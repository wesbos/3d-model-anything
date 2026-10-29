import ARKit
import CoreLocation
import SwiftUI

/// A compass observation paired with an AR pose, before any room/house rotations.
/// Heading angles describe the portrait top edge; cameraBearing describes the rear camera.
struct CompassRecord: Codable {
  var room: Int
  /// Heading time on ARKit's monotonic clock, and the matching camera frame time.
  var timestamp: TimeInterval
  var frameTimestamp: TimeInterval
  /// Original Core Location timestamp, seconds since 1970.
  var recordedAt: TimeInterval
  var magneticHeading: Double
  var trueHeading: Double?
  var headingAccuracy: Double
  var magneticField: [Double]
  var cameraTransform: [Float]
  /// Portrait device axes in session coordinates, including when the phone is tilted.
  var deviceTransform: [Float]
  var poseTimeOffsetSeconds: Double
  var reference: String
  /// Horizontal unit north in the original AR session; nil for rejected observations.
  var northInSession: [Float]?
  var cameraBearing: Double?
  var rejection: String?
}

/// Uses the magnetic field vector rather than treating the phone's top-edge heading
/// as the rear camera's bearing. The latter is wrong when scanning with an upright phone.
@MainActor
final class CompassRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
  @Published private(set) var status = "Directions start with the scan"
  @Published private(set) var uncertain = true
  private(set) var records: [CompassRecord] = []
  private let manager = CLLocationManager()
  private var active = false
  private var locationDate: Date?
  private var lastRecordedAt: TimeInterval = -.infinity
  private struct Pose {
    var timestamp: TimeInterval
    var room: Int
    var camera: simd_float4x4
    var device: simd_float4x4
  }
  private var poses: [Pose] = []
  var authorizationStatus: Int { Int(manager.authorizationStatus.rawValue) }

  override init() {
    super.init()
    manager.delegate = self
    manager.headingOrientation = .portrait
    manager.headingFilter = kCLHeadingFilterNone
    // A coarse location is sufficient for magnetic declination. Coordinates are never saved.
    manager.desiredAccuracy = kCLLocationAccuracyKilometer
    manager.distanceFilter = 1_000
  }

  func prepare() {
    if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
  }

  func start() {
    guard !active else { return }
    guard CLLocationManager.headingAvailable() else {
      status = "Compass unavailable on this device"
      return
    }
    active = true
    poses.removeAll()
    status = "Waiting for compass and stable tracking…"
    uncertain = true
    manager.startUpdatingHeading()
    updateAuthorization()
  }

  func stop() {
    active = false
    manager.stopUpdatingHeading()
    manager.stopUpdatingLocation()
    poses.removeAll()
    status = "Direction recording paused"
  }

  /// Feed only fresh, normally tracked frames while capture is recording.
  func observe(_ frame: ARFrame, room: Int) {
    guard active else { return }
    poses.append(Pose(timestamp: frame.timestamp, room: room, camera: frame.camera.transform,
                      device: frame.camera.viewMatrix(for: .portrait).inverse))
    poses.removeAll { frame.timestamp - $0.timestamp > 2 }
  }

  func clearPoses() { poses.removeAll() }
  func discard(room: Int) { records.removeAll { $0.room == room } }

  func nearest(to timestamp: TimeInterval, room: Int) -> CompassRecord? {
    guard let record = records.filter({ $0.room == room && $0.northInSession != nil })
      .min(by: { abs($0.timestamp - timestamp) < abs($1.timestamp - timestamp) }),
      abs(record.timestamp - timestamp) <= 1 else { return nil }
    return record
  }

  private func updateAuthorization() {
    guard active else { return }
    switch manager.authorizationStatus {
    case .notDetermined: manager.requestWhenInUseAuthorization()
    case .authorizedAlways, .authorizedWhenInUse: manager.startUpdatingLocation()
    default:
      manager.stopUpdatingLocation()
      locationDate = nil
      status = "Magnetic directions · enable Location for true north"
    }
  }

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    Task { @MainActor in self.updateAuthorization() }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    let date = locations.last(where: { $0.horizontalAccuracy >= 0 })?.timestamp
    Task { @MainActor in
      guard self.active else { return }
      self.locationDate = date
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
    Task { @MainActor in self.record(heading) }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    Task { @MainActor in
      guard self.active else { return }
      // Heading remains useful if obtaining a geographic location fails.
      self.locationDate = nil
      self.status = "Waiting for location · magnetic north available"
    }
  }

  nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { true }

  private func record(_ heading: CLHeading) {
    guard active, abs(heading.timestamp.timeIntervalSinceNow) < 2 else { return }
    let time = CACurrentMediaTime() + heading.timestamp.timeIntervalSinceNow
    guard time - lastRecordedAt >= 0.5,
          let pose = poses.min(by: { abs($0.timestamp - time) < abs($1.timestamp - time) }) else { return }
    let field = SIMD3<Float>(Float(heading.x), Float(heading.y), Float(heading.z))
    guard [heading.magneticHeading, heading.headingAccuracy, heading.x, heading.y, heading.z].allSatisfy(\.isFinite) else { return }
    lastRecordedAt = time
    let authorized = manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
    let locationFresh = locationDate.map { abs($0.timeIntervalSinceNow) < 3_600 } ?? false
    let trueHeading = authorized && locationFresh && heading.trueHeading.isFinite && heading.trueHeading >= 0 ? heading.trueHeading : nil
    let offset = abs(pose.timestamp - time)
    var record = CompassRecord(room: pose.room, timestamp: time, frameTimestamp: pose.timestamp,
      recordedAt: heading.timestamp.timeIntervalSince1970, magneticHeading: heading.magneticHeading,
      trueHeading: trueHeading, headingAccuracy: heading.headingAccuracy,
      magneticField: [heading.x, heading.y, heading.z], cameraTransform: pose.camera.columnMajor,
      deviceTransform: pose.device.columnMajor, poseTimeOffsetSeconds: offset,
      reference: trueHeading == nil ? "magnetic" : "true")
    if heading.headingAccuracy < 0 { record.rejection = "invalidHeading" }
    else if offset > 0.15 { record.rejection = "unsynchronizedPose" }
    else {
      let world = pose.device * SIMD4<Float>(field, 0)
      var north = SIMD3<Float>(world.x, 0, world.z)
      if simd_length(north) < 1 { record.rejection = "weakHorizontalField" }
      else {
        north = simd_normalize(north)
        if let trueHeading {
          // trueHeading = magneticHeading + declination. Rotate magnetic north
          // by declination about +Y to recover true north in the session frame.
          let declination = Float((trueHeading - heading.magneticHeading) * .pi / 180)
          north = simd_quatf(angle: declination, axis: SIMD3(0, 1, 0)).act(north)
        }
        record.northInSession = [north.x, 0, north.z]
        let forward = -SIMD3(pose.camera.columns.2.x, 0, pose.camera.columns.2.z)
        if simd_length(forward) > 0.25 {
          let east = SIMD3(-north.z, 0, north.x)
          let degrees = Double(atan2(simd_dot(forward, east), simd_dot(forward, north))) * 180 / .pi
          record.cameraBearing = (degrees + 360).truncatingRemainder(dividingBy: 360)
        }
        if heading.headingAccuracy > 25 { record.rejection = "lowAccuracy" }
      }
    }
    records.append(record)
    uncertain = record.rejection != nil
    if let bearing = record.cameraBearing, !uncertain {
      let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
      let cardinal = directions[Int((bearing + 22.5) / 45) % 8]
      status = "Camera \(cardinal) \(Int(bearing.rounded()) % 360)° · \(record.reference) north ±\(Int(ceil(heading.headingAccuracy)))°"
    } else {
      status = "Directions uncertain · move away from metal and hold steady"
    }
  }
}

struct CompassCaptureStatus: View {
  @ObservedObject var recorder: CompassRecorder
  var body: some View {
    Label(recorder.status, systemImage: "location.north.circle")
      .font(.caption2)
      .foregroundStyle(recorder.uncertain ? Color.orange : Color.primary)
      .accessibilityLabel(recorder.status)
  }
}
