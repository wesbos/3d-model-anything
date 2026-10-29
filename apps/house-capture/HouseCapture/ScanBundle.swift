import Foundation
import RoomPlan
import simd
import UIKit

/// One capture session inside a house on disk
/// (Documents/Houses/<house>/sessions/<id>/, see HouseProject).
///
///     manifest.json          what's in the bundle (rewritten after every room, final at the end)
///     structure.json         all rooms merged by RoomPlan's StructureBuilder
///     structure.usdz         same, for Quick Look
///     rooms/room-N.json      each CapturedRoom as RoomPlan encodes it
///     rooms/room-N.usdz
///     rooms/room-N-data.json RoomPlan's raw CapturedRoomData (re-run RoomBuilder on it later)
///     worldmap.arworldmap    ARWorldMap at the end of the session (NSKeyedArchiver, secure coding)
///     mesh/room-N.ply        LiDAR mesh after room N's detail pass (world space; per-vertex
///                            normal + photo coverage score, per-face ARKit classification)
///     photos/photos.json     camera pose + intrinsics for every photo
///     photos/NNNN.jpg
///     depth/frames.json      LiDAR depth frames: pose + intrinsics (scaled to the depth map)
///     depth/NNNNN.f16/.conf  256×192 Float16 depth (meters) + UInt8 confidence (0–2)
///
/// Everything shares one coordinate system: the ARKit world of the capture
/// session (meters, +Y up against gravity, right-handed). house.json says how that
/// frame sits in the house (`HouseProject.toHouse(session)`).
struct ScanBundle {
  let url: URL

  static let subfolders = ["rooms", "mesh", "photos", "depth", "compass"]

