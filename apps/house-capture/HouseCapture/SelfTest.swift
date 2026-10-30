import ARKit
import SwiftUI
import simd

/// Launch with `-selftest` (works in the simulator): exercises everything of a multi-day
/// house that doesn't need the camera (house.json round trips, session folders, room history,
/// session deletion, the saved-mesh ghost + alignment check, earlier-photo loading, manifests,
/// zipping), prints `SELFTEST:` lines and exits 0 (all passed) or 1.
struct SelfTestView: View {
  @State private var lines: [String] = []
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, l in Text(l).font(.system(size: 10, design: .monospaced)) }
      }
      .padding()
    }
    .task {
      let runner = SelfTest { lines.append($0) }
      let ok = await runner.run()
      try? await Task.sleep(for: .milliseconds(300))
      exit(ok ? 0 : 1)
    }
  }
}

@MainActor
final class SelfTest {
  private let output: (String) -> Void
  private var passed = 0
  private var failed = 0

  init(output: @escaping (String) -> Void) { self.output = output }

  private func log(_ s: String) {
    print("SELFTEST: \(s)")
    output(s)
  }

  private func expect(_ ok: Bool, _ what: String) {
    if ok { passed += 1; log("ok   \(what)") } else { failed += 1; log("FAIL \(what)") }
  }

