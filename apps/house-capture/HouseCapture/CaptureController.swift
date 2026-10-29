import ARKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import RoomPlan
import SwiftUI
import UniformTypeIdentifiers

/// Which house / zone a capture session belongs to and how it starts
struct CapturePlan {
  var houseID: String
  var zoneID: String
  /// folder name under sessions/
  var sessionID: String
  /// the zone's saved ARWorldMap to relocalize against first ("Continue"); nil = fresh world
  var worldMap: URL?
  /// alignment of a fresh start: "first" (this session defines the zone frame) or "unaligned"
  var freshMethod: String
  var note: String?
}

/// Drives one capture session of a house: one ARSession, rooms scanned one after the other
/// (so they, their photos, depth and meshes share a coordinate system):
///
/// - Continue sessions first relocalize against the zone's saved ARWorldMap (before RoomPlan
///   runs), with the zone's earlier meshes drawn as a green ghost, and verify the match by
///   measuring the live LiDAR mesh against the saved one. No match → start unaligned.
/// - RoomPlan runs headless in the background, measuring walls, doors, windows and
///   furniture boxes.
/// - LiDAR mesh + depth are switched on inside RoomPlan's own configuration (verified on
///   device: RoomPlan keeps working, and the mesh is ours to draw).
/// - The camera view shows the mesh tinted by photo coverage plus RoomPlan's live walls;
///   sharp photos are taken wherever they turn the most red to green.
/// - Every finished room is recorded in house.json right away (a crash loses at most the
///   room in progress); the world map is saved after each room and at the end.
@MainActor
final class CaptureController: NSObject, ObservableObject, RoomCaptureSessionDelegate {
  enum Phase: Equatable {
    case relocalizing // Continue: finding our place in the zone's saved map
    case betweenRooms // ready to start the next room (or the first one)
    case scanning
    case finishingRoom
    case finishing
    case done
    case failed(String)
  }

  /// What the Continue screen shows
  struct Relocalization: Equatable {
    enum Stage: Equatable {
      case loadingMap
      /// map running, ARKit hasn't recognized the place yet
      case searching
      /// ARKit says it's relocalized: measuring the live mesh against the saved one
      case checking
      /// relocalized, but the live mesh doesn't sit on the saved one
      case mismatch
      case done
      case failed(String)
    }
    var stage: Stage = .loadingMap
    var tracking = "Starting the camera…"
    var seconds = 0
    /// verification progress 0…1 (≥ 1.5 s of good matches)
    var progress: Float = 0
    var check: ZoneReference.Check?
    var timedOut = false
    /// "Loading earlier scan…", "earlier scan: 85k triangles", …
    var reference = "Loading your earlier scan…"
  }

  @Published private(set) var phase: Phase
  @Published var roomName = ""
  @Published private(set) var rooms: [RoomRecord] = []
  @Published private(set) var photoCount = 0
  private let autoPhotos = true
  @Published var highResolutionPhotos = false
  /// Explicit opt-in for this capture session; never inherited from Location permission.
  @Published var recordDirections = false {
    didSet {
      guard recordDirections != oldValue else { return }
      if recordDirections { compass.prepare() }
      else { compass.stop() }
    }
  }
  @Published private(set) var trackingIssue: TrackingRecovery.Issue? = .starting
  @Published private(set) var sessionNeedsRestart = false
  @Published private(set) var recordingSaveFailed = false
  private var pendingRoomIDs: [Int: String] = [:]
  private var recovery = TrackingRecovery()
  private var sessionInterrupted = false
  private var lastHighResRequest: TimeInterval = -.infinity
  var captureReady: Bool { recovery.canCapture && !sessionNeedsRestart && !sessionInterrupted }
  var canTakePhoto: Bool { phase == .scanning && !paused && captureReady && !highResInFlight && photosInFlight == 0 }
  @Published private(set) var lastWarning: String?
  /// good news (relocalized, map saved) shown briefly
  @Published private(set) var notice: String?
  /// RoomPlan's coaching ("move closer to the wall", …)
  @Published private(set) var instruction: String?
  /// live wall coverage for the map
  @Published private(set) var coverage = Coverage()
  @Published private(set) var cameraPose: simd_float4x4?
  /// coverage of the current room + where to look next
  @Published private(set) var stats = CoverageEngine.Stats()
  @Published private(set) var hint: CoverageEngine.Hint = .none
  @Published private(set) var meshReady = false
  /// photos, depth recording and coverage updates stopped (tracking keeps running)
  @Published private(set) var paused = false
  @Published private(set) var reloc = Relocalization()
  @Published private(set) var alignment: HouseProject.Alignment
  @Published private(set) var mappingStatus: ARFrame.WorldMappingStatus = .notAvailable
  /// "Map saved (12 MB)" / why not
  @Published private(set) var mapSummary: String?
  @Published var ghostVisible = true {
    didSet { applyGhostOpacity() }
  }
  /// photos of the zone from earlier sessions, to show where to stand while relocalizing
  @Published private(set) var landmarks: [URL] = []
  @Published private(set) var priorPhotoCount = 0
  /// what finishing is doing right now
  @Published private(set) var finishingStep = ""

  let arSession = ARSession()
  private var roomSessionCreated = false
  private lazy var roomSession: RoomCaptureSession = {
    roomSessionCreated = true
    let s = RoomCaptureSession(arSession: arSession)
    s.delegate = self
    return s
  }()
  let engine = CoverageEngine()
  let compass = CompassRecorder()
  private(set) lazy var scanView: ScanView = {
    let scan = ScanView(session: arSession, engine: engine)
    scan.onSessionFailure = { [weak self] chain in
      guard let self, !self.closed else { return }
      self.sessionNeedsRestart = true
      self.candidate = nil
      self.lastWarning = "Position tracking stopped. Finish this room to save what is available, then finish the session and start a new capture."
      self.diagnostics.recordFailure(source: "ARKit", chain: chain, since: self.startedAt)
      self.sampleDiagnostics(force: true)
    }
    scan.onSessionEvent = { [weak self] event in
      guard let self, !self.closed else { return }
      self.sessionInterrupted = event == "ARKit session interrupted"
      self.recovery.update(problem: .interrupted, now: CACurrentMediaTime())
      self.trackingIssue = self.recovery.issue
      self.candidate = nil
      self.scanView.feed.isOn = false
      self.diagnostics.log(event, since: self.startedAt)
      self.sampleDiagnostics(force: true)
    }
    return scan
  }()
  private lazy var depthRecorder = DepthRecorder(bundle: bundle)
  private let cameraControl = CameraControl()
  private var meshReadyAt: TimeInterval?
  /// mesh export taken just before RoomPlan stops (stopping reconfigures the session)
  private var preStopMesh: Result<(vertices: Int, faces: Int, covered: Float), Error>?

  let plan: CapturePlan
  let bundle: ScanBundle
  private(set) var house: HouseProject
  private var capturedRooms: [CapturedRoom] = []
  private var liveRoom: CapturedRoom?
  private var lastRoomToEngine: TimeInterval = 0
  private var photos: [PhotoRecord] = []
  private var photoViews: [(room: Int, view: PhotoView)] = []
  private var enginePhotos: [CoverageEngine.Photo] = []
  /// earlier photos of the zone (Continue), counted for coverage but not saved in this bundle
  private var priorPhotos: [CoverageEngine.Photo] = []
  private var displayLink: CADisplayLink?
  private var previousPose: (time: TimeInterval, pose: simd_float4x4)?
  private var poseHistory: [(time: TimeInterval, pose: simd_float4x4)] = []
  private var lastPosePublish: TimeInterval = 0
  private var lastEvaluate: TimeInterval = 0
  private var lastMeshCheck: TimeInterval = 0
  private var lastBlur: Float?
  private var candidate: Shot?
  private var highResSupported = true
  private var highResInFlight = false
  private var highResRequestID: UUID?
  private var lastPhotoTime: TimeInterval = 0
  private var photosInFlight = 0
  private var nextPhotoID = 0
  private var roomStartedAt: Date?
  private var roomPhotoCount = 0
  private var diagnostics = Diagnostics()
  private var lastDiagnosticSample: CFTimeInterval = 0
  private var coverageProbePending = false
  private var coverageQueueDelayMS: Double?
  private let diagnosticWriter = DispatchQueue(label: "capture-diagnostics", qos: .utility)
  private let ciContext = CIContext()
  private let startedAt = Date()
  private var endedAt: Date?
  private var begun = false
  /// abandoned: late async results (map load, RoomPlan's didEnd) must not touch anything
  private var closed = false
  private var sessionRunning = false
  private var noticeTask: Task<Void, Never>?

  // world map
  private var mapSaving = false
  private var worldMapSaved = false
  private var worldMapStatus: String?
  private var warnedBigMap = false

  // relocalization
  private var relocMap: ARWorldMap?
  private var reference: ZoneReference?
  private var referenceLoaded = false
  private var relocRunAt: CFTimeInterval = 0
  private var timeoutAt: CFTimeInterval = 0
  private var normalSince: CFTimeInterval?
  private var seenNormal = false
  private var goodSince: CFTimeInterval?
  private var lastGoodAt: CFTimeInterval = 0
  private var goodMedians: [Float] = []
  private var mismatchSince: CFTimeInterval?
  private var checkInFlight = false
  private var lastCheckAt: CFTimeInterval = 0
  private let checkQueue = DispatchQueue(label: "alignment-check", qos: .userInitiated)
  private var lastTrackingLog = ""
  private var lastMappingLog: ARFrame.WorldMappingStatus?
  private var monitorBad = 0
  private var warnedDrift = false