  /// A new session folder inside a house: <house>/sessions/<id>/
  static func create(in house: HouseProject, id: String) throws -> ScanBundle {
    let url = house.url.appendingPathComponent("sessions", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    guard !FileManager.default.fileExists(atPath: url.path) else {
      throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
    }
    let bundle = ScanBundle(url: url)
    for dir in subfolders {
      try FileManager.default.createDirectory(at: url.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    return bundle
  }

  var name: String { url.lastPathComponent }

  func file(_ path: String) -> URL { url.appendingPathComponent(path) }

  // MARK: rooms + structure

  func saveRoom(_ room: CapturedRoom, index: Int) throws {
    try encoder.encode(room).write(to: file("rooms/room-\(index).json"))
    try? room.export(to: file("rooms/room-\(index).usdz"), exportOptions: .parametric)
    // RoomPlan's detailed object shapes (legs, backs, arms) instead of boxes
    try? room.export(to: file("rooms/room-\(index)-mesh.usdz"), exportOptions: .mesh)
  }

  func deleteRoom(index: Int) {
    for name in ["room-\(index).json", "room-\(index).usdz", "room-\(index)-mesh.usdz", "room-\(index)-data.json"] {
      try? FileManager.default.removeItem(at: file("rooms/\(name)"))
    }
  }

  /// RoomPlan's raw capture data, so RoomBuilder can be re-run on it later (Codable since iOS 17)
  static func encodeRoomData(_ data: CapturedRoomData) throws -> Data {
    try JSONEncoder().encode(data)
  }

  /// photos/photos.json, or [] if there isn't one
  var photos: [PhotoRecord] {
    guard let data = try? Data(contentsOf: file("photos/photos.json")) else { return [] }
    return (try? JSONDecoder().decode([PhotoRecord].self, from: data)) ?? []
  }

  /// depth/frames.json, or [] if there isn't one
  var depthFrames: [DepthRecorder.Record] {
    guard let data = try? Data(contentsOf: file("depth/frames.json")) else { return [] }
    return (try? JSONDecoder().decode([DepthRecorder.Record].self, from: data)) ?? []
  }

  func saveStructure(_ structure: CapturedStructure) throws {
    try Self.saveStructure(structure, in: url)
  }

  /// structure.json + structure.usdz in a folder (a session bundle, or a zone's folder)
  static func saveStructure(_ structure: CapturedStructure, in folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    e.dateEncodingStrategy = .iso8601
    try e.encode(structure).write(to: folder.appendingPathComponent("structure.json"), options: .atomic)
    try? structure.export(to: folder.appendingPathComponent("structure.usdz"), exportOptions: .parametric)
  }

  // MARK: photos

  func savePhotos(_ photos: [PhotoRecord]) throws {
    try encoder.encode(photos).write(to: file("photos/photos.json"))
  }

  func saveCompass(_ records: [CompassRecord]) throws {
    let path = file("compass/headings.json")
    if records.isEmpty {
      if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    } else {
      try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      try encoder.encode(records).write(to: path, options: .atomic)
    }
  }

  // MARK: manifest

  func writeManifest(_ manifest: Manifest) throws {
    try encoder.encode(manifest).write(to: file("manifest.json"), options: .atomic)
  }

  var manifest: Manifest? {
    guard let data = try? Data(contentsOf: file("manifest.json")) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601 // matches the encoder
    return try? decoder.decode(Manifest.self, from: data)
  }

  func delete() throws {
    try FileManager.default.removeItem(at: url)
  }

  /// Zips the bundle (NSFileCoordinator does this for directories) for sharing.
  func zipped(as zipName: String? = nil) throws -> URL {
    try FolderZipper.zip(url, name: zipName ?? name)
  }

  /// Export the selected scan as a standalone bundle, retaining its original room index
  /// and coordinate frame. Never copy the session-wide structure or tracking map.
  func zippedRoom(index: Int, name: String) throws -> URL {
    let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    let folder = staging.appendingPathComponent("Room", isDirectory: true)
    try exportRoom(index: index, name: name, to: folder)
    return try FolderZipper.zip(folder, name: name)
  }

  func exportRoom(index: Int, name: String, to destination: URL) throws {
    let fm = FileManager.default
    guard var manifest, var room = manifest.rooms.first(where: { $0.index == index }) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    // Imported bundles are untrusted: no manifest path may escape its selected folder.
    func checkedSource(_ path: String) throws -> URL {
      let root = url.resolvingSymlinksInPath().standardizedFileURL.path + "/"
      let source = file(path).resolvingSymlinksInPath().standardizedFileURL
      guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), source.path.hasPrefix(root) else {
        throw CocoaError(.fileReadInvalidFileName)
      }
      return source
    }
    // Decode explicitly: a damaged index must not silently export an empty recording.
    func records<T: Decodable>(_ type: T.Type, path: String) throws -> T {
      try JSONDecoder().decode(type, from: Data(contentsOf: checkedSource(path)))
    }
    let selectedPhotos = try records([PhotoRecord].self, path: manifest.photos).filter { $0.room == index }
    let selectedCompass: [CompassRecord]
    if let path = manifest.compass {
      selectedCompass = try records([CompassRecord].self, path: path).filter { $0.room == index }
    } else { selectedCompass = [] }
    let selectedDepth: [DepthRecorder.Record]
    if let path = manifest.depthFrames {
      selectedDepth = try records([DepthRecorder.Record].self, path: path).filter { $0.room == index }
    } else {
      selectedDepth = []
    }
    for folder in Self.subfolders {
      try fm.createDirectory(at: destination.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    let output = ScanBundle(url: destination)
    func copy(_ path: String) throws {
      let source = try checkedSource(path)
      let target = output.file(path)
      try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fm.copyItem(at: source, to: target)
    }
    if !room.file.isEmpty { try copy(room.file) }
    if !room.usdz.isEmpty {
      if fm.fileExists(atPath: file(room.usdz).path) { try copy(room.usdz) }
      else { room.usdz = "" } // Quick Look export is optional during capture.
    }
    if let path = room.data { try copy(path) }
    if let mesh = room.mesh { try copy(mesh.file) }
    for path in ["rooms/room-\(index)-mesh.usdz", "mesh/room-\(index)-colors.bin"] {
      if fm.fileExists(atPath: file(path).path) { try copy(path) }
    }
    for photo in selectedPhotos { try copy(photo.file) }
    for frame in selectedDepth {
      try copy(frame.file)
      try copy(frame.confidence)
      if let rgb = frame.rgb { try copy(rgb) }
    }
    try output.savePhotos(selectedPhotos)
    try output.saveCompass(selectedCompass)
    try encoder.encode(selectedDepth).write(to: output.file("depth/frames.json"))
    room.name = name
    manifest.rooms = [room]
    manifest.photos = "photos/photos.json"
    manifest.photoCount = selectedPhotos.count
    manifest.compass = selectedCompass.isEmpty ? nil : "compass/headings.json"
    manifest.compassSampleCount = selectedCompass.isEmpty ? nil : selectedCompass.count
    manifest.depthFrames = "depth/frames.json"
    manifest.depthFrameCount = selectedDepth.count
    manifest.mesh = room.mesh
    manifest.structure = nil
    manifest.structureError = nil
    manifest.worldMap = nil
    manifest.worldMapStatus = nil
    manifest.diagnostics = nil
    try output.writeManifest(manifest)
  }

  private var encoder: JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    e.dateEncodingStrategy = .iso8601
    return e
  }
}

/// Zips a folder for sharing (AirDrop to the Mac)
enum FolderZipper {
  static func zip(_ folder: URL, name: String) throws -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    // Unique directories keep two simultaneous exports from deleting each other's files.
    // Recover abandoned shares after a crash without touching recent active shares.
    for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
      if let date = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
         date < Date().addingTimeInterval(-86_400) { try? fm.removeItem(at: item) }
    }
    let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    var succeeded = false
    defer { if !succeeded { try? fm.removeItem(at: dir) } }
    let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    let dest = dir.appendingPathComponent("\(safe).zip")
    var result: Result<URL, Error> = .failure(CocoaError(.fileReadUnknown))
    var coordError: NSError?
    NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordError) { zipURL in
      // the coordinator's zip is deleted when this block returns: move it out (no second copy
      // of a multi-GB file), fall back to copying
      result = Result {
        do { try fm.moveItem(at: zipURL, to: dest) } catch { try fm.copyItem(at: zipURL, to: dest) }
        return dest
      }
    }
    if let coordError { throw coordError }
    let archive = try result.get()
    succeeded = true
    return archive
  }