  private func roomExperience() throws {
    expect(!CaptureQuality(percent: 99, walls: 0, photos: 0).ready, "finish signal requires measured room and photos")
    expect(CaptureQuality(percent: 88, walls: 4, photos: 20).ready, "finish signal accepts sufficient coverage")
    let observed = CoverageEngine.Stats(meshCovered: 0.82601947, meshArea: 20, targetsCovered: 0.1, ceilingCovered: 0, floorCovered: 0)
    expect(observed.percent == 83, "room photo detail ignores inferred hidden surfaces and ceiling penalty")
    expect(CoverageEngine.Stats(meshCovered: 1, meshArea: 0, targetsCovered: 1).percent == 0, "no observed mesh cannot report photo detail")
    expect(!CaptureQuality(percent: 40, walls: 4, photos: 156).ready, "many photos do not hide poor observed detail")
    expect(CaptureQuality(percent: 88, walls: 4, photos: 20).ready, "finish suggestion does not require inferred floor or ceiling coverage")
    let legacy = try JSONDecoder().decode(RoomRecord.self, from: Data(#"{"index":0,"name":"Play room","file":"room.json","usdz":"room.usdz","capturedAt":0,"walls":15,"doors":4,"windows":0,"openings":0,"objects":16,"coverage":0.82601947,"photoCoverage":53}"#.utf8))
    expect(legacy.photographedPercent == 83, "saved scans use measured coverage instead of legacy mixed percentage")
    expect(CaptureBudget(thermal: .serious, photos: 2, memoryPressure: false).depthInterval > 0.2, "warm phone reduces depth rate")
    expect(CaptureBudget(thermal: .nominal, photos: 2, memoryPressure: true).constrained, "memory pressure reduces capture work")
    var h = try HouseProject.create(name: "Experience selftest")
    defer { try? FileManager.default.removeItem(at: h.url) }
    let z = h.addZone(named: "test")
    h.beginSession(id: "fixture", zone: z.id, alignment: .init(method: "first"))
    let original = h.recordRoomScan(name: "Office", session: "fixture", index: 0, capturedAt: Date(), matchName: false)!
    _ = h.recordRoomScan(name: "Office", session: "fixture", index: 1, capturedAt: Date(), matchName: false)
    try h.save()
    expect(h.rooms.count == 2, "same-name rooms stay separate when selected by identity")
    try HouseProject.renameRoom(houseID: h.id, roomID: original.id, name: "Studio")
    h = try HouseProject.load(id: h.id)
    _ = h.recordRoomScan(name: "Studio", session: "fixture", index: 2, capturedAt: Date(), roomID: original.id, matchName: false)
    try h.save()
    expect(h.rooms.first { $0.id == original.id }?.history.count == 2, "rescan retains identity after rename")
    try HouseProject.moveRoomToTrash(houseID: h.id, roomID: original.id)
    h = try HouseProject.load(id: h.id)
    expect(h.rooms.count == 1 && h.deletedRooms.count == 1, "soft deletion hides only selected room")
    try HouseProject.restoreRoom(houseID: h.id, roomID: original.id)
    h = try HouseProject.load(id: h.id)
    expect(h.rooms.count == 2 && h.deletedRooms.isEmpty && h.rooms.first { $0.id == original.id }?.history.count == 2, "restore preserves identity and scan history")
    let current = h.rooms.first { $0.id == original.id }!
    try HouseProject.deleteScan(houseID: h.id, roomID: original.id, ref: current.active!)
    h = try HouseProject.load(id: h.id)
    expect(h.rooms.first { $0.id == original.id }?.active?.index == 0 && h.deletedRooms.count == 1, "deleting active version restores previous version and remains recoverable")
  }

  func run() async -> Bool {
    var houseID: String?
    do {
      try await coveragePerformance()
      trackingRecovery()
      try roomExperience()
      try captureDiagnostics()
      try highResolutionStats()
      try await previewNormals()
      try await photoTextures()
      houseID = try await tests()
    } catch {
      failed += 1
      log("FAIL threw: \(error)")
    }
    if let houseID { try? FileManager.default.removeItem(at: HouseProject.url(forHouse: houseID)) }
    do {
      try await realBundle()
    } catch {
      failed += 1
      log("FAIL real bundle threw: \(error)")
    }
    log(failed == 0 ? "PASS \(passed)/\(passed)" : "FAILED \(failed) of \(passed + failed)")
    return failed == 0
  }

  private func highResolutionStats() throws {
    var stats = HighResolutionStats()
    stats.count(.requested); stats.count(.requested); stats.count(.kept)
    stats.count(.notSharper); stats.count(.notSharper); stats.count(.warm)
    stats.delivered("4032x3024")
    expect(stats.requested == 2 && stats.kept == 1, "high-res attempts and kept stills are counted")
    expect(stats.dropped == ["notSharper": 2] && stats.skipped == ["warm": 1], "dropped stills and skipped attempts are counted by reason")
    expect(stats.deliveredSizes == ["4032x3024": 1], "delivered still sizes are counted")
    let decoded = try JSONDecoder().decode(HighResolutionStats.self, from: JSONEncoder().encode(stats))
    expect(decoded.dropped == stats.dropped && decoded.kept == 1, "high-res stats survive JSON")
    expect(try JSONDecoder().decode(Diagnostics.self, from: Data("{\"worldJumps\":[]}".utf8)).highResolution == nil, "older diagnostics have no high-res stats")

    let sizes: [(Int32, Int32)] = [(2016, 1512), (8064, 6048), (4032, 3024)]
    expect(HighResolutionStats.largest(sizes)?.0 == 4032, "the largest offered still up to 4032 wide is picked")
    expect(HighResolutionStats.largest([(8064, 6048), (5712, 4284)])?.0 == 5712, "if every size is wider, the smallest is picked")
    expect(HighResolutionStats.largest([]) == nil, "no offered sizes picks none")
  }

  private func coveragePerformance() async throws {
    let mailbox = CoverageMailbox<Int, Int>()
    expect(mailbox.offer(1, 0), "first mesh update schedules one consumer")
    for i in 1...10_000 { _ = mailbox.offer(1, i) }
    _ = mailbox.offer(2, 20)
    expect(mailbox.counts.pending == 2 && mailbox.counts.replaced == 10_000,
           "busy mesh input retains latest per anchor, not 10,000 obsolete snapshots")
    let first = mailbox.take(limit: 1)
    expect(first.first?.0 == 1 && first.first?.1 == 10_000, "bounded drain gets newest geometry")
    _ = mailbox.offer(1, 10_001)
    expect(mailbox.finish() && mailbox.take(limit: 1).first?.0 == 2, "busy anchor does not starve other anchors")
    _ = mailbox.take()
    expect(!mailbox.finish() && mailbox.offer(3, 30), "idle consumer can be scheduled again")
    let concurrent = CoverageMailbox<Int, Int>()
    await Task.detached {
      DispatchQueue.concurrentPerform(iterations: 1000) { i in _ = concurrent.offer(i % 8, i) }
    }.value
    expect(concurrent.counts.pending == 8 && concurrent.counts.replaced == 992,
           "concurrent producers remain bounded by anchor count")

    let photo = CoverageEngine.Photo(worldToCamera: matrix_identity_float4x4, position: .zero,
      fx: 1000, fy: 1000, cx: 960, cy: 720, width: 1920, height: 1440, sharpness: 1, room: 0)
    var occluded = photo
    occluded.depth = .init(width: 2, height: 2, values: [0.5, 0.5, 0.5, 0.5],
      worldToCamera: matrix_identity_float4x4, fx: 1, fy: 1, cx: 1, cy: 1)
    let photos = Array(repeating: photo, count: 154)
    let points: [SIMD3<Float>] = [SIMD3(0,0,-1), SIMD3(0,0,-4), SIMD3(0,0,1), SIMD3(10,0,-1)]
    for point in points {
      let normal = SIMD3<Float>(0,0,1)
      let baseline = min(2, photos.reduce(Float(0)) { $0 + CoverageEngine.contribution($1, point, normal) })
      expect(CoverageEngine.coverageScore(photos, at: point, normal: normal) == baseline,
             "early saturation preserves score for point \(point)")
    }
    expect(CoverageEngine.coverageScore([occluded], at: SIMD3(0,0,-2), normal: SIMD3(0,0,1)) == 0,
           "occluded surface stays uncovered")
    expect(CoverageEngine.coverageScore([], at: SIMD3(0,0,-1), normal: SIMD3(0,0,1)) == 0,
           "discarding photos clears coverage")

    let engine = CoverageEngine()
    let id = UUID()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("coverage-barrier-\(UUID()).ply")
    defer { try? FileManager.default.removeItem(at: url) }
    for x: Float in [0, 1, 2] {
      engine.update(snapshot: .init(id: id, transform: matrix_identity_float4x4,
        positions: [SIMD3(x,0,0), SIMD3(x+0.1,0,0), SIMD3(x,0.1,0)],
        normals: Array(repeating: SIMD3(0,0,1), count: 3), faces: [0,1,2], classes: [1]))
    }
    engine.remove(id) // RoomPlan may remove anchors as it stops.
    let result = await withCheckedContinuation { continuation in
      engine.exportPLY(to: url) { continuation.resume(returning: $0) }
    }
    _ = try result.get()
    let mesh = try PLYMesh.load(url: url)
    expect(mesh.vertexCount == 3 && mesh.position(0).x == 2,
           "export flushes newest pending geometry even after anchor removal")

    // Reusing unchanged vertices must still respect added/discarded photos and changed normals.
    func exportCoverage(_ e: CoverageEngine) async throws -> PLYMesh {
      let result = await withCheckedContinuation { continuation in
        e.exportPLY(to: url) { continuation.resume(returning: $0) }
      }
      _ = try result.get()
      return try PLYMesh.load(url: url)
    }
    let snapshot = ARMeshAnchor.Snapshot(id: id, transform: matrix_identity_float4x4,
      positions: [SIMD3(0,0,-1), SIMD3(0.1,0,-1), SIMD3(0,0.1,-1)],
      normals: Array(repeating: SIMD3(0,0,1), count: 3), faces: [0,1,2], classes: [1])
    engine.update(snapshot: snapshot)
    engine.add(photo)
    let covered = try await exportCoverage(engine)
    engine.update(snapshot: snapshot)
    let unchanged = try await exportCoverage(engine)
    expect(covered.coverageColors == unchanged.coverageColors && covered.coverageColors[1] == 199,
           "unchanged vertex reuse preserves newly added photo coverage")
    var reversed = snapshot
    reversed.normals = Array(repeating: SIMD3(0,0,-1), count: 3)
    engine.update(snapshot: reversed)
    let changed = try await exportCoverage(engine)
    expect(changed.coverageColors[0] == 255, "changed normal invalidates cached vertex score")
    engine.update(snapshot: snapshot)
    engine.reset(photos: [])
    let reset = try await exportCoverage(engine)
    expect(reset.coverageColors[0] == 255, "reset removes coverage even when geometry is unchanged")

    let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("coverage-benchmark")
    if FileManager.default.fileExists(atPath: base.appendingPathComponent("mesh/room-0.ply").path) {
      let report = try await Task.detached(priority: .utility) { () throws -> (Float, Double, Double, Int) in
        let mesh = try PLYMesh.load(url: base.appendingPathComponent("mesh/room-0.ply"))
        let records = try JSONDecoder().decode([PhotoRecord].self, from: Data(contentsOf: base.appendingPathComponent("photos/photos.json")))
        let photos = records.map { p -> CoverageEngine.Photo in
          let t = simd_float4x4(columnMajor: p.transform), k = p.intrinsics
          return .init(worldToCamera: t.inverse, position: simd_make_float3(t.columns.3),
            fx:k[0], fy:k[4], cx:k[6], cy:k[7], width:Float(p.width), height:Float(p.height),
            sharpness:1, room:p.room)
        }
        let indices = Array(stride(from: 0, to: mesh.vertexCount, by: max(1,mesh.vertexCount/20_000)))
        let t0 = CACurrentMediaTime()
        let baseline = indices.map { i in min(2, photos.reduce(Float(0)) {
          $0 + CoverageEngine.contribution($1,mesh.position(i),mesh.normal(i))
        }) }
        let t1 = CACurrentMediaTime()
        let optimized = indices.map { CoverageEngine.coverageScore(photos,at:mesh.position($0),normal:mesh.normal($0)) }
        let t2 = CACurrentMediaTime()
        let error = zip(baseline,optimized).map { abs($0-$1) }.max() ?? 0
        return (error,(t1-t0)*1000,(t2-t1)*1000,indices.count)
      }.value
      expect(report.0 < 0.00001, "actual office sampled geometry preserves baseline scores")
      log(String(format:"coverage benchmark: %d office vertices, no-depth photo poses, baseline %.1f ms → optimized %.1f ms (%.2fx); max error %.8f", report.3,report.1,report.2,report.1/max(report.2,0.001),report.0))
    } else { log("skip optional coverage-benchmark fixture") }
  }

  private func trackingRecovery() {
    var recovery = TrackingRecovery()
    expect(!recovery.canCapture, "tracking starts blocked until stable")
    recovery.update(problem: nil, now: 0)
    recovery.update(problem: nil, now: 1.4)
    expect(!recovery.canCapture, "one normal frame does not resume capture")
    recovery.update(problem: nil, now: 1.5)
    expect(recovery.canCapture, "stable tracking resumes capture")
    recovery.update(problem: .motion, now: 2)
    expect(!recovery.canCapture && recovery.issue == .motion, "motion immediately blocks capture with guidance")
    recovery.update(problem: nil, now: 3)
    recovery.update(problem: .features, now: 4)
    recovery.update(problem: nil, now: 5)
    recovery.update(problem: nil, now: 6)
    expect(!recovery.canCapture, "tracking flicker restarts stability timer")
    recovery.update(problem: nil, now: 6.5)
    expect(recovery.canCapture, "recovery succeeds after new stable interval")
    recovery.update(problem: .stalled, now: 7)
    expect(!recovery.canCapture, "stale camera frame blocks capture despite normal tracking")
    recovery.update(problem: .interrupted, now: 8)
    expect(recovery.issue == .interrupted, "interruption supplies recovery guidance")
    expect(TrackingRecovery.problem(for: .limited(.excessiveMotion)) == .motion &&
           TrackingRecovery.problem(for: .limited(.insufficientFeatures)) == .features &&
           TrackingRecovery.problem(for: .limited(.relocalizing)) == .relocalizing &&
           TrackingRecovery.problem(for: .normal) == nil, "ARKit tracking reasons map to specific guidance")
  }

  private func captureDiagnostics() throws {
    let underlying = NSError(domain: "test.tracking", code: 42,
        userInfo: [NSLocalizedDescriptionKey: "tracking stopped", NSLocalizedFailureReasonErrorKey: "test reason"])
    let outer = NSError(domain: "test.roomplan", code: 7,
        userInfo: [NSLocalizedDescriptionKey: "World tracking failure", NSUnderlyingErrorKey: underlying])
    let chain = Diagnostics.errorChain(outer)
    expect(chain.count == 2 && chain[0].domain == "test.roomplan" && chain[1].code == 42,
           "diagnostics retain nested error domains and codes")
    expect(chain.last?.reason == "test reason", "diagnostics retain underlying failure reason")
    var diagnostics = Diagnostics()
    for _ in 0..<40 { diagnostics.recordFailure(source: "test", chain: chain, since: Date()) }
    expect(diagnostics.failures?.count == 32, "failure history is bounded")
    for i in 0..<250 {
      diagnostics.recordSample(.init(t: Double(i), phase: "scanning", thermal: "nominal", memoryMB: 123,
        frameAgeSeconds: 0.1, tracking: "normal", mapping: "mapped", featurePoints: 100,
        meshAnchors: 2, meshVertices: 50, photos: 1, depthFrames: 3, photosInFlight: 0))
    }
    expect(diagnostics.resourceSamples?.count == 240 && diagnostics.resourceSamples?.first?.t == 10,
           "resource sampling retains only the latest 240 samples")
    let decoded = try JSONDecoder().decode(Diagnostics.self, from: JSONEncoder().encode(diagnostics))
    expect(decoded.failures?.last?.chain.last?.code == 42 && decoded.resourceSamples?.last?.memoryMB == 123,
           "detailed capture diagnostics survive JSON round trip")
    let old = try JSONDecoder().decode(Diagnostics.self, from: Data("{\"worldJumps\":[]}".utf8))
    expect(old.failures == nil && old.resourceSamples == nil, "older diagnostics remain readable")
    expect(Diagnostics.memoryFootprintMB().map { $0 > 0 } == true, "memory footprint is measurable")
  }

  private func tests() async throws -> String {
    let fm = FileManager.default

    // --- house + first zone + first session
    var house = try HouseProject.create(name: "Selftest \(HouseProject.folderName(for: Date()))")
    let houseID = house.id
    let zone1 = house.addZone(named: "Area 1")
    try house.save()
    expect(zone1.aligned && zone1.id == "area-1", "first zone is placed in the house frame")
    let first = try CaptureController.start(houseID: houseID, zoneID: zone1.id)
    expect(first.phase == .betweenRooms && first.plan.worldMap == nil && first.alignment.method == "first", "first session starts fresh, alignment first")
    let s1 = first.plan.sessionID
    for dir in ScanBundle.subfolders {
      var isDir: ObjCBool = false
      expect(fm.fileExists(atPath: first.bundle.file(dir).path, isDirectory: &isDir) && isDir.boolValue, "session folder has \(dir)/")
    }
    expect(first.bundle.url.deletingLastPathComponent().lastPathComponent == "sessions", "session folder is under sessions/")
    house = try HouseProject.load(id: houseID)
    expect(house.session(s1)?.endedAt == nil && house.session(s1)?.zone == zone1.id, "session recorded in house.json at start")

    // --- rooms + history
    try HouseProject.modify(houseID) { h in
      h.recordRoomScan(name: "Office", session: s1, index: 0, capturedAt: Date(timeIntervalSince1970: 1000))
      h.recordRoomScan(name: "Kitchen", session: s1, index: 1, capturedAt: Date(timeIntervalSince1970: 1100))
      h.recordRoomScan(name: " office ", session: s1, index: 2, capturedAt: Date(timeIntervalSince1970: 1200)) // rescan, same session
      h.endSession(s1)
    }
    house = try HouseProject.load(id: houseID)
    let office = house.rooms.first { $0.name == "Office" }
    expect(house.rooms.count == 2, "rescan by name doesn't add a room (\(house.rooms.map(\.name)))")
    expect(office?.history.count == 2 && office?.active?.index == 2, "rescan goes into history and becomes active")
    expect(house.session(s1)?.rooms == [0, 1, 2], "session lists its room indices")
    try HouseProject.modify(houseID) { $0.removeRoomScan(session: s1, index: 2) }
    house = try HouseProject.load(id: houseID)
    expect(house.rooms.first { $0.name == "Office" }?.active?.index == 0, "redo last room: previous scan active again")
    try HouseProject.modify(houseID) { $0.recordRoomScan(name: "Office", session: s1, index: 2, capturedAt: Date(timeIntervalSince1970: 1200)) }

    // --- saved mesh + photos for session 1 (a 3 m × 2.4 m wall at z = -2 and a floor)
    try writeTestPLY(to: first.bundle.file("mesh/room-0.ply"))
    try writeTestPhotos(first.bundle)

    // --- JSON round trip
    house = try HouseProject.load(id: houseID)
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    e.dateEncodingStrategy = .iso8601
    let a = try e.encode(house)
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    let b = try e.encode(try d.decode(HouseProject.self, from: a))
    expect(a == b, "house.json round-trips byte for byte")
    expect(house.format == "house-project/1", "house.json format")

    // --- world map → Continue plans a relocalization
    let mapPath = WorldMapFile.zoneRelativePath(zone1.id)
    try fm.createDirectory(at: house.url.appendingPathComponent("zones/\(zone1.id)"), withIntermediateDirectories: true)
    try Data("not a real map".utf8).write(to: house.url.appendingPathComponent(mapPath))
    try HouseProject.modify(houseID) { $0.setWorldMap(zone: zone1.id, path: mapPath) }
    try await Task.sleep(for: .seconds(1.1)) // session folders are named by the second
    let cont = try CaptureController.start(houseID: houseID, zoneID: zone1.id)
    expect(cont.phase == .relocalizing && cont.plan.worldMap != nil, "Continue with a saved map starts relocalizing")
    expect(cont.alignment.method == "unaligned" && cont.alignment.note != nil, "until verified the session is recorded as unaligned")
    expect(cont.existingRoomNames.sorted() == ["Kitchen", "Office"], "Continue suggests the zone's rooms for rescans")
    let s2 = cont.plan.sessionID
    expect(s2 != s1, "second session gets its own folder")

    // --- ghost + alignment check against session 1's mesh
    house = try HouseProject.load(id: houseID)
    let ref = ZoneReference.load(house: house, zone: zone1.id, excludingSession: s2)
    expect(ref.files.count == 1 && ref.errors.isEmpty, "zone reference reads the saved PLY (\(ref.errors))")
    expect((ref.ghost?.triangleCount ?? 0) > 100, "ghost is decimated but not empty (\(ref.ghost?.triangleCount ?? 0) triangles from \(ref.sourceVertices) vertices)")
    typealias LP = ZoneReference.LivePoint
    var backWall: [LP] = [], sideWall: [LP] = [], floor: [LP] = []
    for i in 0..<60 { for j in 0..<40 { backWall.append(LP(p: SIMD3(-1.4 + Float(i) * 0.047, 0.1 + Float(j) * 0.055, -2 + 0.004 * sin(Float(i * j))), n: SIMD3(0, 0, 1))) } }
    for i in 0..<30 { for j in 0..<40 { sideWall.append(LP(p: SIMD3(-1.5 + 0.004 * cos(Float(i * j)), 0.1 + Float(j) * 0.055, -1.9 + Float(i) * 0.05), n: SIMD3(1, 0, 0))) } }
    for i in 0..<30 { for j in 0..<20 { floor.append(LP(p: SIMD3(-1.4 + Float(i) * 0.09, 0.003, -1.9 + Float(j) * 0.08), n: SIMD3(0, 1, 0))) } }
    let corner = backWall + sideWall + floor
    let good = ref.check(corner)
    expect(good.isGood && (good.median ?? 1) < 0.01, "live points on the saved corner pass (median \(good.median ?? -1), walls \(good.wallMatched)/\(good.wallKnown), spread \(good.spreadDegrees)°)")
    let oneWall = ref.check(backWall + floor)
    expect(!oneWall.isGood && oneWall.needsCorner, "one flat wall alone can't verify (spread \(oneWall.spreadDegrees)°)")
    let shifted = ref.check(corner.map { LP(p: $0.p + SIMD3(0.25, 0, 0.25), n: $0.n) })
    expect(shifted.isMismatch && !shifted.isGood, "a 35 cm offset is a mismatch (walls \(shifted.wallMatched)/\(shifted.wallKnown))")
    let slid = ref.check(corner.map { LP(p: $0.p + SIMD3(0.3, 0, 0), n: $0.n) })
    expect(!slid.isGood, "a 30 cm slide along the back wall doesn't verify (walls \(slid.wallMatched)/\(slid.wallKnown), spread \(slid.spreadDegrees)°)")
    let slightly = ref.check(corner.map { LP(p: $0.p + SIMD3(0.07, 0, 0.07), n: $0.n) })
    expect(!slightly.isGood, "a 10 cm offset doesn't verify (median \(slightly.median ?? -1))")
    // the back side of the saved wall (seen from the next room, 12 cm away through the wall)
    let behind = ref.check(backWall.map { LP(p: $0.p - SIMD3(0, 0, 0.12), n: -$0.n) })
    expect(behind.known == 0 && !behind.isMismatch, "the far side of a scanned wall isn't a mismatch (known \(behind.known))")
    let far = ref.check(corner.map { LP(p: $0.p + SIMD3(0, 0, 3), n: $0.n) })
    expect(far.known == 0 && !far.isGood && !far.isMismatch, "points far from anything scanned are neither")

    // --- earlier photos (with occlusion depth) for coverage
    let prior = PriorPhotos.load(house: house, zone: zone1.id, excludingSession: s2)
    expect(prior.count == 1, "earlier photo with a matching depth frame loads (\(prior.count))")
    if let p = prior.first, let g = p.depth {
      let center = g.values[24 * g.width + 32]
      expect(abs(center - 2) < 0.01, "depth grid inflated from .f16z (center \(center) m)")
    }
    expect(PriorPhotos.landmarks(house: house, zone: zone1.id).count == 1, "landmark photo found")

    // --- manifests: current session format round trip
    try first.bundle.writeManifest(Manifest(createdAt: Date(), device: "test", systemVersion: "0", house: houseID, session: s1, zone: zone1.id,
                                            alignment: .init(method: "first"), worldMap: WorldMapFile.sessionFile, rooms: [], photos: "photos/photos.json", photoCount: 1))
    expect(first.bundle.manifest?.format == "house-capture/5" && first.bundle.manifest?.alignment?.method == "first", "v5 manifest round-trips")
    // --- single-room export excludes sibling recordings and session-wide assets.
    let exportTest = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: exportTest) }
    let source = ScanBundle(url: exportTest.appendingPathComponent("source"))
    for dir in ScanBundle.subfolders {
      try fm.createDirectory(at: source.file(dir), withIntermediateDirectories: true)
    }
    try writeTestPhotos(source)
    var photo = source.photos[0]
    photo.room = 2; photo.file = "photos/0002.jpg"
    try Data([1, 2, 3]).write(to: source.file(photo.file))
    try source.savePhotos(source.photos + [photo])
    var depth = source.depthFrames[0]
    depth.room = 2; depth.file = "depth/00002.f16z"; depth.confidence = "depth/00002.conf"; depth.rgb = "depth/00002.jpg"
    for path in [depth.file, depth.confidence, depth.rgb!] { try Data([4, 5, 6]).write(to: source.file(path)) }
    try JSONEncoder().encode(source.depthFrames + [depth]).write(to: source.file("depth/frames.json"))
    let roomRecords = [0, 2].map { i in
      RoomRecord(index: i, name: "Room \(i)", file: "rooms/room-\(i).json", usdz: "", capturedAt: Date(), walls: 4, doors: 1, windows: 0, openings: 0, objects: 0,
                 mesh: MeshRecord(file: "mesh/room-\(i).ply", anchors: 1, vertices: 3, faces: 1))
    }
    for room in roomRecords {
      try Data("{}".utf8).write(to: source.file(room.file))
      try Data([7, 8, 9]).write(to: source.file(room.mesh!.file))
    }
    for path in ["worldmap.arworldmap", "structure.json", "structure.usdz"] { try Data([0]).write(to: source.file(path)) }
    var sourceDiagnostics = Diagnostics()
    sourceDiagnostics.highResolution = HighResolutionStats()
    sourceDiagnostics.highResolution?.count(.requested)
    try source.writeManifest(Manifest(createdAt: Date(), device: "test", systemVersion: "0", house: houseID, session: s1, zone: zone1.id,
                                      worldMap: "worldmap.arworldmap", rooms: roomRecords, structure: "structure.json", mesh: roomRecords[0].mesh,
                                      photos: "photos/photos.json", photoCount: 2, depthFrames: "depth/frames.json", depthFrameCount: 2,
                                      diagnostics: sourceDiagnostics))
    let exported = ScanBundle(url: exportTest.appendingPathComponent("export"))
    try source.exportRoom(index: 2, name: "Renamed room", to: exported.url)
    expect(exported.manifest?.rooms.map(\.index) == [2] && exported.manifest?.rooms.first?.name == "Renamed room", "room export preserves nonzero index and current name")
    expect(exported.photos.map(\.room) == [2] && exported.depthFrames.map(\.room) == [2], "room export filters photo and depth indexes")
    expect(exported.manifest?.diagnostics?.highResolution?.requested == 1, "room export keeps the session's capture diagnostics")
    expect(exported.manifest?.photoCount == 1 && exported.manifest?.depthFrameCount == 1 && exported.manifest?.mesh?.file == "mesh/room-2.ply", "room export updates counts and mesh reference")
    expect(exported.manifest?.worldMap == nil && exported.manifest?.structure == nil, "room export clears session-wide references")
    for path in [photo.file, depth.file, depth.confidence, depth.rgb!, "rooms/room-2.json", "mesh/room-2.ply"] {
      expect(fm.fileExists(atPath: exported.file(path).path), "room export includes \(path)")
    }
    for path in ["photos/0000.jpg", "depth/00000.f16z", "rooms/room-0.json", "mesh/room-0.ply", "worldmap.arworldmap", "structure.json", "structure.usdz"] {
      expect(!fm.fileExists(atPath: exported.file(path).path), "room export excludes \(path)")
      expect(fm.fileExists(atPath: source.file(path).path), "room export preserves original \(path)")
    }
    let roomZip = try source.zippedRoom(index: 2, name: "Room / test")
    expect(((try? fm.attributesOfItem(atPath: roomZip.path)[.size] as? Int) ?? 0) > 0, "single room zips with a safe filename")
    do {
      try source.exportRoom(index: 99, name: "Missing", to: exportTest.appendingPathComponent("missing"))
      expect(false, "missing room rejects export")
    } catch { expect(true, "missing room rejects export") }
    let secondRoomZip = try source.zippedRoom(index: 2, name: "Room / test")
    expect(roomZip != secondRoomZip && fm.fileExists(atPath: roomZip.path), "independent room exports do not replace an existing share")
    FolderZipper.removeArchive(secondRoomZip)
    expect(!fm.fileExists(atPath: secondRoomZip.path) && fm.fileExists(atPath: roomZip.path), "share cleanup removes only its own archive")
    FolderZipper.removeArchive(source.file(photo.file))
    expect(fm.fileExists(atPath: source.file(photo.file).path), "share cleanup cannot delete original captures")
    let importedID = try ScanImport.importFolder(exported.url)
    defer { try? fm.removeItem(at: HouseProject.url(forHouse: importedID)) }
    let imported = try HouseProject.load(id: importedID)
    expect(imported.rooms.count == 1 && imported.rooms[0].name == "Renamed room" && imported.rooms[0].active?.index == 2, "folder import creates an independent house with original room index")
    expect(imported.sessions.count == 1 && imported.zones.count == 1, "folder import reconstructs session and tracking group references")
    let importedBundle = imported.bundle(for: imported.sessions[0])
    expect(importedBundle.photos.count == 1 && importedBundle.manifest?.house == importedID, "folder import copies photos and normalizes manifest ownership")
    try fm.createSymbolicLink(at: exported.file("outside"), withDestinationURL: source.url)
    do {
      _ = try ScanImport.importFolder(exported.url)
      expect(false, "folder import rejects symbolic links")
    } catch { expect(true, "folder import rejects symbolic links") }
    try fm.removeItem(at: exported.file("outside"))
    var invalidManifest = exported.manifest!
    invalidManifest.photos = "../source/photos/photos.json"
    try exported.writeManifest(invalidManifest)
    do {
      try exported.exportRoom(index: 2, name: "Unsafe", to: exportTest.appendingPathComponent("unsafe"))
      expect(false, "room export rejects escaping index paths")
    } catch { expect(true, "room export rejects escaping index paths") }
    try CaptureReadiness.checkStorage(available: CaptureReadiness.reserve, required: CaptureReadiness.reserve)
    try CaptureReadiness.checkStorage(available: nil, required: CaptureReadiness.reserve)
    do {
      try CaptureReadiness.checkStorage(available: CaptureReadiness.reserve - 1, required: CaptureReadiness.reserve)
      expect(false, "low-storage preflight blocks below its reserve")
    } catch { expect(true, "low-storage preflight blocks below its reserve") }
    expect(HelpDocument.load("PrivacyPolicy") != nil && HelpDocument.load("Support") != nil, "offline privacy and support ship in the app")
    try Data("broken".utf8).write(to: source.file("photos/photos.json"))
    do {
      try source.exportRoom(index: 2, name: "Broken", to: exportTest.appendingPathComponent("broken"))
      expect(false, "corrupt photo index rejects export")
    } catch { expect(true, "corrupt photo index rejects export") }

    // --- abandoning a Continue session removes it; relocalized-session rooms join the history
    cont.abandon()
    house = try HouseProject.load(id: houseID)
    expect(house.session(s2) == nil && !fm.fileExists(atPath: house.url.appendingPathComponent("sessions/\(s2)").path), "discarded session leaves no trace")
    expect(house.existingWorldMap(zone: house.zone(zone1.id)!) != nil, "discarding a Continue session keeps the zone map")
    try await Task.sleep(for: .seconds(1.1))
    let third = try CaptureController.start(houseID: houseID, zoneID: zone1.id)
    let s3 = third.plan.sessionID
    try HouseProject.modify(houseID) { h in
      h.setAlignment(session: s3, .init(method: "relocalized", residualMeters: 0.02))
      h.recordRoomScan(name: "Kitchen", session: s3, index: 0, capturedAt: Date(timeIntervalSince1970: 2000))
      h.recordRoomScan(name: "Hallway", session: s3, index: 1, capturedAt: Date(timeIntervalSince1970: 2100))
      h.endSession(s3)
    }
    house = try HouseProject.load(id: houseID)
    let kitchen = house.rooms.first { $0.name == "Kitchen" }
    expect(kitchen?.history.map(\.session) == [s1, s3] && kitchen?.active?.session == s3, "rescan in a later session: history across sessions, newest active")
    if let kitchen, let old = kitchen.history.first {
      try HouseProject.modify(houseID) { $0.setActive(room: kitchen.id, old) }
      expect(try HouseProject.load(id: houseID).rooms.first { $0.id == kitchen.id }?.active == old, "use this scan: older scan active again")
    }
    expect(house.lastZone?.id == zone1.id, "Continue defaults to the last session's zone")

    // --- new area
    try await Task.sleep(for: .seconds(1.1))
    let area2 = try CaptureController.start(houseID: houseID, zoneID: nil, newZone: "Upstairs")
    house = try HouseProject.load(id: houseID)
    let z2 = house.zone(area2.plan.zoneID)
    expect(z2?.name == "Upstairs" && z2?.aligned == false && area2.alignment.method == "first" && area2.plan.worldMap == nil, "new area: own frame, not placed in house, session 'first'")

    // --- zip one session and the whole house
    let sessionZip = try FolderZipper.zip(first.bundle.url, name: "\(house.name) \(s1)")
    expect(((try? fm.attributesOfItem(atPath: sessionZip.path)[.size] as? Int) ?? 0) > 1000, "session zips")
    let houseZip = try FolderZipper.zip(house.url, name: house.name)
    expect(((try? fm.attributesOfItem(atPath: houseZip.path)[.size] as? Int) ?? 0) > 1000, "house zips")

    // Room deletion preserves a sibling recorded in the same session.
    let scratch = house.addZone(named: "Deletion test")
    house.beginSession(id: "delete-test", zone: scratch.id, alignment: .init(method: "first"))
    let deleteA = house.recordRoomScan(name: "Delete A", session: "delete-test", index: 0, capturedAt: Date())!
    _ = house.recordRoomScan(name: "Keep B", session: "delete-test", index: 1, capturedAt: Date())
    try house.save()
    try HouseProject.deleteRoom(houseID: houseID, roomID: deleteA.id)
    house = try HouseProject.load(id: houseID)
    expect(!house.rooms.contains { $0.id == deleteA.id } && house.session("delete-test")?.rooms == [1], "room deletion preserves sibling session entries")
    expect(house.zone(zone1.id)?.worldMap != nil, "room deletion preserves unrelated tracking maps")
    let deleteB = house.rooms.first { $0.name == "Keep B" }!
    try HouseProject.deleteRoom(houseID: houseID, roomID: deleteB.id)
    house = try HouseProject.load(id: houseID)
    expect(house.session("delete-test") == nil && house.zone(scratch.id) == nil, "last room deletion removes empty session and tracking group")

    // --- deleting sessions
    try HouseProject.deleteSession(houseID: houseID, sessionID: s3)
    house = try HouseProject.load(id: houseID)
    expect(house.rooms.first { $0.name == "Kitchen" }?.active?.session == s1 && !house.rooms.contains { $0.name == "Hallway" }, "deleting a session rolls its rooms back")
    try HouseProject.deleteSession(houseID: houseID, sessionID: s1)
    house = try HouseProject.load(id: houseID)
    expect(house.roomsInZone(zone1.id).isEmpty && house.zone(zone1.id)?.worldMap == nil && !fm.fileExists(atPath: house.url.appendingPathComponent(mapPath).path),
           "deleting the zone's last placed session drops its map")
    return houseID
  }