  static var isSupported: Bool { RoomCaptureSession.isSupported }
  static let relocalizationTimeout: CFTimeInterval = 90

  init(house: HouseProject, plan: CapturePlan, bundle: ScanBundle, alignment: HouseProject.Alignment) {
    self.house = house
    self.plan = plan
    self.bundle = bundle
    self.alignment = alignment
    phase = plan.worldMap == nil ? .betweenRooms : .relocalizing
    super.init()
    roomName = "" // asked for before each room
    engine.onStats = { [weak self] stats in
      guard let self else { return }
      if stats.percent >= self.lastProgressPercent + 2 {
        self.lastProgressPercent = stats.percent
        self.lastCoverageProgress = Date()
      }
      self.stats = stats
    }
  }

  /// Set up a new session in a house: its folder, and its entry in house.json (so rooms are
  /// recorded as they finish). `newZone` makes a new area first.
  static func start(houseID: String, zoneID: String?, newZone: String? = nil) throws -> CaptureController {
    var house = try HouseProject.load(id: houseID)
    var zone: HouseProject.Zone?
    if let newZone {
      zone = house.addZone(named: newZone)
    } else if let zoneID {
      zone = house.zone(zoneID)
      if let candidate = zone, let map = house.existingWorldMap(zone: candidate) {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: map.path)[.size] as? Int) ?? 0
        if bytes >= 35_000_000 || house.roomsInZone(candidate.id).count >= 4 { zone = house.addZone(named: "") }
      } else if let candidate = zone, !house.sessionsInZone(candidate.id).isEmpty { zone = house.addZone(named: "") }
    } else {
      zone = house.addZone(named: "")
    }
    guard let zone else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "That room is no longer available. Start a new scan."]) }

    var id = HouseProject.folderName(for: Date())
    var n = 2
    while FileManager.default.fileExists(atPath: house.url.appendingPathComponent("sessions/\(id)").path) {
      id = HouseProject.folderName(for: Date()) + " \(n)"
      n += 1
    }
    let placed = house.placedSessionsInZone(zone.id)
    let map = house.existingWorldMap(zone: zone)
    var plan = CapturePlan(houseID: houseID, zoneID: zone.id, sessionID: id, worldMap: nil, freshMethod: "first")
    let alignment: HouseProject.Alignment
    if let map {
      plan.worldMap = map
      // until relocalization is verified (a crash mid-way leaves an honest record)
      alignment = .init(method: "unaligned", note: "relocalization not finished")
    } else if placed.isEmpty {
      alignment = .init(method: "first")
    } else {
      plan.freshMethod = "unaligned"
      plan.note = "\(zone.name) has no saved world map to continue from"
      alignment = .init(method: "unaligned", note: plan.note)
    }
    let bundle = try ScanBundle.create(in: house, id: id)
    do {
      house.beginSession(id: id, zone: zone.id, alignment: alignment)
      try house.save()
    } catch {
      try? bundle.delete()
      throw error
    }
    return CaptureController(house: house, plan: plan, bundle: bundle, alignment: alignment)
  }

  private var roomIndex: Int { rooms.count } // the room being scanned

  var zoneName: String { house.roomsInZone(plan.zoneID).map(\.name).joined(separator: ", ").isEmpty ? "your earlier scan" : house.roomsInZone(plan.zoneID).map(\.name).joined(separator: ", ") }
  var isContinue: Bool { plan.worldMap != nil }
  var hasGhost: Bool { reference?.ghost != nil }

  /// Rooms of this zone scanned in earlier sessions (and not yet in this one): rescan candidates
  var existingRoomNames: [String] {
    house.rooms
      .filter { r in !r.history.contains { $0.session == plan.sessionID } }
      .map(\.name)
  }

  /// Call when the capture screen appears
  func begin() {
    guard !begun else { return }
    begun = true
    NotificationCenter.default.addObserver(self, selector: #selector(memoryWarning),
        name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(thermalChanged),
        name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    diagnostics.log("session \(plan.sessionID) zone \(plan.zoneID) \(isContinue ? "continue" : plan.freshMethod)", since: startedAt)
    if let url = plan.worldMap { startRelocalizing(url) }
  }

  // MARK: - Continue: relocalize against the zone's map

  private func startRelocalizing(_ url: URL) {
    reloc = Relocalization()
    diagnostics.relocalization = Diagnostics.Relocalization()
    diagnostics.relocalization?.worldMapBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
    UIApplication.shared.isIdleTimerDisabled = true
    startTicking()
    let snapshot = house, zone = plan.zoneID, session = plan.sessionID
    Task.detached(priority: .userInitiated) { [weak self] in
      let result = Result { try WorldMapFile.load(url) }
      await self?.worldMapLoaded(result)
    }
    Task.detached(priority: .utility) { [weak self] in
      let ref = ZoneReference.load(house: snapshot, zone: zone, excludingSession: session)
      let marks = PriorPhotos.landmarks(house: snapshot, zone: zone)
      await self?.referenceReady(ref, landmarks: marks)
    }
  }

  private func worldMapLoaded(_ result: Result<ARWorldMap, Error>) {
    guard phase == .relocalizing, !closed else { return }
    switch result {
    case .success(let map):
      relocMap = map
      diagnostics.log("world map loaded: \(map.rawFeaturePoints.points.count) feature points, \(map.anchors.count) anchors", since: startedAt)
      runRelocalization(map)
    case .failure(let error):
      reloc.stage = .failed("Couldn't read the saved map (\(error.localizedDescription)).")
      diagnostics.log("world map load failed: \(error.localizedDescription)", since: startedAt)
    }
  }

  private func referenceReady(_ ref: ZoneReference, landmarks: [URL]) {
    guard !closed else { return }
    self.landmarks = landmarks
    diagnostics.relocalization?.referenceVertices = ref.sourceVertices
    diagnostics.relocalization?.ghostTriangles = ref.ghost?.triangleCount
    for e in ref.errors.prefix(5) { diagnostics.log("saved mesh skipped: \(e)", since: startedAt) }
    guard phase == .relocalizing || alignment.method == "relocalized" else { return } // went unaligned meanwhile
    reference = ref
    referenceLoaded = true
    scanView.setGhost(ref.ghost)
    applyGhostOpacity()
    reloc.reference = ref.isEmpty
      ? "No saved mesh in \(zoneName) to check against."
      : "Earlier scan: \(ref.files.count) mesh\(ref.files.count == 1 ? "" : "es"), \((ref.ghost?.triangleCount ?? 0) / 1000)k triangles"
  }

  private static func relocalizationConfiguration(map: ARWorldMap?) -> ARWorldTrackingConfiguration {
    let c = ARWorldTrackingConfiguration()
    c.initialWorldMap = map
    if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
      c.sceneReconstruction = .meshWithClassification
    }
    if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { c.frameSemantics.insert(.sceneDepth) }
    return c
  }

  private func runRelocalization(_ map: ARWorldMap) {
    // the only reset in a Continue session: nothing of this session's own exists yet
    scanView.feed.isOn = false
    arSession.run(Self.relocalizationConfiguration(map: map), options: [.resetTracking, .removeExistingAnchors])
    sessionRunning = true
    let now = CACurrentMediaTime()
    relocRunAt = now
    timeoutAt = now + Self.relocalizationTimeout
    normalSince = nil
    seenNormal = false
    goodSince = nil
    goodMedians = []
    mismatchSince = nil
    reloc.stage = .searching
    reloc.progress = 0
    reloc.timedOut = false
    reloc.check = nil
    applyGhostOpacity()
    diagnostics.log("relocalization run", since: startedAt)
  }

  private func tickRelocalization(_ frame: ARFrame, now: CFTimeInterval) {
    let tracking = frame.camera.trackingState
    let text = Self.trackingText(tracking)
    if reloc.tracking != text { reloc.tracking = text }
    let seconds = Int(now - relocRunAt)
    if relocRunAt > 0, reloc.seconds != seconds { reloc.seconds = seconds }
    switch reloc.stage {
    case .loadingMap, .failed, .done: return
    default: break
    }

    switch tracking {
    case .normal:
      if normalSince == nil {
        normalSince = now
        if diagnostics.relocalization?.secondsToNormal == nil { diagnostics.relocalization?.secondsToNormal = (now - relocRunAt).rounded1 }
      }
      if !seenNormal {
        seenNormal = true
        applyGhostOpacity() // the world is the zone's now: the ghost means something
      }
    case .limited(.relocalizing), .limited(.initializing), .notAvailable:
      normalSince = nil
      goodSince = nil
      reloc.progress = 0
      if seenNormal {
        seenNormal = false // the world may jump again when it relocalizes
        applyGhostOpacity()
      }
    case .limited:
      // fast motion / low features after it relocalized: the world is still the zone's
      normalSince = nil
      goodSince = nil
      reloc.progress = 0
    }

    if !reloc.timedOut, now >= timeoutAt {
      reloc.timedOut = true
      diagnostics.log("relocalization timeout after \(Int(now - relocRunAt)) s", since: startedAt)
    }

    guard let normalSince else {
      if reloc.stage != .mismatch { reloc.stage = .searching }
      return
    }
    guard referenceLoaded, let reference else {
      reloc.stage = .checking // waiting for the saved mesh to load
      return
    }
    if reference.isEmpty {
      // nothing to measure against: trust ARKit once tracking has been steady a moment
      reloc.stage = .checking
      reloc.progress = Float(min(1, (now - normalSince) / 3))
      if now - normalSince >= 3 { relocalized(residual: nil, inliers: nil, note: "not verified: no saved mesh in this zone") }
      return
    }
    if reloc.stage == .searching { reloc.stage = .checking }
    if !checkInFlight, now - lastCheckAt >= 0.3, now - normalSince >= 0.5 {
      runCheck(frame, reference: reference)
    }
  }

  /// Measure the live mesh in view against the saved surfaces (off main)
  private func runCheck(_ frame: ARFrame, reference: ZoneReference) {
    let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
    let camera = frame.camera.transform
    checkInFlight = true
    lastCheckAt = CACurrentMediaTime()
    checkQueue.async { [weak self] in
      let points = LiveMeshSampler.sample(anchors, camera: camera)
      let check = reference.check(points)
      Task { @MainActor in
        guard let self else { return }
        self.checkInFlight = false
        self.handle(check)
      }
    }
  }

  private func handle(_ check: ZoneReference.Check) {
    let now = CACurrentMediaTime()
    if phase != .relocalizing {
      monitor(check)
      return
    }
    reloc.check = check
    guard normalSince != nil, reloc.stage == .checking || reloc.stage == .mismatch else { return }
    if check.isGood, let median = check.median {
      mismatchSince = nil
      if reloc.stage == .mismatch { reloc.stage = .checking }
      if goodSince == nil {
        goodSince = now
        goodMedians = []
      }
      goodMedians.append(median)
      lastGoodAt = now
      let held = now - goodSince!
      reloc.progress = Float(min(1, held / 1.5))
      if held >= 1.5, goodMedians.count >= 4 {
        let sorted = goodMedians.sorted()
        relocalized(residual: sorted[sorted.count / 2], inliers: check.inlierFraction, note: nil)
      }
    } else if check.isMismatch {
      goodSince = nil
      reloc.progress = 0
      if mismatchSince == nil { mismatchSince = now }
      if now - mismatchSince! >= 3, reloc.stage != .mismatch {
        reloc.stage = .mismatch
        diagnostics.log("relocalization mismatch: known \(check.known) matched \(check.matched) median \(check.median.map { String(format: "%.3f", $0) } ?? "-")", since: startedAt)
      }
    } else if goodSince != nil, now - lastGoodAt > 1 {
      // looked away from the scanned area: start the 1.5 s over
      goodSince = nil
      reloc.progress = 0
    }
  }

  private func relocalized(residual: Float?, inliers: Float?, note: String?) {
    guard phase == .relocalizing else { return }
    alignment = .init(method: "relocalized", residualMeters: residual, note: note)
    saveAlignment()
    let now = CACurrentMediaTime()
    diagnostics.relocalization?.secondsToVerified = (now - relocRunAt).rounded1
    diagnostics.relocalization?.residualMeters = residual
    diagnostics.relocalization?.inlierFraction = inliers
    diagnostics.relocalization?.outcome = "relocalized"
    diagnostics.log("relocalized: residual \(residual.map { String(format: "%.3f", $0) } ?? "-") \(note ?? "")", since: startedAt)
    reloc.stage = .done
    reloc.progress = 1
    relocMap = nil // the session has it now; don't hold tens of MB twice
    phase = .betweenRooms
    applyGhostOpacity()
    scanView.feed.isOn = captureReady
    if captureReady { scanView.refeedEngine(from: arSession) }
    loadPriorPhotos()
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    show(notice: residual.map { "Lined up with your earlier scan (±\(String(format: "%.1f", $0 * 100)) cm). Pick up where you left off." }
      ?? "Relocalized in \(zoneName). Pick up where you left off.")
  }

  /// Give up on the saved map: this session gets its own frame (the Mac lines it up later)
  func startUnaligned() {
    guard phase == .relocalizing else { return }
    let why: String
    switch reloc.stage {
    case .mismatch: why = "relocalized but the live mesh didn't match the saved one"
    case .failed(let m): why = m
    default: why = "couldn't relocalize (gave up after \(reloc.seconds) s)"
    }
    alignment = .init(method: "unaligned", note: why)
    saveAlignment()
    diagnostics.relocalization?.outcome = "unaligned: \(why)"
    diagnostics.log("start unaligned: \(why)", since: startedAt)
    relocMap = nil
    reference = nil
    scanView.setGhost(nil)
    // a fresh world, without the map
    arSession.run(Self.relocalizationConfiguration(map: nil), options: [.resetTracking, .removeExistingAnchors])
    sessionRunning = true
    scanView.feed.isOn = true
    reloc.stage = .done
    phase = .betweenRooms
    show(notice: "Saved rooms will need alignment. Use Connect room to match a doorway with another room.")
  }

  /// Relocalized to the wrong place (or stuck): run the map again from scratch
  func retryRelocalization() {
    guard phase == .relocalizing, let relocMap else { return }
    diagnostics.log("relocalization retry", since: startedAt)
    runRelocalization(relocMap)
  }

  /// After the timeout: another minute
  func keepTrying() {
    reloc.timedOut = false
    timeoutAt = CACurrentMediaTime() + 60
  }

  /// Faint ghost while scanning, clearer while relocalizing; hidden until the world is the zone's
  private func applyGhostOpacity() {
    guard reference?.ghost != nil else {
      scanView.setGhostOpacity(0)
      return
    }
    let alpha: CGFloat
    switch phase {
    case .relocalizing: alpha = seenNormal ? 0.4 : 0
    case .betweenRooms, .scanning, .finishingRoom: alpha = alignment.method == "relocalized" && ghostVisible ? 0.14 : 0
    default: alpha = 0
    }
    scanView.setGhostOpacity(alpha)
  }

  /// After relocalizing: live mesh vs saved mesh every few seconds. Catches the world
  /// quietly resetting (e.g. when RoomPlan starts) so the user isn't scanning into a wrong frame.
  private func monitor(_ check: ZoneReference.Check) {
    guard check.known >= 50 else { return }
    var list = diagnostics.alignmentChecks ?? []
    list.append(.init(t: Date().timeIntervalSince(startedAt).rounded1, known: check.known, matched: check.matched, median: check.median))
    if list.count > 300 { list.removeFirst(list.count - 300) }
    diagnostics.alignmentChecks = list
    if check.isMismatch { monitorBad += 1 } else if check.isGood { monitorBad = 0 }
    if monitorBad >= 3, !warnedDrift {
      warnedDrift = true
      diagnostics.log("alignment drift: known \(check.known) matched \(check.matched)", since: startedAt)
      lastWarning = "The earlier scan doesn't line up any more (tracking may have reset). Finish this session and use Continue again so new rooms land in the right place."
    }
  }

  private func loadPriorPhotos() {
    let snapshot = house, zone = plan.zoneID, session = plan.sessionID
    Task.detached(priority: .utility) { [weak self] in
      let photos = PriorPhotos.load(house: snapshot, zone: zone, excludingSession: session)
      await self?.priorPhotosLoaded(photos)
    }
  }

  private func priorPhotosLoaded(_ photos: [CoverageEngine.Photo]) {
    guard alignment.method == "relocalized", !closed else { return }
    priorPhotos = photos
    priorPhotoCount = photos.count
    engine.add(contentsOf: photos)
    diagnostics.log("coverage: \(photos.count) earlier photos", since: startedAt)
  }

  private func saveAlignment() {
    do {
      house = try HouseProject.modify(house.id) { $0.setAlignment(session: plan.sessionID, alignment) }
    } catch {
      lastWarning = "Couldn't update house.json: \(error.localizedDescription)"
    }
  }

  private func show(notice text: String) {
    notice = text
    noticeTask?.cancel()
    noticeTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(6))
      guard !Task.isCancelled else { return }
      self?.notice = nil
    }
  }

  // MARK: - Room lifecycle

  private var lastProgressPercent = 0
  private var lastCoverageProgress = Date()
  var coveragePlateau: Bool {
    guard let started = roomStartedAt else { return false }
    return !paused && captureReady && stats.percent >= 65 && Date().timeIntervalSince(started) > 120 && Date().timeIntervalSince(lastCoverageProgress) > 45
  }
  private var memoryPressureUntil: TimeInterval = 0
  var captureBudget: CaptureBudget { CaptureBudget(thermal: ProcessInfo.processInfo.thermalState, photos: roomPhotoCount, memoryPressure: CACurrentMediaTime() < memoryPressureUntil) }
  var quality: CaptureQuality { CaptureQuality(percent: stats.percent, walls: coverage.walls.count, photos: roomPhotoCount) }
  var recoveryPhoto: URL? { photos.last.map { bundle.file($0.file) } }
  var reviewSource: PreviewSource? {
    guard let last = rooms.last, let session = house.session(plan.sessionID) else { return nil }
    var source = PreviewSource.session(house, session)
    source.rooms = source.rooms.filter { $0.index == last.index }
    source.title = last.name
    return source
  }
  var requiresFreshScan: Bool { warnedBigMap || rooms.count >= 4 }

  var selectedRoomID: String?
  var existingRooms: [HouseProject.Room] { house.rooms.filter { r in !r.history.contains { $0.session == plan.sessionID } } }
  func selectRoom(_ room: HouseProject.Room) {
    roomName = room.name
    selectedRoomID = room.id
  }
  var canStartRoom: Bool { phase == .betweenRooms && !sessionNeedsRestart && !recordingSaveFailed && !requiresFreshScan && !roomName.trimmingCharacters(in: .whitespaces).isEmpty }

  func startRoom() {
    guard canStartRoom else { return }
    do { try CaptureReadiness.requireStorage(at: bundle.url) }
    catch { lastWarning = error.localizedDescription; return }
    recovery = TrackingRecovery()
    trackingIssue = recovery.issue
    meshReadyAt = nil
    preStopMesh = nil
    lastWarning = nil
    instruction = nil
    liveRoom = nil
    meshReady = false
    paused = false
    scanView.feed.isOn = false
    roomStartedAt = Date()
    lastCoverageProgress = Date()
    lastProgressPercent = 0
    roomPhotoCount = 0
    hint = .none
    engine.setRoom(nil)
    scanView.showRoom(nil)
    phase = .scanning
    applyGhostOpacity()
    refreshCoverage()
    diagnostics.log("room \(roomIndex) '\(roomName)' start", since: startedAt)
    diagnostics.log("permissions camera=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue) location=\(compass.authorizationStatus); worldTrackingSupported=\(ARWorldTrackingConfiguration.isSupported) roomPlanSupported=\(Self.isSupported)", since: startedAt)
    roomSession.run(configuration: RoomCaptureSession.Configuration())
    sessionRunning = true
    UIApplication.shared.isIdleTimerDisabled = true
    startTicking()
  }

  /// Done with this room: RoomPlan builds it, the mesh is exported. The ARSession keeps
  /// running (mesh and all) so the next room lands in the same world.
  func finishRoom() {
    guard phase == .scanning else { return }
    if paused { resume() }
    commitCandidate(allowHighResolution: false)
    phase = .finishingRoom
    compass.stop()
    scanView.feed.isOn = false // freeze accepted mesh input for the export barrier
    // export the mesh while it's all still there, then let RoomPlan wrap up (didEndWith → finish)
    let file = bundle.file("mesh/room-\(roomIndex).ply")
    Task {
      await drainPhotos()
      guard !closed, phase == .finishingRoom else { return }
      preStopMesh = await withCheckedContinuation { c in engine.exportPLY(to: file) { c.resume(returning: $0) } }
      guard !closed, phase == .finishingRoom else { return }
      cameraControl.unlock()
      roomSession.stop(pauseARSession: false)
    }
  }

  // MARK: pause / resume

  /// Stop auto photos, depth recording and coverage updates; tracking (and RoomPlan) keep going
  func pause() {
    guard phase == .scanning, !paused else { return }
    paused = true
    compass.stop()
    candidate = nil
    scanView.feed.isOn = false
    diagnostics.log("pause", since: startedAt)
  }

  func resume() {
    guard paused else { return }
    do { try CaptureReadiness.requireStorage(at: bundle.url) }
    catch { lastWarning = error.localizedDescription; return }
    paused = false
    previousPose = nil // no blur estimate across the gap
    scanView.feed.isOn = captureReady
    if captureReady { scanView.refeedEngine(from: arSession) } // the mesh kept growing while paused
    diagnostics.log("resume", since: startedAt)
  }

  nonisolated func captureSession(_ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration) {
    Task { @MainActor in self.diagnostics.log("RoomPlan started", since: self.startedAt) }
  }

  nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
    Task { @MainActor in self.liveRoomUpdated(room) }
  }

  nonisolated func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
    Task { @MainActor in self.instruction = Self.describe(instruction) }
  }

  nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {
    Task { @MainActor in await self.finish(with: data, error: error) }
  }

  private func finish(with data: CapturedRoomData, error: Error?) async {
    // .scanning: RoomPlan ended on its own (tracking failure, scene too big): keep what it has
    guard !closed, phase == .finishingRoom || phase == .scanning else { return }
    if error != nil { sessionNeedsRestart = true }
    if phase == .scanning {
      commitCandidate(allowHighResolution: false)
      cameraControl.unlock()
      if paused { resume() }
      phase = .finishingRoom
    }
    if let error {
      lastWarning = "Scanning stopped: \(error.localizedDescription). Saving what is available. Finish this session before starting a new capture."
      diagnostics.log("RoomPlan ended with error: \(error.localizedDescription)", since: startedAt)
      diagnostics.recordFailure(source: "RoomPlan", chain: Diagnostics.errorChain(error), since: startedAt)
      sampleDiagnostics(force: true)
    }
    scanView.feed.isOn = false
    await drainPhotos()
    guard !closed else { return }
    let index = roomIndex
    let capturedAt = Date()
    var record = RoomRecord(
      index: index, name: roomName.trimmingCharacters(in: .whitespaces), file: "rooms/room-\(index).json",
      usdz: "rooms/room-\(index).usdz", capturedAt: capturedAt, walls: 0, doors: 0, windows: 0, openings: 0, objects: 0)
    // raw capture data first: RoomBuilder can be re-run on it later even if it fails now
    let dataFile = bundle.file("rooms/room-\(index)-data.json")
    let savedData = await Task.detached(priority: .utility) { () -> Bool in
      guard let json = try? ScanBundle.encodeRoomData(data) else { return false }
      return (try? json.write(to: dataFile, options: .atomic)) != nil
    }.value
    if savedData { record.data = "rooms/room-\(index)-data.json" }
    do {
      let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
      try bundle.saveRoom(room, index: index)
      record.walls = room.walls.count
      record.doors = room.doors.count
      record.windows = room.windows.count
      record.openings = room.openings.count
      record.objects = room.objects.count
      capturedRooms.append(room)
      engine.setRoom(room)
      scanView.showRoom(room)
    } catch {
      lastWarning = "RoomPlan couldn't build the layout (\(error.localizedDescription)). The mesh and photos are still saved."
      record.file = "" // no layout for this room; capturedRooms only holds rooms RoomPlan built
      record.usdz = ""
    }
    let meshFile = "mesh/room-\(index).ply"
    var result = preStopMesh
    if case .success(let r)? = result, r.vertices > 0 {} else {
      result = await withCheckedContinuation { c in engine.exportPLY(to: bundle.file(meshFile)) { c.resume(returning: $0) } }
    }
    if case .success(let r)? = result, r.vertices > 0 {
      record.mesh = MeshRecord(file: meshFile, anchors: 0, vertices: r.vertices, faces: r.faces)
      record.coverage = r.covered
    }
    record.photoCoverage = record.photographedPercent
    record.detailSeconds = roomStartedAt.map { Date().timeIntervalSince($0) }
    record.detailPhotos = roomPhotoCount
    rooms.append(record)
    pendingRoomIDs[index] = selectedRoomID
    do {
      try depthRecorder.save()
      try bundle.savePhotos(photos)
    } catch {
      recordingSaveFailed = true
      lastWarning = "Some recording files could not be saved: \(error.localizedDescription). Free storage and finish the session to retry."
    }
    do {
      house = try HouseProject.modify(house.id) {
        $0.recordRoomScan(name: record.name, session: plan.sessionID, index: index, capturedAt: capturedAt, roomID: selectedRoomID, matchName: false)
      }
    } catch {
      recordingSaveFailed = true
      lastWarning = "Couldn't add \(record.name) to house.json: \(error.localizedDescription)"
    }
    diagnostics.log("room \(index) '\(record.name)' saved: \(record.walls) walls, mesh \(record.mesh?.vertices ?? 0) v", since: startedAt)
    do { try writeManifest() }
    catch {
      recordingSaveFailed = true
      lastWarning = "The scan index could not be saved: \(error.localizedDescription). Free storage and finish the session to retry."
    }
    // keep the zone's map current, so a crash later doesn't cost the whole session's alignment
    await saveWorldMap(final: false)
    roomName = ""
    selectedRoomID = nil
    phase = .betweenRooms
    applyGhostOpacity()
    refreshCoverage()
  }

  /// Throws away the most recently captured room (e.g. to rescan it).
  func discardLastRoom() {
    guard phase == .betweenRooms, let last = rooms.popLast() else { return }
    if !last.file.isEmpty { capturedRooms.removeLast() }
    bundle.deleteRoom(index: last.index)
    try? FileManager.default.removeItem(at: bundle.file("mesh/room-\(last.index).ply"))
    for photo in photos where photo.room == last.index {
      try? FileManager.default.removeItem(at: bundle.file(photo.file))
    }
    photos.removeAll { $0.room == last.index }
    compass.discard(room: last.index)
    photoViews.removeAll { $0.room == last.index }
    enginePhotos.removeAll { $0.room == last.index }
    engine.reset(photos: priorPhotos + enginePhotos)
    depthRecorder.discard(room: last.index)
    photoCount = photos.count
    roomName = last.name
    do {
      house = try HouseProject.modify(house.id) { $0.removeRoomScan(session: plan.sessionID, index: last.index) }
    } catch {
      lastWarning = "Couldn't update house.json: \(error.localizedDescription)"
    }
    try? bundle.savePhotos(photos)
    try? depthRecorder.save()
    try? writeManifest()
    diagnostics.log("room \(last.index) discarded", since: startedAt)
    refreshCoverage()
  }

  // MARK: - Finish

  func finishSession() async {
    let retrying: Bool
    if case .failed = phase { retrying = true } else { retrying = false }
    guard phase == .betweenRooms || retrying else { return }
    phase = .finishing
    applyGhostOpacity()
    finishingStep = "Saving the map: keep the camera moving slowly…"
    if !retrying { await saveWorldMap(final: true) }
    stopTicking()
    compass.stop()
    arSession.pause()
    sessionRunning = false
    UIApplication.shared.isIdleTimerDisabled = false
    endedAt = Date()

    finishingStep = "Saving…"
    do {
      try bundle.savePhotos(photos)
      try depthRecorder.save()
      try writeManifest()
      house = try HouseProject.modify(house.id) {
        for room in rooms where !$0.rooms.contains(where: { r in r.history.contains { $0.session == plan.sessionID && $0.index == room.index } }) {
          $0.recordRoomScan(name: room.name, session: plan.sessionID, index: room.index, capturedAt: room.capturedAt, roomID: pendingRoomIDs[room.index], matchName: false)
        }
        $0.setAlignment(session: plan.sessionID, alignment)
        $0.endSession(plan.sessionID, at: endedAt ?? Date())
      }
    } catch {
      phase = .failed(error.localizedDescription)
      return
    }

    // RoomPlan merges last: it's slow, and everything above is already safe on disk
    finishingStep = "Merging rooms…"
    var structureFile: String?
    var structureError: String?
    if !capturedRooms.isEmpty {
      do {
        let structure = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: capturedRooms)
        try bundle.saveStructure(structure)
        structureFile = "structure.json"
      } catch {
        structureError = error.localizedDescription
      }
    }
    await buildZoneStructure()
    try? writeManifest(structure: structureFile, structureError: structureError)
    phase = .done
  }

  /// All active rooms of the zone that are in the zone frame, merged by RoomPlan into
  /// zones/<zone>/structure.usdz (only rooms whose sessions share the frame, or StructureBuilder
  /// throws invalidRoomLocation). A preview product; errors only get logged.
  private func buildZoneStructure() async {
    let zone = plan.zoneID
    let frameSessions = Set(house.sessionsInZone(zone).filter { HouseProject.zoneFrameMethods.contains($0.alignment.method) }.map(\.id))
    guard frameSessions.contains(plan.sessionID) else { return }
    let refs = house.roomsInZone(zone).compactMap(\.active).filter { frameSessions.contains($0.session) }
    guard Set(refs.map(\.session)).count >= 2 else { return } // same as this session's structure.json
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var list: [CapturedRoom] = []
    for ref in refs {
      guard let s = house.session(ref.session),
            let data = try? Data(contentsOf: house.bundle(for: s).file("rooms/room-\(ref.index).json")),
            let room = try? decoder.decode(CapturedRoom.self, from: data) else { continue }
      list.append(room)
    }
    guard list.count >= 2 else { return }
    do {
      let structure = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: list)
      try ScanBundle.saveStructure(structure, in: house.url.appendingPathComponent("zones/\(zone)", isDirectory: true))
      diagnostics.log("zone structure: \(list.count) rooms", since: startedAt)
    } catch {
      diagnostics.log("zone structure failed (\(list.count) rooms): \(error.localizedDescription)", since: startedAt)
    }
  }

  /// Leave without saving anything: the session disappears from the house.
  func abandon() {
    closed = true
    compass.stop()
    stopTicking()
    if roomSessionCreated, phase == .scanning || phase == .finishingRoom { roomSession.stop() }
    arSession.pause()
    sessionRunning = false
    UIApplication.shared.isIdleTimerDisabled = false
    try? HouseProject.deleteSession(houseID: house.id, sessionID: plan.sessionID)
  }

  // MARK: - World map

  /// Saves the session's ARWorldMap into the bundle and, if this session is in the zone frame,
  /// as the zone's map. Only once ARKit calls the map `.mapped` (`.extending` is accepted with
  /// a note: it relocalizes less reliably); the final save waits a few seconds for `.mapped`.
  private func saveWorldMap(final: Bool) async {
    while mapSaving { try? await Task.sleep(for: .milliseconds(100)) }
    guard sessionRunning else { return }
    if final {
      for _ in 0..<30 {
        if arSession.currentFrame?.worldMappingStatus == .mapped { break }
        try? await Task.sleep(for: .milliseconds(200))
      }
    }
    let status = arSession.currentFrame?.worldMappingStatus ?? .notAvailable
    guard status == .mapped || status == .extending else {
      if !worldMapSaved { // an earlier save of this session still stands otherwise
        worldMapStatus = "not saved: mapping status \(WorldMapFile.describe(status))"
        mapSummary = "Map not saved yet (ARKit: \(WorldMapFile.describe(status)))"
      }
      diagnostics.log("world map \(final ? "final " : "")skipped: \(WorldMapFile.describe(status))", since: startedAt)
      return
    }
    mapSaving = true
    defer { mapSaving = false }
    let result: Result<ARWorldMap, Error> = await withCheckedContinuation { k in
      arSession.getCurrentWorldMap { map, error in
        if let map { k.resume(returning: .success(map)) } else { k.resume(returning: .failure(error ?? CocoaError(.fileWriteUnknown))) }
      }
    }
    guard case .success(let map) = result else {
      if case .failure(let e) = result { diagnostics.log("getCurrentWorldMap failed: \(e.localizedDescription)", since: startedAt) }
      return
    }
    let zoneFrame = HouseProject.zoneFrameMethods.contains(alignment.method)
    let zonePath = WorldMapFile.zoneRelativePath(plan.zoneID)
    var targets = [bundle.file(WorldMapFile.sessionFile)]
    if zoneFrame { targets.append(house.url.appendingPathComponent(zonePath)) }
    let written = await Task.detached(priority: .utility) { Result { try WorldMapFile.write(map, to: targets) } }.value
    switch written {
    case .success(let bytes):
      worldMapSaved = true
      worldMapStatus = status == .mapped ? "mapped" : "extending (saved before ARKit finished mapping: may relocalize less reliably)"
      let mb = Double(bytes) / 1_000_000
      mapSummary = String(format: "Map saved (%.0f MB%@)", mb, status == .mapped ? "" : ", still extending")
      diagnostics.log(String(format: "world map saved: %@ %.1f MB features %d%@", WorldMapFile.describe(status), mb, map.rawFeaturePoints.points.count, zoneFrame ? " (zone map)" : ""), since: startedAt)
      if zoneFrame {
        do {
          house = try HouseProject.modify(house.id) { $0.setWorldMap(zone: plan.zoneID, path: zonePath) }
        } catch {
          lastWarning = "Couldn't update house.json: \(error.localizedDescription)"
        }
      }
      if mb > 40, !warnedBigMap {
        warnedBigMap = true
        lastWarning = "Finish and save this scan before scanning another room. The next scan will start fresh to keep capture responsive."
      }
    case .failure(let e):
      diagnostics.log("world map write failed: \(e.localizedDescription)", since: startedAt)
      lastWarning = "Couldn't save the world map: \(e.localizedDescription)"
    }
  }

  private func writeManifest(structure: String? = nil, structureError: String? = nil) throws {
    let existing = structure == nil ? bundle.manifest : nil
    try bundle.saveCompass(compass.records)
    try bundle.writeManifest(Manifest(
      format: Manifest.currentFormat,
      createdAt: startedAt,
      device: UIDevice.modelIdentifier,
      systemVersion: UIDevice.current.systemVersion,
      house: house.id,
      houseName: house.name,
      session: plan.sessionID,
      zone: plan.zoneID,
      alignment: alignment,
      worldMap: worldMapSaved ? WorldMapFile.sessionFile : nil,
      worldMapStatus: worldMapStatus,
      endedAt: endedAt,
      rooms: rooms,
      structure: structure ?? existing?.structure,
      structureError: structureError ?? existing?.structureError,
      mesh: nil,
      sceneReconstruction: diagnostics.detailConfiguration,
      photos: "photos/photos.json",
      photoCount: photos.count,
      depthFrames: depthRecorder.records.isEmpty ? nil : "depth/frames.json",
      depthFrameCount: depthRecorder.records.count,
      diagnostics: diagnostics,
      compass: compass.records.isEmpty ? nil : "compass/headings.json",
      compassSampleCount: compass.records.isEmpty ? nil : compass.records.count
    ))
  }

  // MARK: - Live room + coverage

  private func liveRoomUpdated(_ room: CapturedRoom) {
    guard phase == .scanning else { return }
    liveRoom = room
    refreshCoverage()
    scanView.showRoom(room)
    // RoomPlan's surfaces feed the coverage engine too (areas the LiDAR hasn't reached yet)
    let now = CACurrentMediaTime()
    if now - lastRoomToEngine > 2 {
      lastRoomToEngine = now
      engine.setRoom(room)
    }
  }

  /// While scanning: the live room over earlier rooms in grey. Otherwise: the
  /// latest finished room, so you can see what's left.
  private func refreshCoverage() {
    let views = photoViews.map(\.view)
    if phase == .scanning || phase == .finishingRoom {
      coverage = Coverage(room: liveRoom, previous: capturedRooms, photos: views)
    } else {
      coverage = Coverage(room: capturedRooms.last, previous: Array(capturedRooms.dropLast()), photos: views)
    }
  }

  var photoPositions: [SIMD2<Float>] {
    let room = phase == .scanning ? roomIndex : max(0, roomIndex - 1)
    return photoViews.filter { $0.room == room }.map { SIMD2($0.view.position.x, $0.view.position.z) }
  }

  /// RoomPlan's configuration has LiDAR reconstruction running internally but doesn't
  /// hand out mesh anchors or depth. Adding them to *its* configuration keeps RoomPlan
  /// working (tested on device), and RoomPlan may drop depth when it reconfigures, so
  /// this runs every half second while scanning. Never resets tracking, and never carries a
  /// world map (that would start relocalizing all over again).
  private func ensureMeshAndDepth() {
    // Leave RoomPlan's camera/VIO configuration alone while ARKit is still
    // establishing a world frame.
    guard captureReady, !paused else { return }
    guard let c = arSession.configuration as? ARWorldTrackingConfiguration else { return }
    let depthOK = !ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) || c.frameSemantics.contains(.sceneDepth)
    let meshOK = c.sceneReconstruction.contains(.meshWithClassification)
    if meshOK, depthOK {
      if !meshReady {
        meshReady = true
        meshReadyAt = CACurrentMediaTime()
        diagnostics.detailConfiguration = "\(type(of: c)) reconstruction=\(c.sceneReconstruction.rawValue) semantics=\(c.frameSemantics.rawValue) video=\(Int(c.videoFormat.imageResolution.width))x\(Int(c.videoFormat.imageResolution.height)) worldMap=\(c.initialWorldMap != nil)"
      }
      return
    }
    guard let updated = c.copy() as? ARWorldTrackingConfiguration else { return }
    if diagnostics.roomPlanConfiguration == nil {
      diagnostics.roomPlanConfiguration = "\(type(of: c)) reconstruction=\(c.sceneReconstruction.rawValue) semantics=\(c.frameSemantics.rawValue) worldMap=\(c.initialWorldMap != nil)"
    }
    updated.initialWorldMap = nil
    updated.sceneReconstruction.insert(.meshWithClassification)
    if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { updated.frameSemantics.insert(.sceneDepth) }
    meshReady = false
    diagnostics.configurationChanges = (diagnostics.configurationChanges ?? 0) + 1
    diagnostics.log("enable mesh/depth #\(diagnostics.configurationChanges!): reconstruction \(c.sceneReconstruction.rawValue)→\(updated.sceneReconstruction.rawValue), semantics \(c.frameSemantics.rawValue)→\(updated.frameSemantics.rawValue)", since: startedAt)
    arSession.run(updated, options: []) // no reset: same world, RoomPlan keeps going
  }

  @objc private func memoryWarning() {
    guard !closed else { return }
    memoryPressureUntil = CACurrentMediaTime() + 60
    candidate = nil
    diagnostics.memoryWarnings = (diagnostics.memoryWarnings ?? 0) + 1
    diagnostics.log("memory warning", since: startedAt)
    sampleDiagnostics(force: true)
  }

  @objc private func thermalChanged() {
    guard !closed else { return }
    diagnostics.log("thermal " + Diagnostics.thermalDescription(ProcessInfo.processInfo.thermalState), since: startedAt)
    sampleDiagnostics(force: true)
  }

  /// Runs even when ARKit stops delivering new frames, to expose a stalled session.
  private func sampleDiagnostics(force: Bool = false) {
    let now = CACurrentMediaTime()
    guard !closed, force || now - lastDiagnosticSample >= 5 else { return }
    lastDiagnosticSample = now
    if phase == .scanning, !paused, let available = CaptureReadiness.available(at: bundle.url), available < CaptureReadiness.pauseReserve {
      pause()
      lastWarning = "Storage is almost full. Recording is paused. Finish this room to save what is available, then free space before continuing."
    }
    let frame = arSession.currentFrame
    let levels = frame.flatMap { Diagnostics.cameraLevels($0.capturedImage) }
    let meshes = frame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
    diagnostics.recordSample(.init(
      t: Date().timeIntervalSince(startedAt), phase: "\(phase)",
      thermal: Diagnostics.thermalDescription(ProcessInfo.processInfo.thermalState),
      memoryMB: Diagnostics.memoryFootprintMB(),
      frameAgeSeconds: frame.map { max(0, now - $0.timestamp) },
      tracking: frame.map { Self.describeTracking($0.camera.trackingState) },
      mapping: frame.map { WorldMapFile.describe($0.worldMappingStatus) },
      featurePoints: frame?.rawFeaturePoints?.points.count ?? 0,
      meshAnchors: meshes.count, meshVertices: meshes.reduce(0) { $0 + $1.geometry.vertices.count },
      photos: photos.count, depthFrames: depthRecorder.records.count, photosInFlight: photosInFlight,
      coverageQueueDelayMS: coverageQueueDelayMS,
      pendingMeshUpdates: engine.pendingMeshUpdates, coalescedMeshUpdates: engine.coalescedMeshUpdates,
      cameraAuthorization: Int(AVCaptureDevice.authorizationStatus(for: .video).rawValue),
      locationAuthorization: compass.authorizationStatus,
      cameraWidth: frame.map { CVPixelBufferGetWidth($0.capturedImage) },
      cameraHeight: frame.map { CVPixelBufferGetHeight($0.capturedImage) },
      cameraPixelFormat: frame.map { CVPixelBufferGetPixelFormatType($0.capturedImage) },
      cameraLumaMean: levels?.mean, cameraLumaMin: levels?.min, cameraLumaMax: levels?.max))
    print("CAPTURE: cameraAuth=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue) locationAuth=\(compass.authorizationStatus) tracking=\(frame.map { Self.describeTracking($0.camera.trackingState) } ?? "no frame") features=\(frame?.rawFeaturePoints?.points.count ?? 0) luma=\(levels.map { String(format: "%.1f [%d,%d]", $0.mean, $0.min, $0.max) } ?? "unavailable")")
    if !coverageProbePending {
      coverageProbePending = true
      engine.measureQueueDelay { [weak self] delay in
        guard let self else { return }
        self.coverageProbePending = false
        self.coverageQueueDelayMS = delay
      }
    }
    // Serial atomic checkpoints also survive an unfinished room; no photos or frame buffers retained.
    let url = bundle.file("diagnostics.json")
    if let data = try? JSONEncoder().encode(diagnostics) {
      diagnosticWriter.async { try? data.write(to: url, options: .atomic) }
    }
  }

  /// World-mapping status + tracking state changes, for the HUD and the diagnostics log
  private func trackStatus(_ frame: ARFrame) {
    let status = frame.worldMappingStatus
    if status != mappingStatus { mappingStatus = status }
    if status != lastMappingLog {
      lastMappingLog = status
      diagnostics.log("mapping \(WorldMapFile.describe(status))", since: startedAt)
    }
    let tracking = Self.describeTracking(frame.camera.trackingState)
    if tracking != lastTrackingLog {
      lastTrackingLog = tracking
      diagnostics.log("tracking \(tracking)", since: startedAt)
    }
  }

  nonisolated static func trackingText(_ state: ARCamera.TrackingState) -> String {
    switch state {
    case .normal: "Tracking"
    case .notAvailable: "Camera starting…"
    case .limited(.initializing): "Getting started: move the phone slowly"
    case .limited(.relocalizing): "Looking for a place it knows…"
    case .limited(.excessiveMotion): "Slow down"
    case .limited(.insufficientFeatures): "Not enough detail here: aim at furniture, doorways, corners"
    case .limited: "Tracking limited"
    }
  }

  // MARK: - Photos

  /// A frame worth keeping, held until a sharper one of the same view comes along.
  /// The pixel buffer is copied so ARKit's frame pool isn't starved.
  fileprivate struct Shot: @unchecked Sendable { // pixel buffers are safe to hand across threads
    var buffer: CVPixelBuffer
    var transform: simd_float4x4
    var intrinsics: simd_float3x3
    var resolution: CGSize
    var timestamp: TimeInterval
    var tracking: String
    var exposure: TimeInterval
    /// predicted motion blur in pixels (0 for manual stills we don't measure)
    var blur: Float
    var depth: CoverageEngine.DepthGrid?
    var highRes = false
    var camera: CameraState?
  }

  func takePhoto() {
    guard canTakePhoto, let frame = arSession.currentFrame,
          CACurrentMediaTime() - frame.timestamp < 0.5,
          case .normal = frame.camera.trackingState,
          let buffer = Self.copy(frame.capturedImage) else { return }
    candidate = nil
    var shot = Shot(frame: frame, buffer: buffer, blur: lastBlur ?? 0)
    shot.depth = DepthRecorder.grid(for: frame)
    shot.camera = cameraControl.state(for: frame)
    save(shot, manual: true)
  }

  /// Wait for accepted JPEG writes. A still request has a timeout; late callbacks are
  /// invalidated so they cannot attach a photo to the next room.
  private func drainPhotos() async {
    let deadline = CACurrentMediaTime() + 3
    while highResInFlight && CACurrentMediaTime() < deadline && !closed {
      try? await Task.sleep(for: .milliseconds(50))
    }
    if highResInFlight {
      highResRequestID = nil
      highResInFlight = false
      diagnostics.log("high-resolution request timed out while finishing", since: startedAt)
    }
    while photosInFlight > 0 && !closed {
      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  private func updateRecovery(_ frame: ARFrame?, now: TimeInterval) {
    guard phase == .scanning else { return }
    let wasReady = recovery.canCapture
    let problem: TrackingRecovery.Issue?
    if sessionInterrupted { problem = .interrupted }
    else if let frame, now - frame.timestamp < 0.5 { problem = TrackingRecovery.problem(for: frame.camera.trackingState) }
    else { problem = .stalled }
    recovery.update(problem: problem, now: now)
    if trackingIssue != recovery.issue {
      trackingIssue = recovery.issue
      diagnostics.log("capture tracking: \(trackingIssue.map { String(describing: $0) } ?? "ready")", since: startedAt)
    }
    scanView.feed.isOn = !paused && captureReady
    if !captureReady { candidate = nil }
    if wasReady && !recovery.canCapture {
      UINotificationFeedbackGenerator().notificationOccurred(.warning)
    } else if !wasReady && recovery.canCapture && !sessionNeedsRestart {
      previousPose = nil
      poseHistory.removeAll()
      if !paused { scanView.refeedEngine(from: arSession) }
      show(notice: paused ? "Tracking recovered. Tap Resume when ready." : "Tracking recovered. Continue slowly.")
    }
  }

  private func startTicking() {
    guard displayLink == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(onDisplayLink))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    link.add(to: .main, forMode: .common)
    displayLink = link
    previousPose = nil
    candidate = nil
  }

  private func stopTicking() {
    displayLink?.invalidate()
    displayLink = nil
    cameraPose = nil
  }

  @objc private func onDisplayLink() {
    sampleDiagnostics()
    updateRecovery(arSession.currentFrame, now: CACurrentMediaTime())
    if !captureReady { compass.clearPoses() }
    guard let frame = arSession.currentFrame, frame.timestamp != previousPose?.time else { return }
    let now = CACurrentMediaTime()
    trackStatus(frame)
    let pose = frame.camera.transform
    if let prev = previousPose {
      lastBlur = Self.predictedBlur(frame: frame, previous: prev)
      // a big jump between consecutive frames means ARKit re-localized or reset the world
      let jump = simd_distance(pose.columns.3, prev.pose.columns.3)
      if jump > 0.5, frame.timestamp - prev.time < 0.2 {
        diagnostics.worldJumps.append(.init(time: frame.timestamp, meters: jump, phase: "\(phase)"))
      }
    }
    previousPose = (frame.timestamp, pose)
    poseHistory.append((frame.timestamp, pose))
    if poseHistory.count > 90 { poseHistory.removeFirst(poseHistory.count - 90) }
    if frame.timestamp - lastPosePublish > 1.0 / 15 { // the map doesn't need 60 Hz
      cameraPose = pose
      lastPosePublish = frame.timestamp
    }
    if phase == .relocalizing {
      tickRelocalization(frame, now: now)
      return
    }
    // relocalized: keep checking the live mesh against the saved one
    if alignment.method == "relocalized", let reference, !reference.isEmpty, !paused, !checkInFlight,
       phase == .betweenRooms || phase == .scanning, now - lastCheckAt > 2.5, case .normal = frame.camera.trackingState {
      runCheck(frame, reference: reference)
    }
    guard phase == .scanning else { return }
    if frame.timestamp - lastMeshCheck > 0.5 {
      lastMeshCheck = frame.timestamp
      ensureMeshAndDepth()
    }
    if !cameraControl.whiteBalanceLocked, let t = meshReadyAt, now - t > 3 {
      cameraControl.lockWhiteBalance()
      diagnostics.whiteBalance = cameraControl.summary
    }
    guard !paused, captureReady else { return }
    if recordDirections {
      compass.start()
      compass.observe(frame, room: roomIndex)
    }
    let budget = captureBudget
    depthRecorder.consider(frame, room: roomIndex, camera: cameraControl.state(for: frame), interval: budget.depthInterval)
    if frame.timestamp - lastEvaluate > budget.evaluationInterval {
      lastEvaluate = frame.timestamp
      engine.evaluate(view: Self.enginePhoto(frame: frame, sharpness: 1, depth: nil, room: roomIndex))
      if engine.latestHint != hint { hint = engine.latestHint }

    }
    if let blur = lastBlur { autoPhoto(frame, blur: blur) }
  }

  /// How far the image smears during this frame's exposure, in pixels: rotation
  /// speed × exposure × focal length, plus translation assuming things ~2 m away.
  /// Computed from ARKit's poses, so it costs nothing per frame.
  private static func predictedBlur(frame: ARFrame, previous: (time: TimeInterval, pose: simd_float4x4)) -> Float {
    let dt = Float(frame.timestamp - previous.time)
    guard dt > 0 else { return .infinity }
    let q0 = simd_quatf(previous.pose), q1 = simd_quatf(frame.camera.transform)
    let delta = q0.inverse * q1
    let angle = 2 * acos(min(1, abs(delta.real)))
    let moved = simd_distance(previous.pose.columns.3, frame.camera.transform.columns.3)
    let exposure = Float(frame.camera.exposureDuration > 0 ? frame.camera.exposureDuration : 1.0 / 60)
    let focal = frame.camera.intrinsics.columns.0.x
    return focal * exposure * (angle / dt + (moved / dt) / 2)
  }

  /// Blur for a frame that isn't the latest (a high-res still): camera motion from the pose history
  private func blur(at time: TimeInterval, for frame: ARFrame) -> Float? {
    guard let after = poseHistory.firstIndex(where: { $0.time >= time }), after > 0 else { return nil }
    let a = poseHistory[after - 1], b = poseHistory[after]
    let dt = Float(b.time - a.time)
    guard dt > 0 else { return nil }
    let angle = 2 * acos(min(1, abs((simd_quatf(a.pose).inverse * simd_quatf(b.pose)).real)))
    let moved = simd_distance(a.pose.columns.3, b.pose.columns.3)
    let exposure = Float(frame.camera.exposureDuration > 0 ? frame.camera.exposureDuration : 1.0 / 60)
    return frame.camera.intrinsics.columns.0.x * exposure * (angle / dt + (moved / dt) / 2)
  }

  /// Shoot where it pays off. Once there's mesh (or RoomPlan surfaces) to score against,
  /// the engine estimates how much red the current view would turn green; before that,
  /// any new viewpoint counts. Either way, hold the sharpest frame of that view.
  private func autoPhoto(_ frame: ARFrame, blur: Float) {
    guard autoPhotos, photosInFlight == 0, !highResInFlight, case .normal = frame.camera.trackingState else { return }
    let view = PhotoView(transform: frame.camera.transform)
    if resolveCandidate(frame: frame, view: view) { return }
    guard frame.timestamp - lastPhotoTime > captureBudget.photoInterval, blur <= Self.acceptableBlur else { return }
    let recent = photoViews.suffix(8)
    guard recent.allSatisfy({ simd_distance($0.view.position, view.position) > 0.12 || simd_dot($0.view.forward, view.forward) < cos(Float.pi / 18) }) else { return }
    if stats.meshArea > 0.5 || stats.targetsCovered > 0 || liveRoom != nil {
      guard engine.latestGain > Self.minimumGain else { return }
    } else {
      guard abs(view.forward.y) < 0.75 else { return }
      let isNew = photoViews.allSatisfy { simd_distance($0.view.position, view.position) > 0.5 || simd_dot($0.view.forward, view.forward) < cos(Float.pi / 7) }
      guard isNew else { return }
    }
    hold(frame, blur: blur)
  }

  /// Save the held frame once it's sharp enough, or once you've moved on from that view.
  /// Returns true if it handled this tick.
  private func resolveCandidate(frame: ARFrame, view: PhotoView) -> Bool {
    guard let held = candidate else { return false }
    let heldView = PhotoView(transform: held.transform)
    let movedOn = simd_distance(heldView.position, view.position) > 0.3 || simd_dot(heldView.forward, view.forward) < cos(Float.pi / 12)
    let stale = frame.timestamp - held.timestamp > 1.2
    guard held.blur <= Self.sharpBlur || movedOn || stale else { return false }
    commitCandidate()
    return true
  }

  private func hold(_ frame: ARFrame, blur: Float) {
    if let held = candidate, blur > held.blur * 0.8 { return } // only copy clearly better frames
    guard let copy = Self.copy(frame.capturedImage) else { return }
    var shot = Shot(frame: frame, buffer: copy, blur: blur)
    shot.depth = DepthRecorder.grid(for: frame)
    shot.camera = cameraControl.state(for: frame)
    candidate = shot
  }

  /// Save the held frame, trying for a full-resolution still of the same view first and
  /// keeping it if it came out at least as sharp (relative to its size).
  private func commitCandidate(allowHighResolution: Bool = true) {
    guard let held = candidate else { return }
    candidate = nil
    guard held.blur <= Self.acceptableBlur else { return }
    guard !captureBudget.constrained, allowHighResolution, highResolutionPhotos, highResSupported, !highResInFlight,
          captureReady, phase == .scanning,
          ProcessInfo.processInfo.thermalState == .nominal,
          CACurrentMediaTime() - lastHighResRequest >= 3 else {
      save(held, manual: false)
      return
    }
    highResInFlight = true
    lastHighResRequest = CACurrentMediaTime()
    let requestID = UUID()
    highResRequestID = requestID
    diagnostics.log("high-resolution photo requested", since: startedAt)
    arSession.captureHighResolutionFrame { [weak self] frame, error in
      Task { @MainActor in
        guard let self, self.highResRequestID == requestID else { return }
        self.highResInFlight = false
        self.highResRequestID = nil
        guard !self.closed, !self.paused, self.captureReady,
              self.phase == .scanning || self.phase == .finishingRoom else { return }
        guard let frame, let blur = self.blur(at: frame.timestamp, for: frame) else {
          if let error {
            self.highResSupported = false // don't keep asking
            self.diagnostics.recordFailure(source: "high-resolution photo", chain: Diagnostics.errorChain(error), since: self.startedAt)
            self.sampleDiagnostics(force: true)
          }
          self.save(held, manual: false)
          return
        }
        guard case .normal = frame.camera.trackingState else {
          self.save(held, manual: false)
          return
        }
        let relative = blur / Float(frame.camera.imageResolution.width) * 1920
        let heldView = PhotoView(transform: held.transform), hrView = PhotoView(transform: frame.camera.transform)
        let sameView = simd_distance(heldView.position, hrView.position) < 0.2 && simd_dot(heldView.forward, hrView.forward) > cos(Float.pi / 15)
        if frame.camera.imageResolution.width > held.resolution.width, relative <= max(held.blur, Self.sharpBlur) * 1.2, sameView {
          guard let buffer = Self.copy(frame.capturedImage) else {
            self.save(held, manual: false)
            return
          }
          var shot = Shot(frame: frame, buffer: buffer, blur: blur)
          shot.depth = held.depth // depth from the video frame a moment earlier (same view)
          shot.highRes = true
          shot.camera = self.cameraControl.state(for: frame)
          self.save(shot, manual: false)
        } else {
          self.save(held, manual: false)
        }
      }
    }
  }

  /// Under ~1.5 px of smear (at 1920 wide) is effectively sharp; up to 6 px is still usable.
  nonisolated private static let sharpBlur: Float = 1.5
  nonisolated private static let acceptableBlur: Float = 6
  /// m² of not-yet-covered surface a photo must add
  private static let minimumGain: Float = 0.06
  /// long edge of saved photos; full-res stills are scaled down to this
  private static let maxPhotoEdge: CGFloat = 3024

  private func save(_ shot: Shot, manual: Bool) {
    // auto photos wait their turn; manual taps always go through (within reason)
    guard !closed, phase == .scanning || phase == .finishingRoom,
          photosInFlight < (manual ? 3 : 1), !paused || manual else { return }
    photosInFlight += 1
    lastPhotoTime = shot.timestamp

    let fileName = String(format: "%04d.jpg", nextPhotoID)
    nextPhotoID += 1
    let scale = min(1, Self.maxPhotoEdge / max(shot.resolution.width, shot.resolution.height))
    var k = shot.intrinsics
    k.columns.0.x *= Float(scale); k.columns.1.y *= Float(scale); k.columns.2.x *= Float(scale); k.columns.2.y *= Float(scale)
    let size = CGSize(width: (shot.resolution.width * scale).rounded(), height: (shot.resolution.height * scale).rounded())
    let record = PhotoRecord(
      file: "photos/\(fileName)",
      room: roomIndex,
      timestamp: shot.timestamp,
      width: Int(size.width),
      height: Int(size.height),
      transform: shot.transform.columnMajor,
      intrinsics: k.columnMajor,
      tracking: shot.tracking,
      manual: manual,
      exposure: shot.exposure,
      blurPixels: manual ? nil : shot.blur * Float(scale),
      pass: "scan",
      highRes: shot.highRes,
      camera: shot.camera,
      compassTimestamp: recordDirections ? compass.nearest(to: shot.timestamp, room: roomIndex)?.timestamp : nil
    )
    let view = PhotoView(transform: shot.transform)
    let enginePhoto = CoverageEngine.Photo(
      worldToCamera: shot.transform.inverse, position: view.position,
      fx: k.columns.0.x, fy: k.columns.1.y, cx: k.columns.2.x, cy: k.columns.2.y,
      width: Float(size.width), height: Float(size.height),
      sharpness: Self.sharpness(blurAt1920: shot.blur / Float(shot.resolution.width) * 1920),
      depth: shot.depth, room: record.room)
    var image = CIImage(cvPixelBuffer: shot.buffer)
    if scale < 1 {
      let f = CIFilter.lanczosScaleTransform()
      f.inputImage = image
      f.scale = Float(scale)
      f.aspectRatio = 1
      image = f.outputImage ?? image
    }
    let url = bundle.file(record.file)
    let context = ciContext
    Task.detached(priority: .utility) {
      let ok = Self.writeJPEG(image, to: url, context: context)
      await MainActor.run {
        defer { self.photosInFlight -= 1 }
        guard !self.closed else { return }
        if ok {
          self.photos.append(record)
          self.photoViews.append((record.room, view))
          self.enginePhotos.append(enginePhoto)
          self.engine.add(enginePhoto)
          self.photoCount = self.photos.count
          self.roomPhotoCount += 1
          self.refreshCoverage()
        } else {
          self.lastWarning = "A photo could not be saved. Check available storage before continuing."
          self.diagnostics.log("JPEG write failed: \(record.file)", since: self.startedAt)
        }
      }
    }
  }

  nonisolated static func sharpness(blurAt1920 b: Float) -> Float {
    b <= sharpBlur ? 1 : max(0.4, 1 - (b - sharpBlur) / (acceptableBlur - sharpBlur) * 0.6)
  }

  fileprivate static func enginePhoto(frame: ARFrame, sharpness: Float, depth: CoverageEngine.DepthGrid?, room: Int) -> CoverageEngine.Photo {
    let k = frame.camera.intrinsics, t = frame.camera.transform
    return CoverageEngine.Photo(
      worldToCamera: t.inverse, position: simd_make_float3(t.columns.3),
      fx: k.columns.0.x, fy: k.columns.1.y, cx: k.columns.2.x, cy: k.columns.2.y,
      width: Float(frame.camera.imageResolution.width), height: Float(frame.camera.imageResolution.height),
      sharpness: sharpness, depth: depth, room: room)
  }

  nonisolated private static func copy(_ src: CVPixelBuffer) -> CVPixelBuffer? {
    var out: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    CVPixelBufferCreate(nil, CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src), CVPixelBufferGetPixelFormatType(src), attrs, &out)
    guard let dst = out else { return nil }
    CVPixelBufferLockBaseAddress(src, .readOnly)
    CVPixelBufferLockBaseAddress(dst, [])
    defer {
      CVPixelBufferUnlockBaseAddress(dst, [])
      CVPixelBufferUnlockBaseAddress(src, .readOnly)
    }
    for plane in 0..<CVPixelBufferGetPlaneCount(src) {
      guard let s = CVPixelBufferGetBaseAddressOfPlane(src, plane), let d = CVPixelBufferGetBaseAddressOfPlane(dst, plane) else { return nil }
      let rows = CVPixelBufferGetHeightOfPlane(src, plane)
      let sBytes = CVPixelBufferGetBytesPerRowOfPlane(src, plane), dBytes = CVPixelBufferGetBytesPerRowOfPlane(dst, plane)
      if sBytes == dBytes {
        memcpy(d, s, rows * sBytes)
      } else {
        for r in 0..<rows { memcpy(d + r * dBytes, s + r * sBytes, min(sBytes, dBytes)) }
      }
    }
    return dst
  }

  /// JPEG of the raw sensor image. Pixels stay in sensor orientation (so the saved
  /// intrinsics apply); EXIF orientation 6 makes Photos/Finder show it upright.
  nonisolated private static func writeJPEG(_ image: CIImage, to url: URL, context: CIContext) -> Bool {
    guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { return false }
    let props: [CFString: Any] = [
      kCGImagePropertyOrientation: 6,
      kCGImageDestinationLossyCompressionQuality: 0.85,
    ]
    CGImageDestinationAddImage(dest, cg, props as CFDictionary)
    return CGImageDestinationFinalize(dest)
  }

  // MARK: - Helpers

  nonisolated fileprivate static func describeTracking(_ state: ARCamera.TrackingState) -> String {
    switch state {
    case .normal: "normal"
    case .notAvailable: "notAvailable"
    case .limited(let reason): "limited:\(reason)"
    }
  }

  nonisolated private static func describe(_ i: RoomCaptureSession.Instruction) -> String? {
    switch i {
    case .moveCloseToWall: "Move closer to the wall"
    case .moveAwayFromWall: "Move back from the wall"
    case .slowDown: "Slow down"
    case .turnOnLight: "Turn on more lights"
    case .lowTexture: "Aim at something with more detail"
    case .normal: nil
    @unknown default: nil
    }
  }

  private static let names = ["Living room", "Kitchen", "Dining room", "Hallway", "Bedroom", "Bathroom", "Office"]
  static func suggestedName(for index: Int) -> String {
    index < names.count ? names[index] : "Room \(index + 1)"
  }
}

private extension CaptureController.Shot {
  init(frame: ARFrame, buffer: CVPixelBuffer, blur: Float) {
    self.init(
      buffer: buffer,
      transform: frame.camera.transform,
      intrinsics: frame.camera.intrinsics,
      resolution: frame.camera.imageResolution,
      timestamp: frame.timestamp,
      tracking: CaptureController.describeTracking(frame.camera.trackingState),
      exposure: frame.camera.exposureDuration,
      blur: blur
    )
  }
}

private extension Double {
  /// seconds to one decimal, for logs
  var rounded1: Double { (self * 10).rounded() / 10 }
}