  static func removeArchive(_ archive: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("share").standardizedFileURL
    let directory = archive.deletingLastPathComponent().standardizedFileURL
    guard directory.deletingLastPathComponent() == root else { return }
    try? FileManager.default.removeItem(at: directory)
  }
}

// MARK: - Bundle file formats

struct Manifest: Codable {
  static let currentFormat = "house-capture/5"
  var format = Manifest.currentFormat
  var createdAt: Date
  var device: String
  var systemVersion: String
  var coordinateSystem = "ARKit world space of this capture session: meters, +Y up (gravity), right-handed. Rooms, structure, mesh and photo poses all share it. For house sessions, the house's house.json maps it into the house frame: zone.toHouse × session.alignment.toZone."
  /// The house this session belongs to
  var house: String
  var houseName: String?
  var session: String
  var zone: String
  /// same as house.json's session.alignment at the time of writing (house.json is authoritative)
  var alignment: HouseProject.Alignment?
  /// "worldmap.arworldmap" once saved
  var worldMap: String?
  /// the ARKit world-mapping status when the map was saved ("mapped", "extending") or why it wasn't
  var worldMapStatus: String?
  var endedAt: Date?
  var rooms: [RoomRecord]
  var structure: String?
  var structureError: String?
  var mesh: MeshRecord?
  /// what happened when the app tried to turn on ARKit scene reconstruction
  var sceneReconstruction: String?
  var photos: String
  var photoCount: Int
  var depthFrames: String?
  var depthFrameCount: Int?
  var diagnostics: Diagnostics?
  /// Optional, additive house-capture/5 direction evidence. No geographic coordinates.
  var compass: String?
  var compassSampleCount: Int?
}

/// What the capture session actually did, for debugging bundles after the fact
struct Diagnostics: Codable {
  struct Jump: Codable {
    var time: TimeInterval
    var meters: Float
    var phase: String
  }
  /// the ARConfiguration RoomPlan ran (class, reconstruction, depth, video format)
  var roomPlanConfiguration: String?
  /// the configuration of the detail (coverage) pass
  var detailConfiguration: String?
  /// frame-to-frame camera jumps > 0.5 m: world re-localized; rooms/photos across it may not line up
  var worldJumps: [Jump] = []
  /// white balance locked after the first few seconds of scanning (gains in the photos' camera state)
  var whiteBalance: String?
  /// house-capture/5: tracking state / world-mapping status changes, pauses, map saves (capped)
  var events: [Event]?
  /// Continue sessions: how relocalizing against the zone's saved map went
  var relocalization: Relocalization?
  /// periodic live-mesh ↔ saved-mesh checks after relocalizing (capped)
  var alignmentChecks: [AlignmentCheck]?

  /// Structured framework errors, including the underlying NSError chain.
  var failures: [Failure]?
  /// Bounded samples, persisted during capture as diagnostics.json as well as in the manifest.
  var resourceSamples: [ResourceSample]?
  var memoryWarnings: Int?
  var configurationChanges: Int?

  struct Failure: Codable, Sendable {
    var t: TimeInterval
    var source: String
    var chain: [ErrorDetail]
  }

  struct ErrorDetail: Codable, Sendable {
    var domain: String
    var code: Int
    var description: String
    var reason: String?
    var recovery: String?
  }

  struct ResourceSample: Codable {
    var t: TimeInterval
    var phase: String
    var thermal: String
    var memoryMB: Double?
    var frameAgeSeconds: Double?
    var tracking: String?
    var mapping: String?
    var featurePoints: Int
    var meshAnchors: Int
    var meshVertices: Int
    var photos: Int
    var depthFrames: Int
    var photosInFlight: Int
    var coverageQueueDelayMS: Double?
    var pendingMeshUpdates: Int?
    var coalescedMeshUpdates: Int?
    var cameraAuthorization: Int?
    var locationAuthorization: Int?
    var cameraWidth: Int?
    var cameraHeight: Int?
    var cameraPixelFormat: UInt32?
    var cameraLumaMean: Double?
    var cameraLumaMin: Int?
    var cameraLumaMax: Int?
  }

