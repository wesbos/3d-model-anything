import ARKit
import AVFoundation

/// Keeps color consistent across a scan: once auto white balance has settled, lock it, so
/// the same wall has the same color in every photo. Exposure stays automatic (a locked
/// exposure picked in a bright corner would crush the dark ones), but ISO + shutter are
/// recorded with every photo and depth frame so brightness can be normalized later.
@MainActor
final class CameraControl {
  private(set) var whiteBalanceLocked = false
  private(set) var summary: String?
  private var device: AVCaptureDevice? { ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera }

  /// Call once the session has been running a few seconds (auto white balance settled)
  func lockWhiteBalance() {
    guard !whiteBalanceLocked, let d = device, d.isWhiteBalanceModeSupported(.locked) else { return }
    do {
      try d.lockForConfiguration()
      d.whiteBalanceMode = .locked
      d.unlockForConfiguration()
      whiteBalanceLocked = true
      let g = d.deviceWhiteBalanceGains
      let tt = d.temperatureAndTintValues(for: g)
      summary = String(format: "locked at %.0f K tint %.1f (gains %.2f %.2f %.2f)", tt.temperature, tt.tint, g.redGain, g.greenGain, g.blueGain)
    } catch {
      summary = "couldn't lock: \(error.localizedDescription)"
    }
  }

  /// Back to auto (between rooms, so each room gets its own white point)
  func unlock() {
    guard whiteBalanceLocked, let d = device else { return }
    try? d.lockForConfiguration()
    d.whiteBalanceMode = .continuousAutoWhiteBalance
    d.unlockForConfiguration()
    whiteBalanceLocked = false
  }

  func state(for frame: ARFrame) -> CameraState {
    let d = device
    let g = d?.deviceWhiteBalanceGains
    return CameraState(
      iso: d?.iso,
      shutter: d.map { CMTimeGetSeconds($0.exposureDuration) } ?? frame.camera.exposureDuration,
      exposureOffset: frame.camera.exposureOffset,
      whiteBalance: g.map { [$0.redGain, $0.greenGain, $0.blueGain] },
      whiteBalanceLocked: whiteBalanceLocked,
      ambientIntensity: frame.lightEstimate.map { Float($0.ambientIntensity) },
      colorTemperature: frame.lightEstimate.map { Float($0.ambientColorTemperature) },
      lensPosition: d?.lensPosition
    )
  }
}
