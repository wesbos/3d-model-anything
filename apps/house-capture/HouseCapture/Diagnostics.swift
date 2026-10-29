import ARKit
import Darwin
import RoomPlan
import SwiftUI

extension Diagnostics {
  /// Sample brightness only; never retain or copy the camera image into diagnostics.
  static func cameraLevels(_ image: CVPixelBuffer) -> (mean: Double, min: Int, max: Int)? {
    let format = CVPixelBufferGetPixelFormatType(image)
    guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
          CVPixelBufferGetPlaneCount(image) > 0,
          CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else { return nil }
    let width = CVPixelBufferGetWidthOfPlane(image, 0), height = CVPixelBufferGetHeightOfPlane(image, 0)
    let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
    let pixels = base.assumingMemoryBound(to: UInt8.self)
    var sum = 0, count = 0, low = 255, high = 0
    for y in stride(from: 0, to: height, by: max(1, height / 16)) {
      for x in stride(from: 0, to: width, by: max(1, width / 16)) {
        let value = Int(pixels[y * rowBytes + x])
        sum += value; count += 1; low = min(low, value); high = max(high, value)
      }
    }
    guard count > 0 else { return nil }
    return (Double(sum) / Double(count), low, high)
  }
}

/// Launch with `-diag` to probe how RoomPlan and ARKit's LiDAR mesh coexist on one
/// ARSession. Prints `DIAG:` lines (read them with `devicectl ... --console`) and exits.
@MainActor
final class DiagnosticsRunner: NSObject, ObservableObject, RoomCaptureSessionDelegate {
  @Published var lines: [String] = []
  private var session = ARSession()
  private var roomPlan: RoomCaptureSession?
  private var roomUpdates = 0
  private var builtRoom: CapturedRoom?

  func log(_ s: String) {
    print("DIAG: \(s)")
    lines.append(s)
  }

  func describe(_ c: ARConfiguration?) -> String {
    guard let c else { return "nil" }
    var s = "\(type(of: c))"
    if let w = c as? ARWorldTrackingConfiguration {
      s += " reconstruction=\(w.sceneReconstruction.rawValue) semantics=\(w.frameSemantics.rawValue) planes=\(w.planeDetection.rawValue)"
    }
    s += " video=\(Int(c.videoFormat.imageResolution.width))x\(Int(c.videoFormat.imageResolution.height))@\(c.videoFormat.framesPerSecond)"
    return s
  }

  func snapshot(_ label: String) {
    let f = session.currentFrame
    let meshes = f?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
    let verts = meshes.reduce(0) { $0 + $1.geometry.vertices.count }
    let planes = f?.anchors.compactMap { $0 as? ARPlaneAnchor }.count ?? 0
    log("\(label): config=\(describe(session.configuration)) meshAnchors=\(meshes.count) verts=\(verts) planes=\(planes) sceneDepth=\(f?.sceneDepth != nil) tracking=\(String(describing: f?.camera.trackingState)) pos=\(f.map { simd_make_float3($0.camera.transform.columns.3) }.map { String(format: "%.2f,%.2f,%.2f", $0.x, $0.y, $0.z) } ?? "-") roomUpdates=\(roomUpdates)")
  }