  struct Event: Codable {
    /// seconds since the session started
    var t: TimeInterval
    var what: String
  }

  struct Relocalization: Codable {
    var worldMapBytes: Int?
    var referenceVertices: Int?
    var ghostTriangles: Int?
    var secondsToNormal: TimeInterval?
    var secondsToVerified: TimeInterval?
    var residualMeters: Float?
    var inlierFraction: Float?
    /// "relocalized", "unaligned: <why>", "cancelled"
    var outcome: String?
  }

  struct AlignmentCheck: Codable {
    var t: TimeInterval
    /// live points near the saved surfaces / of those, within 8 cm / their median distance (m)
    var known: Int
    var matched: Int
    var median: Float?
  }

  mutating func log(_ what: String, since start: Date) {
    print("CAPTURE: \(what)")
    var list = events ?? []
    list.append(Event(t: (Date().timeIntervalSince(start) * 10).rounded() / 10, what: what))
    if list.count > 400 { list.removeFirst(list.count - 400) }
    events = list
  }
}

struct RoomRecord: Codable, Identifiable {
  var index: Int
  var name: String
  var file: String
  var usdz: String
  var capturedAt: Date
  var walls: Int
  var doors: Int
  var windows: Int
  var openings: Int
  var objects: Int
  /// detail pass results
  var mesh: MeshRecord?
  /// fraction of the in-room mesh area that's well photographed
  var coverage: Float?
  /// Photo detail on observed mesh. Older exports used a mixed heuristic here;
  /// prefer `coverage` for display so old scans also get an honest metric.
  var photoCoverage: Int?
  var photographedPercent: Int? {
    guard let coverage, coverage.isFinite else { return nil }
    return Int((min(1, max(0, coverage)) * 100).rounded())
  }
  var detailSeconds: TimeInterval?
  var detailPhotos: Int?
  /// house-capture/5: RoomPlan's raw CapturedRoomData ("rooms/room-N-data.json")
  var data: String?
  var id: Int { index }
}

struct MeshRecord: Codable {
  var file: String
  var anchors: Int
  var vertices: Int
  var faces: Int
}

/// One reference photo. The JPEG's pixels are the raw camera image in sensor
/// orientation (landscape); `intrinsics` match those pixels. It carries EXIF
/// orientation 6 so viewers show it upright; ignore that when projecting.
struct PhotoRecord: Codable {
  var file: String
  /// index of the room being scanned when this was taken
  var room: Int
  var timestamp: TimeInterval
  var width: Int
  var height: Int
  /// camera-to-world, column-major 4x4. ARKit camera looks down -Z, +Y up, +X right (in sensor orientation)
  var transform: [Float]
  /// column-major 3x3: fx, 0, 0, 0, fy, 0, cx, cy, 1
  var intrinsics: [Float]
  var tracking: String
  var manual: Bool
  /// shutter time in seconds
  var exposure: Double?
  /// predicted motion blur in pixels from camera motion during the exposure (auto photos)
  var blurPixels: Float?
  /// "layout" (RoomPlan pass) or "detail" (coverage pass)
  var pass: String?
  /// a full-resolution still rather than a video frame
  var highRes: Bool?
  /// camera state when the photo was taken, for normalizing brightness/color across photos
  var camera: CameraState?
  /// Monotonic timestamp of the paired compass/headings.json observation, if within 1 s.
  var compassTimestamp: TimeInterval?
}

/// Exposure + white balance + ARKit's light estimate for one frame
struct CameraState: Codable {
  /// sensor ISO
  var iso: Float?
  /// shutter time in seconds
  var shutter: Double?
  /// ARKit exposure offset (EV)
  var exposureOffset: Float?
  /// white-balance gains (red, green, blue), constant once white balance is locked
  var whiteBalance: [Float]?
  var whiteBalanceLocked: Bool?
  /// ARKit ambient light estimate: intensity (lumen, ~1000 = neutral) and color temperature (K)
  var ambientIntensity: Float?
  var colorTemperature: Float?
}

extension simd_float4x4 {
  var columnMajor: [Float] {
    [columns.0, columns.1, columns.2, columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
  }
}

extension simd_float3x3 {
  var columnMajor: [Float] {
    [columns.0, columns.1, columns.2].flatMap { [$0.x, $0.y, $0.z] }
  }
}

extension UIDevice {
  /// e.g. "iPhone16,1"
  static var modelIdentifier: String {
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { buf in
      String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
    }
  }
}