  /// Regression: a zero ARKit normal used to become NaN and trap during photo-color baking.
  private func previewNormals() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-preview-normals.ply")
    defer { try? FileManager.default.removeItem(at: url) }
    let normals: [SIMD3<Float>] = [SIMD3(.nan, .nan, .nan), SIMD3(0, .infinity, 0),
                                  .zero, SIMD3(0, 1e-10, 0), SIMD3(0, 2, 0)]
    try writeTestPLY(to: url, initialNormals: normals)
    let mesh = try PLYMesh.load(url: url)
    expect(mesh.normals.allSatisfy { $0.isFinite }, "preview replaces non-finite normals")
    expect((0..<4).allSatisfy { mesh.normal($0) == .zero }, "invalid and degenerate normals stay unknown")
    expect(mesh.normal(4) == SIMD3(0, 1, 0), "preview normalizes valid directions")
    let result = await Task.detached {
      VertexColorBaker.bake(mesh: mesh, photos: [], progress: { _, _ in }, isCancelled: { false })
    }.value
    expect(result?.rgba.count == mesh.vertexCount * 4 && result?.seen == 0,
           "unphotographed vertices bake without crashing on invalid normals")
    expect(result.map { Array($0.rgba.prefix(4)) == [138, 138, 144, 255] } ?? false,
           "unknown normals receive neutral clay shading")
  }

  /// Texture projection preserves per-pixel detail, face accounting, and bounded allocations.
  private func photoTextures() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-textures")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let meshURL = folder.appendingPathComponent("test.ply"), photoURL = folder.appendingPathComponent("test.jpg")
    try writeTestPLY(to: meshURL)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: CGSize(width: 1920, height: 1440), format: format).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 1920, height: 1440))
      UIColor.red.setFill()
      for x in stride(from: 0, to: 1920, by: 8) { context.fill(CGRect(x: x, y: 0, width: 4, height: 1440)) }
    }
    try image.jpegData(compressionQuality: 1)!.write(to: photoURL)
    let mesh = try PLYMesh.load(url: meshURL)
    let photo = PreviewPhoto(id: 0, session: 0, url: photoURL, room: 0, timestamp: 0,
                             cameraToHouse: matrix_identity_float4x4, fx: 1400, fy: 1400, cx: 960, cy: 720,
                             width: 1920, height: 1440, sharpness: 1, gain: 1)
    let result = await Task.detached {
      PhotoTextures.build(mesh: mesh, inside: mesh.indices, outside: [], photos: [photo], pixelBudget: 2_000_000,
                          progress: { _ in }, isCancelled: { false })
    }.value
    expect(result != nil && (result?.triangleCount ?? 0) > 100, "photo texture assigned to visible mesh triangles")
    if let result {
      expect(result.triangleCount + result.insideFallback.count / 3 == mesh.faceCount, "textured and fallback faces cover the mesh exactly")
      expect(result.pixelCount > mesh.vertexCount * 10 && result.pixelCount <= 2_010_000, "texture detail exceeds vertex density within pixel budget")
      let sources = result.inside?.sources(for: .texcoord) ?? []
      expect(!sources.isEmpty && sources.allSatisfy { source in
        source.data.withUnsafeBytes { raw in
          raw.bindMemory(to: Float.self).allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
        }
      }, "cropped photo coordinates stay finite and inside their image")
    }
    let cancelled = PhotoTextures.build(mesh: mesh, inside: mesh.indices, outside: [], photos: [photo], pixelBudget: 2_000_000,
                                        progress: { _ in }, isCancelled: { true })
    expect(cancelled == nil, "texture building cancels without publishing partial geometry")
  }

  /// With a real bundle copied to Documents/selftest-bundle (photos, depth, mesh/room-*.ply in
  /// the app's format): load it as a zone's earlier session, with timings
  private func realBundle() async throws {
    let fm = FileManager.default
    let src = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("selftest-bundle", isDirectory: true)
    guard fm.fileExists(atPath: src.path) else {
      log("skip real bundle (no Documents/selftest-bundle)")
      return
    }
    var house = try HouseProject.create(name: "Selftest real \(HouseProject.folderName(for: Date()))")
    defer { try? fm.removeItem(at: house.url) }
    let zone = house.addZone(named: "Area 1")
    house.beginSession(id: "real", zone: zone.id, alignment: .init(method: "first"))
    try house.save()
    try fm.copyItem(at: src, to: house.url.appendingPathComponent("sessions/real", isDirectory: true))

    var t = Date()
    let snapshot = house
    let newestOnly = ZoneReference.load(house: snapshot, zone: zone.id, excludingSession: nil)
    expect(newestOnly.files == ["real/room-0.ply"], "newest non-empty PLY per session (\(newestOnly.files))")
    t = Date()
    let ref = await Task.detached { ZoneReference.load(house: snapshot, zone: zone.id, excludingSession: nil, allFiles: true) }.value
    let loadMs = Int(Date().timeIntervalSince(t) * 1000)
    log("real: \(ref.files) \(ref.sourceVertices) vertices → ghost \(ref.ghost?.triangleCount ?? 0) triangles / \(ref.ghost?.positions.count ?? 0) vertices, index \(ref.index.points.count) voxels, \(loadMs) ms, errors \(ref.errors)")
    expect(ref.errors.isEmpty && ref.sourceVertices > 100_000, "real PLYs parse (empty one included)")
    expect((ref.ghost?.triangleCount ?? 0) > 10_000 && (ref.ghost?.triangleCount ?? 0) < 600_000, "real ghost is a sane size")
    expect(loadMs < 20_000, "real zone loads in < 20 s (\(loadMs) ms)")

    // live-like samples: saved surface points with ±5 mm noise
    let step = max(1, ref.index.points.count / 3000)
    var pts: [ZoneReference.LivePoint] = []
    var k = 0
    while k < ref.index.points.count {
      let m = ref.index.normals[k]
      let n = simd_length(m) > 0.5 ? simd_normalize(m) : SIMD3<Float>.zero
      pts.append(.init(p: ref.index.points[k] + n * (Float((k * 7919) % 11) - 5) * 0.001, n: n))
      k += step
    }
    func describe(_ c: ZoneReference.Check) -> String {
      "walls \(c.wallMatched)/\(c.wallKnown) flat \(c.flatMatched)/\(c.flatKnown) all \(c.matched)/\(c.known) spread \(c.spreadDegrees)° median \(c.median.map { String(format: "%.3f", $0) } ?? "-")"
    }
    t = Date()
    let good = ref.check(pts)
    let checkMs = Int(Date().timeIntervalSince(t) * 1000)
    expect(good.isGood, "real: noisy samples of the saved surface verify (\(describe(good)), \(checkMs) ms)")
    for (label, offset) in [("36 cm shift", SIMD3<Float>(0.3, 0, 0.2)), ("15 cm shift", SIMD3<Float>(0.1, 0, 0.11)), ("10 cm up", SIMD3<Float>(0, 0.1, 0))] {
      let c = ref.check(pts.map { .init(p: $0.p + offset, n: $0.n) })
      expect(!c.isGood, "real: a \(label) doesn't verify (\(describe(c)))")
    }
    let center = ref.index.points.reduce(SIMD3<Float>.zero, +) / Float(max(1, ref.index.points.count))
    // where the line is (logged, not asserted): small errors the check tolerates
    for (label, offset) in [("3 cm", SIMD3<Float>(0.02, 0, 0.02)), ("6 cm", SIMD3<Float>(0.045, 0, 0.04)), ("9 cm", SIMD3<Float>(0.065, 0, 0.06))] {
      let c = ref.check(pts.map { .init(p: $0.p + offset, n: $0.n) })
      log("real: \(label) shift → good=\(c.isGood) (\(describe(c)))")
    }
    for degrees: Float in [1, 2] {
      let yaw = simd_quatf(angle: degrees * .pi / 180, axis: SIMD3(0, 1, 0))
      let c = ref.check(pts.map { .init(p: yaw.act($0.p - center) + center, n: yaw.act($0.n)) })
      log("real: \(Int(degrees))° turn → good=\(c.isGood) (\(describe(c)))")
    }
    for degrees: Float in [9, 4] {
      let yaw = simd_quatf(angle: degrees * .pi / 180, axis: SIMD3(0, 1, 0))
      let c = ref.check(pts.map { .init(p: yaw.act($0.p - center) + center, n: yaw.act($0.n)) })
      expect(!c.isGood, "real: a \(Int(degrees))° turn doesn't verify (\(describe(c)))")
    }

    t = Date()
    let prior = await Task.detached { PriorPhotos.load(house: snapshot, zone: zone.id, excludingSession: nil) }.value
    let photoCount = house.bundle(for: house.sessions[0]).photos.count
    log("real: \(prior.count) of \(photoCount) photos have a depth frame (\(Int(Date().timeIntervalSince(t) * 1000)) ms)")
    expect(prior.count > photoCount / 3, "real: most photos get occlusion depth")
    expect(PriorPhotos.landmarks(house: house, zone: zone.id).count >= 2, "real: landmarks")
  }

  // MARK: fixtures

  /// Same layout CoverageEngine.writePLY produces: a wall (z = -2, facing +z) and a floor
  private func writeTestPLY(to url: URL, initialNormals: [SIMD3<Float>] = []) throws {
    var verts: [(SIMD3<Float>, SIMD3<Float>)] = []
    var faces: [(UInt32, UInt32, UInt32)] = []
    func grid(_ origin: SIMD3<Float>, _ u: SIMD3<Float>, _ v: SIMD3<Float>, _ n: SIMD3<Float>, _ nu: Int, _ nv: Int) {
      let base = UInt32(verts.count)
      for j in 0...nv { for i in 0...nu { verts.append((origin + u * Float(i) + v * Float(j), n)) } }
      let w = UInt32(nu + 1)
      for j in 0..<UInt32(nv) {
        for i in 0..<UInt32(nu) {
          let a = base + j * w + i
          faces.append((a, a + 1, a + w + 1))
          faces.append((a, a + w + 1, a + w))
        }
      }
    }
    grid(SIMD3(-1.5, 0, -2), SIMD3(0.03, 0, 0), SIMD3(0, 0.03, 0), SIMD3(0, 0, 1), 100, 80)
    grid(SIMD3(-1.5, 0, -2), SIMD3(0.03, 0, 0), SIMD3(0, 0, 0.03), SIMD3(0, 1, 0), 100, 60)
    grid(SIMD3(-1.5, 0, -2), SIMD3(0, 0, 0.03), SIMD3(0, 0.03, 0), SIMD3(1, 0, 0), 60, 80)
    var header = "ply\nformat binary_little_endian 1.0\n"
    header += "comment selftest\n"
    header += "element vertex \(verts.count)\nproperty float x\nproperty float y\nproperty float z\n"
    header += "property float nx\nproperty float ny\nproperty float nz\nproperty float coverage\n"
    header += "property uchar red\nproperty uchar green\nproperty uchar blue\nproperty uchar inroom\n"
    header += "element face \(faces.count)\nproperty list uchar uint vertex_indices\nproperty uchar class\nend_header\n"
    var data = Data(header.utf8)
    func put<T>(_ v: T) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
    for (i, vertex) in verts.enumerated() {
      let (p, normal) = vertex
      let n = i < initialNormals.count ? initialNormals[i] : normal
      put(p.x); put(p.y); put(p.z); put(n.x); put(n.y); put(n.z); put(Float(1))
      put(UInt8(52)); put(UInt8(199)); put(UInt8(89)); put(UInt8(1))
    }
    for f in faces { put(UInt8(3)); put(f.0); put(f.1); put(f.2); put(UInt8(1)) }
    try data.write(to: url)
  }

  /// One photo looking at the wall from 2 m, and a depth frame from the same spot (2 m everywhere)
  private func writeTestPhotos(_ bundle: ScanBundle) throws {
    let pose = matrix_identity_float4x4 // at the origin, looking down -z at the wall
    let photo = PhotoRecord(file: "photos/0000.jpg", room: 0, timestamp: 1, width: 1920, height: 1440, transform: pose.columnMajor,
                            intrinsics: [1400, 0, 0, 0, 1400, 0, 960, 720, 1], tracking: "normal", manual: false, exposure: 0.01, blurPixels: 0.5)
    try bundle.savePhotos([photo])
    try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: bundle.file(photo.file))
    let w = 256, h = 192
    let depth = [Float16](repeating: 2, count: w * h).withUnsafeBufferPointer { Data(buffer: $0) }
    try ((depth as NSData).compressed(using: .zlib) as Data).write(to: bundle.file("depth/00000.f16z"))
    try Data(repeating: 2, count: w * h).write(to: bundle.file("depth/00000.conf"))
    let record = DepthRecorder.Record(file: "depth/00000.f16z", confidence: "depth/00000.conf", rgb: nil, rgbIntrinsics: nil, camera: nil, room: 0,
                                      timestamp: 1.05, width: w, height: h, transform: pose.columnMajor, intrinsics: [186.7, 0, 0, 0, 186.7, 0, 128, 96, 1])
    try JSONEncoder().encode([record]).write(to: bundle.file("depth/frames.json"))
  }
}