  func sleep(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

  func run() async {
    log("device=\(UIDevice.modelIdentifier) ios=\(UIDevice.current.systemVersion) roomPlanSupported=\(RoomCaptureSession.isSupported)")
    log("worldTracking supports mesh=\(ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)) meshWithClassification=\(ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)) sceneDepth=\(ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)) highResFormat=\(ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing.map { "\(Int($0.imageResolution.width))x\(Int($0.imageResolution.height))" } ?? "nil")")

    // A: RoomPlan alone, headless on our own session
    log("--- A: RoomPlan headless")
    let rp = RoomCaptureSession(arSession: session)
    rp.delegate = self
    roomPlan = rp
    rp.run(configuration: RoomCaptureSession.Configuration())
    await sleep(4)
    snapshot("A+4s")

    // B: add mesh + depth to RoomPlan's running configuration
    log("--- B: add reconstruction + sceneDepth to RoomPlan's config")
    if let c = session.configuration as? ARWorldTrackingConfiguration, let updated = c.copy() as? ARWorldTrackingConfiguration {
      updated.sceneReconstruction = .meshWithClassification
      updated.frameSemantics.insert(.sceneDepth)
      let before = roomUpdates
      session.run(updated, options: [])
      await sleep(6)
      snapshot("B+6s")
      log("B: roomPlan updates during B = \(roomUpdates - before)")
    } else {
      log("B: skipped, config is \(describe(session.configuration))")
    }

    log("--- stop RoomPlan (keep session) + build")
    rp.stop(pauseARSession: false)
    await sleep(3)
    snapshot("after stop")
    log("built room: \(builtRoom.map { "walls=\($0.walls.count) objects=\($0.objects.count)" } ?? "none")")

    // C: our config first, then RoomPlan on top: does RoomPlan replace it?
    log("--- C: our mesh config first, then RoomPlan run")
    let ours = ARWorldTrackingConfiguration()
    ours.sceneReconstruction = .meshWithClassification
    ours.frameSemantics.insert(.sceneDepth)
    session.run(ours, options: [])
    await sleep(3)
    snapshot("C ours+3s")
    roomUpdates = 0
    builtRoom = nil
    rp.run(configuration: RoomCaptureSession.Configuration())
    await sleep(5)
    snapshot("C roomplan+5s")
    rp.stop(pauseARSession: false)
    await sleep(3)
    log("C built room: \(builtRoom.map { "walls=\($0.walls.count) objects=\($0.objects.count)" } ?? "none")")
    snapshot("C end")

    log("DONE")
    await sleep(1)
    exit(0)
  }

  nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
    Task { @MainActor in self.roomUpdates += 1 }
  }

  nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {
    Task { @MainActor in
      if let error { self.log("didEnd error: \(error.localizedDescription)") }
      do {
        self.builtRoom = try await RoomBuilder(options: []).capturedRoom(from: data)
      } catch {
        self.log("RoomBuilder error: \(error.localizedDescription)")
      }
    }
  }
}

struct DiagnosticsView: View {
  @StateObject var runner = DiagnosticsRunner()
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(runner.lines.enumerated()), id: \.offset) { _, l in Text(l).font(.system(size: 10, design: .monospaced)) }
      }
      .padding()
    }
    .task { await runner.run() }
  }
}

/// Launch with `-autotest`: runs a real single-pass room scan hands-free (the phone can sit
/// on a desk) in a new house "Autotest …", logging `AUTOTEST:` lines, then finishes the room +
/// session and exits. `-autotest-continue` instead continues the newest Autotest house: it
/// relocalizes against the saved map (logging the verification), scans a room, finishes, exits.
struct AutoTestView: View {
  let continueLatest: Bool
  @State private var controller: CaptureController?
  @State private var failure: String?

  var body: some View {
    Group {
      if let controller {
        CaptureScreen(controller: controller) {}
          .task { await run(controller) }
      } else {
        Text(failure ?? "Starting…").padding()
      }
    }
    .task { setUp() }
  }

  private func log(_ s: String) { print("AUTOTEST: \(s)") }

