import ARKit
import AVFoundation

// Kept small so the configuration/fallback path can be exercised without camera hardware.
@MainActor
protocol WhiteBalanceDevice: AnyObject {
  var deviceWhiteBalanceGains: AVCaptureDevice.WhiteBalanceGains { get }
  var maxWhiteBalanceGain: Float { get }
  var whiteBalanceMode: AVCaptureDevice.WhiteBalanceMode { get set }
  func isWhiteBalanceModeSupported(_ mode: AVCaptureDevice.WhiteBalanceMode) -> Bool
  func lockForConfiguration() throws
  func unlockForConfiguration()
}
extension AVCaptureDevice: WhiteBalanceDevice {}

/// Lock a settled white point when supported; leave camera automation alone otherwise.
/// Exposure stays automatic. Raw gains remain available for later color normalization.
@MainActor
final class CameraControl {
  private(set) var whiteBalanceLocked = false
  private(set) var summary: String?
  private var attempted = false
  private var lockedDevice: (any WhiteBalanceDevice)?
  private let whiteBalanceDevice: () -> (any WhiteBalanceDevice)?
  private var device: AVCaptureDevice? { ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera }

  init(whiteBalanceDevice: @escaping () -> (any WhiteBalanceDevice)? = {
    ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera
  }) {
    self.whiteBalanceDevice = whiteBalanceDevice
  }

  /// Reject invalid metadata rather than clamping it into a fabricated white point.
  static func validGains(_ gains: AVCaptureDevice.WhiteBalanceGains, maximum: Float) -> [Float]? {
    let values = [gains.redGain, gains.greenGain, gains.blueGain]
    guard maximum.isFinite, maximum >= 1,
          values.allSatisfy({ $0.isFinite && $0 >= 1 && $0 <= maximum }) else { return nil }
    return values
  }

  /// One best-effort attempt per room, after auto white balance has settled.
  func lockWhiteBalance() {
    guard !attempted, !whiteBalanceLocked else { return }
    attempted = true
    guard let d = whiteBalanceDevice() else { summary = "white balance device unavailable"; return }
    do {
      try d.lockForConfiguration()
      defer { d.unlockForConfiguration() }
      guard d.isWhiteBalanceModeSupported(.locked) else {
        summary = "white balance lock unsupported"; return
      }
      guard let gains = Self.validGains(d.deviceWhiteBalanceGains, maximum: d.maxWhiteBalanceGain) else {
        summary = "white balance gains unavailable; left unchanged"; return
      }
      d.whiteBalanceMode = .locked
      lockedDevice = d
      whiteBalanceLocked = true
      // Temperature/tint conversion is optional diagnostics, but can raise an Objective-C
      // exception (not caught by Swift do/catch). Do not invoke it in the capture loop.
      summary = String(format: "locked (gains %.2f %.2f %.2f)", gains[0], gains[1], gains[2])
    } catch {
      summary = "couldn't lock: \(error.localizedDescription)"
    }
  }

  /// Restore only the device we locked, and never write after configuration locking fails.
  func unlock() {
    attempted = false
    guard let d = lockedDevice else { return }
    do {
      try d.lockForConfiguration()
      defer { d.unlockForConfiguration() }
      guard d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) else {
        summary = "automatic white balance unsupported; lock retained"; return
      }
      d.whiteBalanceMode = .continuousAutoWhiteBalance
      whiteBalanceLocked = false
      lockedDevice = nil
    } catch {
      summary = "couldn't restore automatic white balance: \(error.localizedDescription)"
    }
  }

  func state(for frame: ARFrame) -> CameraState {
    let d = device
    let gains = d.flatMap { Self.validGains($0.deviceWhiteBalanceGains, maximum: $0.maxWhiteBalanceGain) }
    return CameraState(
      iso: d?.iso,
      shutter: d.map { CMTimeGetSeconds($0.exposureDuration) } ?? frame.camera.exposureDuration,
      exposureOffset: frame.camera.exposureOffset,
      whiteBalance: gains,
      whiteBalanceLocked: whiteBalanceLocked,
      ambientIntensity: frame.lightEstimate.map { Float($0.ambientIntensity) },
      colorTemperature: frame.lightEstimate.map { Float($0.ambientColorTemperature) }
    )
  }
}