  @MainActor
  private func setUp() {
    guard controller == nil, failure == nil else { return }
    do {
      if continueLatest {
        guard let house = HouseProject.all().first(where: { $0.name.hasPrefix("Autotest") && $0.zones.contains { $0.worldMap != nil } }),
              let zone = house.zones.first(where: { $0.worldMap != nil }) else {
          throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "no Autotest house with a saved map: run -autotest first"])
        }
        log("continue house=\(house.id) zone=\(zone.id) map=\(zone.worldMap ?? "-")")
        controller = try CaptureController.start(houseID: house.id, zoneID: zone.id)
      } else {
        var house = try HouseProject.create(name: "Autotest \(HouseProject.folderName(for: Date()))")
        let zone = house.addZone(named: "Area 1")
        try house.save()
        log("new house=\(house.id)")
        controller = try CaptureController.start(houseID: house.id, zoneID: zone.id)
      }
    } catch {
      failure = error.localizedDescription
      log("setup failed: \(error.localizedDescription)")
      exit(1)
    }
  }

  @MainActor
  private func run(_ c: CaptureController) async {
    try? await Task.sleep(for: .seconds(1))
    if c.phase == .relocalizing {
      var t = 0
      while c.phase == .relocalizing, t < 60 {
        try? await Task.sleep(for: .seconds(2))
        t += 2
        let r = c.reloc
        log("reloc t=\(t)s stage=\(r.stage) tracking=\(r.tracking) progress=\(r.progress) check=\(r.check.map { "known=\($0.known) matched=\($0.matched) median=\($0.median ?? -1)" } ?? "-") ref=\(r.reference)")
      }
      if c.phase == .relocalizing {
        log("not relocalized after 60 s: starting unaligned")
        c.startUnaligned()
      }
      log("alignment: \(c.alignment.method) residual=\(c.alignment.residualMeters ?? -1) note=\(c.alignment.note ?? "-")")
      try? await Task.sleep(for: .seconds(3))
      log("prior photos: \(c.priorPhotoCount)")
    }
    c.roomName = "Autotest"
    c.startRoom()
    for t in stride(from: 2, through: 24, by: 2) {
      try? await Task.sleep(for: .seconds(2))
      let meshes = c.arSession.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
      log("t=\(t)s meshReady=\(c.meshReady) meshAnchors=\(meshes.count) verts=\(meshes.reduce(0) { $0 + $1.geometry.vertices.count }) meshArea=\(String(format: "%.2f", c.stats.meshArea)) percent=\(c.stats.percent) redSpots=\(c.stats.redSpots.count) photos=\(c.photoCount) walls=\(c.coverage.walls.count) hint=\(c.hint) instruction=\(c.instruction ?? "-") depth=\(c.arSession.currentFrame?.sceneDepth != nil) map=\(WorldMapFile.describe(c.mappingStatus))")
      if t == 10 {
        c.pause()
        log("paused=\(c.paused)")
      } else if t == 12 {
        c.resume()
        log("resumed paused=\(c.paused)")
      }
    }
    let report = await withCheckedContinuation { k in c.engine.debugReport { k.resume(returning: $0) } }
    for line in report.split(separator: "\n").prefix(20) { log(String(line)) }
    c.finishRoom()
    while c.phase != .betweenRooms { try? await Task.sleep(for: .milliseconds(200)) }
    if let r = c.rooms.last {
      log("room: file=\(r.file) data=\(r.data ?? "-") walls=\(r.walls) mesh=\(r.mesh.map { "\($0.vertices)v/\($0.faces)f" } ?? "none") coverage=\(r.coverage ?? -1) photoCoverage=\(r.photoCoverage ?? -1) photos=\(r.detailPhotos ?? 0)")
    }
    log("map after room: \(c.mapSummary ?? "-")")
    log("warning=\(c.lastWarning ?? "-")")
    await c.finishSession()
    let m = c.bundle.manifest
    log("phase=\(c.phase) manifest: format=\(m?.format ?? "?") photos=\(m?.photoCount ?? -1) depthFrames=\(m?.depthFrameCount ?? -1) worldMap=\(m?.worldMap ?? "-") status=\(m?.worldMapStatus ?? "-") alignment=\(m?.alignment?.method ?? "-")")
    if let d = m?.diagnostics {
      log("diag: rp=\(d.roomPlanConfiguration ?? "-") | scan=\(d.detailConfiguration ?? "-") | jumps=\(d.worldJumps.count) | checks=\(d.alignmentChecks?.count ?? 0)")
      if let r = d.relocalization { log("reloc: toNormal=\(r.secondsToNormal ?? -1) toVerified=\(r.secondsToVerified ?? -1) residual=\(r.residualMeters ?? -1) outcome=\(r.outcome ?? "-") refVerts=\(r.referenceVertices ?? -1)") }
      for e in (d.events ?? []).suffix(40) { log("event \(e.t)s \(e.what)") }
    }
    if let house = try? HouseProject.load(id: c.plan.houseID) {
      log("house: zones=\(house.zones.map { "\($0.id) map=\($0.worldMap ?? "-")" }) sessions=\(house.sessions.map { "\($0.id) \($0.alignment.method) rooms=\($0.rooms)" }) rooms=\(house.rooms.map { "\($0.name) scans=\($0.history.count)" })")
    }
    let files = (try? FileManager.default.contentsOfDirectory(atPath: c.bundle.file("mesh").path)) ?? []
    let size = files.compactMap { try? FileManager.default.attributesOfItem(atPath: c.bundle.file("mesh/\($0)").path)[.size] as? Int }
    log("mesh files: \(zip(files, size).map { "\($0.0) \($0.1 / 1024)KB" })")
    log("DONE")
    try? await Task.sleep(for: .seconds(2))
    exit(0)
  }
}

// MARK: - Persisted capture failure details

extension Diagnostics {
  /// Copy error values before crossing callback queues; cap depth and detect cycles.
  nonisolated static func errorChain(_ error: Error) -> [ErrorDetail] {
    var result: [ErrorDetail] = []
    var current: NSError? = error as NSError
    var seen = Set<ObjectIdentifier>()
    while let e = current, result.count < 8, seen.insert(ObjectIdentifier(e)).inserted {
      result.append(ErrorDetail(domain: e.domain, code: e.code,
                                description: e.localizedDescription,
                                reason: e.localizedFailureReason, recovery: e.localizedRecoverySuggestion))
      current = e.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return result
  }

  mutating func recordFailure(source: String, chain: [ErrorDetail], since start: Date) {
    var list = failures ?? []
    list.append(Failure(t: Date().timeIntervalSince(start), source: source, chain: chain))
    failures = Array(list.suffix(32))
    log("\(source) failure: " + chain.map { "\($0.domain)(\($0.code)): \($0.description)" }.joined(separator: " ← "), since: start)
  }

  mutating func recordSample(_ sample: ResourceSample) {
    var list = resourceSamples ?? []
    list.append(sample)
    resourceSamples = Array(list.suffix(240)) // 20 minutes at a 5-second interval
  }

  nonisolated static func thermalDescription(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
  }

  nonisolated static func memoryFootprintMB() -> Double? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    return Double(info.phys_footprint) / 1_048_576
  }
}

/// Recovery hysteresis: bad tracking blocks capture immediately; fresh normal frames must
/// remain stable before capture resumes. Mapping status intentionally does not enter this policy.
struct TrackingRecovery {
  enum Issue: Equatable {
    case starting, motion, features, relocalizing, unavailable, interrupted, stalled, settling

    var message: String {
      switch self {
      case .starting: return "Finding your position. Aim at a well-lit doorway or furniture and move slowly."
      case .motion: return "Slow down and hold steady. Keep a familiar doorway or furniture in view."
      case .features: return "Aim at well-lit furniture, shelves or a doorway. Blank walls are hard to track."
      case .relocalizing: return "Return to an area you just scanned and pan slowly so the phone can recognize it."
      case .unavailable: return "Position tracking is unavailable. Hold steady with the room in view."
      case .interrupted: return "Camera interrupted. Return to the app, then aim at an area you already scanned."
      case .stalled: return "Camera updates have stalled. Hold steady. If this persists, finish the room to save what you have."
      case .settling: return "Position found. Hold steady for a moment while tracking settles."
      }
    }
  }

  private(set) var issue: Issue? = .starting
  private var normalSince: TimeInterval?
  var canCapture: Bool { issue == nil }

  mutating func update(problem: Issue?, now: TimeInterval) {
    if let problem {
      issue = problem
      normalSince = nil
    } else if issue != nil {
      if normalSince == nil { normalSince = now }
      issue = now - (normalSince ?? now) >= 1.5 ? nil : .settling
    }
  }

  static func problem(for state: ARCamera.TrackingState) -> Issue? {
    switch state {
    case .normal: return nil
    case .notAvailable: return .unavailable
    case .limited(.initializing): return .starting
    case .limited(.excessiveMotion): return .motion
    case .limited(.insufficientFeatures): return .features
    case .limited(.relocalizing): return .relocalizing
    case .limited: return .unavailable
    }
  }
}
