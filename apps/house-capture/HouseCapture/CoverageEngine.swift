import ARKit
import Foundation
import RoomPlan
import simd

/// Scores every point of the LiDAR mesh (and of RoomPlan's surfaces) by how well
/// the photos taken so far show it: close enough for detail, roughly head-on,
/// sharp, and not hidden behind something (checked against each photo's depth).
///
/// All state lives on a private serial queue. Inputs (mesh anchors, photos, the
/// room outline) are copied in; results come back on the main queue.
final class CoverageEngine: @unchecked Sendable {
  // MARK: public types

  /// A photo as the engine needs it: where it looked from, its lens, how sharp it was
  struct Photo {
    var worldToCamera: simd_float4x4
    var position: SIMD3<Float>
    var fx: Float, fy: Float, cx: Float, cy: Float
    var width: Float, height: Float
    /// 1 = sharp; lower for blurrier frames
    var sharpness: Float
    var depth: DepthGrid?
    var room: Int
  }

  /// Low-res depth (meters along the camera axis) with its own pose, for occlusion tests
  struct DepthGrid {
    var width: Int, height: Int
    var values: [Float]
    var worldToCamera: simd_float4x4
    var fx: Float, fy: Float, cx: Float, cy: Float
  }

  /// A sampled point on one of RoomPlan's surfaces (walls, floor, ceiling, furniture boxes)
  struct Target {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var area: Float
  }

  struct Stats: Equatable {
    /// Fraction of observed mesh area inside the outline that is photographed well.
    /// This does not measure how much of the whole room has been scanned.
    var meshCovered: Float = 0
    var meshArea: Float = 0
    /// same, over RoomPlan's surfaces: catches areas the LiDAR hasn't even reached yet
    var targetsCovered: Float = 0
    /// where the remaining gaps are (world x/z), for the map; a few hundred at most
    var redSpots: [SIMD2<Float>] = []
    /// RoomPlan's ceiling / floor surfaces that are well photographed (1 if there's no layout yet)
    var ceilingCovered: Float = 1
    var floorCovered: Float = 1
    /// Photo detail on observed geometry, without penalties for inferred hidden surfaces.
    var percent: Int {
      guard meshArea > 0.5, meshCovered.isFinite else { return 0 }
      return Int((min(1, max(0, meshCovered)) * 100).rounded())
    }
  }

  enum Hint: Equatable {
    case none
    case turn(angle: Float) // radians, + = to the right
    case lookUp
    case lookDown
    case getCloser
    case done
  }

  /// Geometry for one mesh anchor, ready for SceneKit (anchor-local coordinates), with its
  /// triangles split by coverage band and facet shade for the live scan overlay
  struct AnchorMesh {
    var id: UUID
    var positions: Data // SIMD3<Float> array bytes (16-byte stride)
    var normals: Data
    var vertexCount: Int
    /// Three facet shades per coverage band: needs photos, almost, done, outside the room.
    /// Material index = coverage band * 3 + shade.
    var bands: [Data]
    var bandCounts: [Int]
  }

  /// Called on main with anchors whose colors (or geometry) changed
  var onMeshes: (([AnchorMesh]) -> Void)?
  var onStats: ((Stats) -> Void)?

  /// Latest estimate of how much the current view would add, in m² of surface
  private(set) var latestGain: Float {
    get { lock.withLock { _latestGain } }
    set { lock.withLock { _latestGain = newValue } }
  }
  private(set) var latestHint: Hint {
    get { lock.withLock { _latestHint } }
    set { lock.withLock { _latestHint = newValue } }
  }
  private var _latestGain: Float = 0
  private var _latestHint: Hint = .none
  private let lock = NSLock()

  // MARK: private state (queue only)

  private let queue = DispatchQueue(label: "coverage", qos: .userInitiated)

  private final class AnchorData {
    let id: UUID
    var transform: simd_float4x4 = matrix_identity_float4x4
    var local: [SIMD3<Float>] = []
    var localNormals: [SIMD3<Float>] = []
    var world: [SIMD3<Float>] = []
    var worldNormals: [SIMD3<Float>] = []
    var area: [Float] = []
    var score: [Float] = []
    var inRoom: [Bool] = []
    var faces: [UInt32] = []
    var classes: [UInt8] = [] // per face
    var center = SIMD3<Float>(repeating: 0)
    var radius: Float = 0
    init(id: UUID) { self.id = id }
  }

  private var anchors: [UUID: AnchorData] = [:]
  private let pending = CoverageMailbox<UUID, ARMeshAnchor.Snapshot>()
  private let pendingRooms = CoverageMailbox<Int, ([Target], [SIMD2<Float>], Float, Float)>()
  private let pendingMeshes = CoverageMailbox<UUID, AnchorMesh>()
  private var photos: [Photo] = []
  private var targets: [Target] = []
  private var targetScore: [Float] = []
  private var outline: [SIMD2<Float>] = []
  private var floorY: Float = -10
  private var ceilingY: Float = 10
  private var statsScheduled = false
  private var ceilingFraction: Float = 1

  static let goodScore: Float = 0.8 // a vertex is "done" (green) at this score: one clean photo within ~3 m

  // MARK: inputs

  /// Room outline (world x/z) + vertical range, and RoomPlan surface samples
  func setRoom(_ room: CapturedRoom?) {
    let targets = room.map(Self.targets(for:)) ?? []
    let (outline, floor, ceiling) = room.map(Self.bounds(for:)) ?? ([], -10, 10)
    if pendingRooms.offer(0, (targets, outline, floor, ceiling)) {
      queue.async { self.applyPendingRoom() }
    }
  }

  private func applyPendingRoom() {
    if let (_, value) = pendingRooms.take(limit: 1).first {
      (targets, outline, floorY, ceilingY) = value
      scoreTargets()
      for a in anchors.values { classify(a) }
      publishStats()
    }
    if pendingRooms.finish() { queue.async { self.applyPendingRoom() } }
  }

  /// Mesh anchor added or updated. Copies the geometry immediately (call from any thread).
  func update(_ anchor: ARMeshAnchor) {
    update(snapshot: anchor.snapshot())
  }

  /// Coalesce before entering the worker queue: at most one waiting snapshot per anchor.
  func update(snapshot: ARMeshAnchor.Snapshot) {
    if pending.offer(snapshot.id, snapshot) {
      queue.asyncAfter(deadline: .now() + 0.15) { self.drain() }
    }
  }

  /// Preserve the last snapshot even if RoomPlan removes anchors while stopping.
  func remove(_ id: UUID) {}

  func add(_ photo: Photo) {
    queue.async {
      self.photos.append(photo)
      var changed: [AnchorMesh] = []
      for a in self.anchors.values where self.score(a, with: photo) {
        changed.append(self.mesh(for: a))
      }
      for i in self.targets.indices {
        if self.targetScore[i] < 2 {
          self.targetScore[i] = min(2, self.targetScore[i] + Self.contribution(photo, self.targets[i].position, self.targets[i].normal, twoSided: true))
        }
      }
      self.emit(changed)
      self.publishStats()
    }
  }

  /// Many photos at once (a Continue session's earlier photos of the zone): one rescore pass
  func add(contentsOf photos: [Photo]) {
    guard !photos.isEmpty else { return }
    queue.async {
      self.photos.append(contentsOf: photos)
      var changed: [AnchorMesh] = []
      for a in self.anchors.values {
        self.rescore(a)
        changed.append(self.mesh(for: a))
      }
      self.scoreTargets()
      self.emit(changed)
      self.publishStats()
    }
  }

  /// Rebuild all scores from scratch (after photos were discarded)
  func reset(photos: [Photo]) {
    queue.async {
      self.photos = photos
      var changed: [AnchorMesh] = []
      for a in self.anchors.values {
        self.rescore(a)
        changed.append(self.mesh(for: a))
      }
      self.scoreTargets()
      self.emit(changed)
      self.publishStats()
    }
  }

  /// Estimate what a photo from this camera would add, plus where the remaining gaps are.
  /// Results land in `latestGain` / `latestHint`.
  func evaluate(view: Photo) {
    // keep only the newest request so a busy queue never builds a backlog
    let schedule = lock.withLock { () -> Bool in
      let idle = pendingView == nil
      pendingView = view
      return idle
    }
    guard schedule else { return }
    queue.async {
      guard let view = self.lock.withLock({ () -> Photo? in
        defer { self.pendingView = nil }
        return self.pendingView
      }) else { return }
      self.latestGain = self.gain(view)
      self.latestHint = self.hint(from: view)
    }
  }
  private var pendingView: Photo?

  var pendingMeshUpdates: Int { pending.counts.pending }
  var coalescedMeshUpdates: Int { pending.counts.replaced }

  /// Measure waiting time without holding an ARFrame or geometry buffers.
  func measureQueueDelay(_ done: @escaping (Double) -> Void) {
    let start = CACurrentMediaTime()
    queue.async {
      let milliseconds = (CACurrentMediaTime() - start) * 1000
      DispatchQueue.main.async { done(milliseconds) }
    }
  }

  /// Why photos do or don't count for the current mesh (debugging on device)
  func debugReport(_ done: @escaping (String) -> Void) {
    queue.async {
      var out: [String] = []
      for (pi, ph) in self.photos.enumerated() {
        var r = [0, 0, 0, 0, 0] // far/behind, out of frame, grazing, occluded, ok
        for a in self.anchors.values {
          for i in a.world.indices {
            let p = a.world[i], n = a.worldNormals[i]
            let c = ph.worldToCamera * SIMD4(p, 1)
            let d = -c.z
            if !(d > 0.25 && d < 5) { r[0] += 1; continue }
            let u = ph.fx * c.x / d + ph.cx, v = ph.fy * -c.y / d + ph.cy
            if !(u > ph.width * 0.03 && u < ph.width * 0.97 && v > ph.height * 0.03 && v < ph.height * 0.97) { r[1] += 1; continue }
            if simd_dot(n, simd_normalize(ph.position - p)) <= 0.2 { r[2] += 1; continue }
            if Self.contribution(ph, p, n) == 0 { r[3] += 1; continue }
            r[4] += 1
          }
        }
        var g = "no depth"
        if let dg = ph.depth {
          let vals = dg.values.filter { $0 > 0 }.sorted()
          g = "grid \(dg.width)x\(dg.height) fx=\(dg.fx) cx=\(dg.cx) cy=\(dg.cy) min=\(vals.first ?? 0) median=\(vals.isEmpty ? 0 : vals[vals.count / 2]) zeros=\(dg.values.count - vals.count)"
        }
        out.append("photo \(pi): \(Int(ph.width))x\(Int(ph.height)) fx=\(ph.fx) sharp=\(ph.sharpness) far=\(r[0]) frame=\(r[1]) grazing=\(r[2]) occluded=\(r[3]) ok=\(r[4]) | \(g)")
      }
      DispatchQueue.main.async { done(out.joined(separator: "\n")) }
    }
  }

  // MARK: export

  /// Binary PLY of every anchor in world space: position, normal, coverage score,
  /// coverage color per vertex; ARKit classification per face.
  func exportPLY(to url: URL, completion: @escaping (Result<(vertices: Int, faces: Int, covered: Float), Error>) -> Void) {
    queue.async {
      do {
        // Export is a barrier for the newest accepted geometry, including updates whose
        // regular drain hasn't run yet. Snapshot the mailbox once; don't chase live input.
        // Leave scheduling ownership to the already queued room consumer.
        if let (_, value) = self.pendingRooms.take().first {
          (self.targets, self.outline, self.floorY, self.ceilingY) = value
          self.scoreTargets()
          for a in self.anchors.values { self.classify(a) }
        }
        self.process(self.pending.take())
        let result = try self.writePLY(url)
        DispatchQueue.main.async { completion(.success(result)) }
      } catch {
        DispatchQueue.main.async { completion(.failure(error)) }
      }
    }
  }

  // MARK: - scoring

  /// How much one photo contributes to seeing point p (normal n) well, 0...1
  static func contribution(_ ph: Photo, _ p: SIMD3<Float>, _ n: SIMD3<Float>, twoSided: Bool = false) -> Float {
    let c = ph.worldToCamera * SIMD4(p, 1)
    let d = -c.z
    guard d > 0.25, d < 5 else { return 0 }
    let u = ph.fx * c.x / d + ph.cx
    let v = ph.fy * -c.y / d + ph.cy
    guard u > ph.width * 0.03, u < ph.width * 0.97, v > ph.height * 0.03, v < ph.height * 0.97 else { return 0 }
    let toCam = simd_normalize(ph.position - p)
    var cosT = simd_dot(n, toCam)
    if twoSided { cosT = abs(cosT) }
    guard cosT > 0.2 else { return 0 }
    var occlusionFactor: Float = 0.9 // no depth to check against: count it, a bit less
    if let g = ph.depth {
      let cg = g.worldToCamera * SIMD4(p, 1)
      let dg = -cg.z
      guard dg > 0.05 else { return 0 }
      let gu = Int(g.fx * cg.x / dg + g.cx), gv = Int(g.fy * -cg.y / dg + g.cy)
      if gu >= 0, gu < g.width, gv >= 0, gv < g.height {
        let surface = g.values[gv * g.width + gu]
        if surface > 0, dg > surface + 0.06 + 0.03 * surface { return 0 } // something's in front
        occlusionFactor = 1
      }
    }
    // pixels per centimeter on the surface; ~4 px/cm reads fine detail (labels, trim edges)
    let pxPerCm = ph.fx * cosT / d / 100
    return min(1, pxPerCm / 4) * ph.sharpness * occlusionFactor
  }

  /// Cheap reject: the photo is too far from this anchor, or it's entirely behind the camera
  private static func mightSee(_ ph: Photo, _ a: AnchorData) -> Bool {
    let d = simd_distance(ph.position, a.center)
    guard d < 5 + a.radius else { return false }
    let c = ph.worldToCamera * SIMD4(a.center, 1)
    return -c.z > -a.radius // some part of the sphere is in front
  }

  /// Add one photo to an anchor's scores; true if any vertex changed color band
  private func score(_ a: AnchorData, with photo: Photo) -> Bool {
    guard Self.mightSee(photo, a) else { return false }
    var changed = false
    for i in a.world.indices where a.score[i] < 2 {
      let q = Self.contribution(photo, a.world[i], a.worldNormals[i])
      if q > 0 {
        let before = Self.band(a.score[i])
        a.score[i] = min(2, a.score[i] + q)
        if Self.band(a.score[i]) != before { changed = true }
      }
    }
    return changed
  }

  private func rescore(_ a: AnchorData, previousWorld: [SIMD3<Float>] = [], previousNormals: [SIMD3<Float>] = [], previousScores: [Float] = []) {
    let relevant = photos.filter { Self.mightSee($0, a) }
    for i in a.world.indices {
      // ARKit often updates only part of an anchor. Exact equality is safe; fuzzy
      // spatial caching could incorrectly carry coverage across an edge or occluder.
      if i < previousWorld.count, i < previousNormals.count, i < previousScores.count,
         a.world[i] == previousWorld[i], a.worldNormals[i] == previousNormals[i] {
        a.score[i] = previousScores[i]
        continue
      }
      a.score[i] = Self.coverageScore(relevant, at: a.world[i], normal: a.worldNormals[i])
    }
  }

  /// Score RoomPlan's surface samples against every photo that could reach them (photos more
  /// than 5 m from the room can't: skip them, a Continue session can bring thousands)
  private func scoreTargets() {
    guard let first = targets.first else {
      targetScore = []
      return
    }
    let lo = targets.reduce(first.position) { simd_min($0, $1.position) }
    let hi = targets.reduce(first.position) { simd_max($0, $1.position) }
    let center = (lo + hi) / 2, radius = simd_length(hi - lo) / 2
    let relevant = photos.filter { simd_distance($0.position, center) < radius + 5 }
    targetScore = targets.map { Self.coverageScore(relevant, at: $0.position, normal: $0.normal, twoSided: true) }
  }

  private static func band(_ s: Float) -> Int { s < 0.35 ? 0 : s < goodScore ? 1 : 2 }

  /// Keep the original cap of 2 (not just the green threshold): triangle colors
  /// average three vertex scores, so lowering the cap would change the visible result.
  static func coverageScore(_ photos: [Photo], at point: SIMD3<Float>, normal: SIMD3<Float>, twoSided: Bool = false) -> Float {
    var score: Float = 0
    for photo in photos {
      score += contribution(photo, point, normal, twoSided: twoSided)
      if score >= 2 { return 2 }
    }
    return score
  }

  private func drain() {
    // Yield between small batches so camera guidance, new photos, and diagnostics
    // aren't trapped behind a full-room rescore. FIFO keys avoid starving old anchors.
    process(pending.take(limit: 2))
    if pending.finish() { queue.async { self.drain() } }
  }

  private func process(_ batch: [(UUID, ARMeshAnchor.Snapshot)]) {
    var changed: [AnchorMesh] = []
    for (id, snap) in batch {
      let a = anchors[id] ?? AnchorData(id: id)
      anchors[id] = a
      let previousWorld = a.world, previousNormals = a.worldNormals, previousScores = a.score
      a.transform = snap.transform
      a.local = snap.positions
      a.localNormals = snap.normals
      a.faces = snap.faces
      a.classes = snap.classes
      let rot = simd_float3x3(SIMD3(snap.transform.columns.0.x, snap.transform.columns.0.y, snap.transform.columns.0.z),
                              SIMD3(snap.transform.columns.1.x, snap.transform.columns.1.y, snap.transform.columns.1.z),
                              SIMD3(snap.transform.columns.2.x, snap.transform.columns.2.y, snap.transform.columns.2.z))
      a.world = snap.positions.map { simd_make_float3(snap.transform * SIMD4($0, 1)) }
      a.worldNormals = snap.normals.map {
        let normal = rot * $0
        let length = simd_length(normal)
        return length.isFinite && length > 1e-6 ? normal / length : .zero
      }
      // per-vertex area: a third of each adjacent triangle
      var area = [Float](repeating: 0, count: a.world.count)
      var f = 0
      while f + 2 < a.faces.count {
        let i0 = Int(a.faces[f]), i1 = Int(a.faces[f + 1]), i2 = Int(a.faces[f + 2])
        let t = simd_length(simd_cross(a.world[i1] - a.world[i0], a.world[i2] - a.world[i0])) / 6
        area[i0] += t; area[i1] += t; area[i2] += t
        f += 3
      }
      a.area = area
      if let first = a.world.first {
        let lo = a.world.reduce(first) { simd_min($0, $1) }, hi = a.world.reduce(first) { simd_max($0, $1) }
        a.center = (lo + hi) / 2
        a.radius = simd_length(hi - lo) / 2
      }
      a.score = [Float](repeating: 0, count: a.world.count)
      classify(a)
      rescore(a, previousWorld: previousWorld, previousNormals: previousNormals, previousScores: previousScores)
      changed.append(mesh(for: a))
    }
    emit(changed)
    publishStats()
  }

  /// Which vertices belong to the current room (inside its outline, between floor and ceiling)
  private func classify(_ a: AnchorData) {
    guard outline.count >= 3 else {
      a.inRoom = [Bool](repeating: true, count: a.world.count)
      return
    }
    a.inRoom = a.world.map { p in
      guard p.y > floorY - 0.1, p.y < ceilingY + 0.2 else { return false }
      for (dx, dz) in [(0, 0), (0.25, 0), (-0.25, 0), (0, 0.25), (0, -0.25)] as [(Float, Float)] {
        if Self.inside(outline, SIMD2(p.x + dx, p.z + dz)) { return true }
      }
      return false
    }
  }

  // MARK: - gain + guidance

  private func gain(_ view: Photo) -> Float {
    var g: Float = 0
    for a in anchors.values where Self.mightSee(view, a) {
      // every 3rd vertex is plenty for an estimate
      var i = 0
      while i < a.world.count {
        if a.inRoom[i], a.score[i] < Self.goodScore {
          let q = Self.contribution(view, a.world[i], a.worldNormals[i])
          if q > 0 { g += a.area[i] * 3 * min(q, Self.goodScore - a.score[i]) }
        }
        i += 3
      }
    }
    for (i, t) in targets.enumerated() where targetScore[i] < Self.goodScore {
      let q = Self.contribution(view, t.position, t.normal, twoSided: true)
      if q > 0 { g += t.area * min(q, Self.goodScore - targetScore[i]) }
    }
    return g
  }

  /// Point toward the biggest remaining gap near you
  private func hint(from view: Photo) -> Hint {
    let camToWorld = view.worldToCamera.inverse
    let forward = -simd_normalize(simd_make_float3(camToWorld.columns.2))
    let flatF = simd_normalize(SIMD2(forward.x, forward.z) + SIMD2(1e-5, 0))
    var bins = [Float](repeating: 0, count: 12)
    var dist = [Float](repeating: 0, count: 12)
    var up: Float = 0, down: Float = 0, total: Float = 0
    func consider(_ p: SIMD3<Float>, _ w: Float) {
      let v = p - view.position
      let d = simd_length(v)
      guard d > 0.2, d < 6 else { return }
      let dir = v / d
      let weight = w / max(1, d * 0.5)
      total += weight
      if dir.y > 0.75 { up += weight; return }
      if dir.y < -0.8 { down += weight; return }
      let flat = SIMD2(dir.x, dir.z)
      let angle = atan2(flatF.x * flat.y - flatF.y * flat.x, simd_dot(flatF, flat)) // + = right
      let b = Int(((angle + .pi) / (2 * .pi) * 12).rounded(.down)) % 12
      bins[b] += weight
      dist[b] += weight * d
    }
    for a in anchors.values {
      var i = 0
      while i < a.world.count {
        if a.inRoom[i], a.score[i] < 0.35 { consider(a.world[i], a.area[i] * 4) }
        i += 4
      }
    }
    for (i, t) in targets.enumerated() where targetScore[i] < 0.35 { consider(t.position, t.area * 1.5) }
    let hasContent = !targets.isEmpty || anchors.values.contains { !$0.world.isEmpty }
    guard total > 0.05 else { return hasContent ? .done : .none }
    // the ceiling is the part everyone forgets: ask for it until it's mostly covered
    if ceilingFraction < 0.6, up > 0.02, forward.y < 0.35 { return .lookUp }
    let best = bins.indices.max { bins[$0] < bins[$1] }!
    if up > bins[best], up > down { return .lookUp }
    if down > bins[best] { return .lookDown }
    let angle = (Float(best) + 0.5) / 12 * 2 * .pi - .pi
    if abs(angle) < .pi / 6 {
      return dist[best] / max(bins[best], 1e-6) > 3 ? .getCloser : .none
    }
    return .turn(angle: angle)
  }

  // MARK: - outputs

  private func mesh(for a: AnchorData) -> AnchorMesh {
    var bands = [[UInt32]](repeating: [], count: 12)
    var f = 0
    while f + 2 < a.faces.count {
      let i0 = Int(a.faces[f]), i1 = Int(a.faces[f + 1]), i2 = Int(a.faces[f + 2])
      // ARKit fills unseen gaps with long sliver triangles; they still count for coverage
      // but drawing them looks like shattered glass
      let l = a.local
      if simd_distance(l[i0], l[i1]) > 0.35 || simd_distance(l[i1], l[i2]) > 0.35 || simd_distance(l[i2], l[i0]) > 0.35 {
        f += 3
        continue
      }
      let band: Int
      if !a.inRoom.isEmpty, !(a.inRoom[i0] || a.inRoom[i1] || a.inRoom[i2]) {
        band = 3
      } else {
        band = Self.band((a.score[i0] + a.score[i1] + a.score[i2]) / 3)
      }
      // Stable for a triangle across coverage updates; adjacent faces get different jewel tones.
      let hash = (a.faces[f] &* 73856093) ^ (a.faces[f + 1] &* 19349663) ^ (a.faces[f + 2] &* 83492791)
      let shade = Int(hash % 3)
      bands[band * 3 + shade].append(contentsOf: [a.faces[f], a.faces[f + 1], a.faces[f + 2]])
      f += 3
    }
    return AnchorMesh(
      id: a.id,
      positions: a.local.withUnsafeBufferPointer { Data(buffer: $0) },
      normals: a.localNormals.withUnsafeBufferPointer { Data(buffer: $0) },
      vertexCount: a.local.count,
      bands: bands.map { b in b.withUnsafeBufferPointer { Data(buffer: $0) } },
      bandCounts: bands.map { $0.count / 3 }
    )
  }

  /// red → amber → green; things outside the room fade to neutral grey
  static func color(_ s: Float, inRoom: Bool) -> (UInt8, UInt8, UInt8, UInt8) {
    guard inRoom else { return (150, 150, 160, 255) }
    if s < 0.35 { return (255, 59, 48, 255) }
    if s < goodScore {
      let t = (s - 0.35) / (goodScore - 0.35)
      return (255, UInt8(149 + 60 * t), UInt8(0 + 40 * t), 255)
    }
    return (52, 199, 89, 255)
  }

  private func emit(_ meshes: [AnchorMesh]) {
    var schedule = false
    for mesh in meshes { if pendingMeshes.offer(mesh.id, mesh) { schedule = true } }
    if schedule { DispatchQueue.main.async { self.deliverMeshes() } }
  }

  private func deliverMeshes() {
    let meshes = pendingMeshes.take(limit: 4).map { $0.1 }
    if !meshes.isEmpty { onMeshes?(meshes) }
    if pendingMeshes.finish() { DispatchQueue.main.async { self.deliverMeshes() } }
  }

  /// Stats are cheap-ish but not free; publish at most ~4× a second
  private func publishStats() {
    guard !statsScheduled else { return }
    statsScheduled = true
    queue.asyncAfter(deadline: .now() + 0.25) {
      self.statsScheduled = false
      var s = Stats()
      var covered: Float = 0
      for a in self.anchors.values {
        for i in a.world.indices where a.inRoom[i] {
          s.meshArea += a.area[i]
          if a.score[i] >= Self.goodScore { covered += a.area[i] }
        }
      }
      s.meshCovered = s.meshArea > 0 ? covered / s.meshArea : 0
      var tArea: Float = 0, tCovered: Float = 0
      var cA: Float = 0, cC: Float = 0, fA: Float = 0, fC: Float = 0
      for (i, t) in self.targets.enumerated() {
        tArea += t.area
        let ok = self.targetScore[i] >= Self.goodScore
        if ok { tCovered += t.area }
        if t.normal.y < -0.9 { cA += t.area; if ok { cC += t.area } }
        if t.normal.y > 0.9 { fA += t.area; if ok { fC += t.area } }
      }
      s.ceilingCovered = cA > 0 ? cC / cA : 1
      s.floorCovered = fA > 0 ? fC / fA : 1
      self.ceilingFraction = s.ceilingCovered
      s.targetsCovered = tArea > 0 ? tCovered / tArea : 0
      var spots: [SIMD2<Float>] = []
      for (i, t) in self.targets.enumerated() where self.targetScore[i] < 0.35 { spots.append(SIMD2(t.position.x, t.position.z)) }
      for a in self.anchors.values {
        var i = 0
        while i < a.world.count {
          if a.inRoom[i], a.score[i] < 0.35 { spots.append(SIMD2(a.world[i].x, a.world[i].z)) }
          i += 25
        }
      }
      if spots.count > 400 { spots = stride(from: 0, to: spots.count, by: spots.count / 400 + 1).map { spots[$0] } }
      s.redSpots = spots
      if let onStats = self.onStats { DispatchQueue.main.async { onStats(s) } }
    }
  }

  private func writePLY(_ url: URL) throws -> (vertices: Int, faces: Int, covered: Float) {
    let list = Array(anchors.values)
    let vCount = list.reduce(0) { $0 + $1.world.count }
    let fCount = list.reduce(0) { $0 + $1.faces.count / 3 }
    var header = "ply\nformat binary_little_endian 1.0\n"
    header += "comment house-capture LiDAR mesh, ARKit world space (meters, +Y up)\n"
    header += "comment coverage: photo coverage score (>= 0.8 means well photographed)\n"
    header += "comment class: 0 none 1 wall 2 floor 3 ceiling 4 table 5 seat 6 window 7 door\n"
    header += "element vertex \(vCount)\nproperty float x\nproperty float y\nproperty float z\n"
    header += "property float nx\nproperty float ny\nproperty float nz\nproperty float coverage\n"
    header += "property uchar red\nproperty uchar green\nproperty uchar blue\nproperty uchar inroom\n"
    header += "element face \(fCount)\nproperty list uchar uint vertex_indices\nproperty uchar class\nend_header\n"
    var data = Data(header.utf8)
    data.reserveCapacity(data.count + vCount * 32 + fCount * 14)
    func put<T>(_ v: T) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
    var covered: Float = 0, total: Float = 0
    for a in list {
      for i in a.world.indices {
        let p = a.world[i], n = a.worldNormals[i]
        put(p.x); put(p.y); put(p.z); put(n.x); put(n.y); put(n.z); put(a.score[i])
        let c = Self.color(a.score[i], inRoom: a.inRoom[i])
        put(c.0); put(c.1); put(c.2); put(UInt8(a.inRoom[i] ? 1 : 0))
        if a.inRoom[i] {
          total += a.area[i]
          if a.score[i] >= Self.goodScore { covered += a.area[i] }
        }
      }
    }
    var offset: UInt32 = 0
    for a in list {
      var f = 0
      while f + 2 < a.faces.count {
        put(UInt8(3)); put(a.faces[f] + offset); put(a.faces[f + 1] + offset); put(a.faces[f + 2] + offset)
        put(f / 3 < a.classes.count ? a.classes[f / 3] : 0)
        f += 3
      }
      offset += UInt32(a.world.count)
    }
    try data.write(to: url)
    return (vCount, fCount, total > 0 ? covered / total : 0)
  }

  // MARK: - room geometry helpers

  private static func inside(_ poly: [SIMD2<Float>], _ p: SIMD2<Float>) -> Bool {
    var hit = false
    var j = poly.count - 1
    for i in poly.indices {
      let a = poly[i], b = poly[j]
      if (a.y > p.y) != (b.y > p.y), p.x < a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y) { hit.toggle() }
      j = i
    }
    return hit
  }

  static func bounds(for room: CapturedRoom) -> ([SIMD2<Float>], Float, Float) {
    var outline: [SIMD2<Float>] = []
    var floorY: Float = .infinity
    if let floor = room.floors.first, !floor.polygonCorners.isEmpty {
      outline = floor.polygonCorners.map { c in
        let w = floor.transform * SIMD4(c, 1)
        return SIMD2(w.x, w.z)
      }
      floorY = floor.transform.columns.3.y
    }
    var top: Float = -.infinity
    for w in room.walls {
      let cy = w.transform.columns.3.y
      floorY = min(floorY, cy - w.dimensions.y / 2)
      top = max(top, cy + w.dimensions.y / 2)
    }
    if outline.isEmpty { // fall back to the wall endpoints' bounding box
      let ends = room.walls.flatMap { w -> [SIMD2<Float>] in
        let c = w.transform.columns.3, x = w.transform.columns.0 * (w.dimensions.x / 2)
        return [SIMD2(c.x - x.x, c.z - x.z), SIMD2(c.x + x.x, c.z + x.z)]
      }
      if let first = ends.first {
        let lo = ends.reduce(first) { simd_min($0, $1) }, hi = ends.reduce(first) { simd_max($0, $1) }
        outline = [lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y)]
      }
    }
    return (outline, floorY.isFinite ? floorY : -10, top.isFinite ? top : 10)
  }

  /// Sample RoomPlan's walls, floor, ceiling and furniture boxes every ~30 cm
  static func targets(for room: CapturedRoom) -> [Target] {
    var out: [Target] = []
    let step: Float = 0.3
    func surface(_ t: simd_float4x4, _ w: Float, _ h: Float, _ n: SIMD3<Float>) {
      let x = simd_make_float3(t.columns.0), y = simd_make_float3(t.columns.1)
      let c = simd_make_float3(t.columns.3)
      let nu = max(1, Int(w / step)), nv = max(1, Int(h / step))
      for i in 0..<nu {
        for j in 0..<nv {
          let p = c + x * ((Float(i) + 0.5) / Float(nu) - 0.5) * w + y * ((Float(j) + 0.5) / Float(nv) - 0.5) * h
          out.append(Target(position: p, normal: n, area: (w / Float(nu)) * (h / Float(nv))))
        }
      }
    }
    for wall in room.walls {
      surface(wall.transform, wall.dimensions.x, wall.dimensions.y, simd_make_float3(wall.transform.columns.2))
    }
    let (outline, floorY, ceilingY) = bounds(for: room)
    if outline.count >= 3 {
      let lo = outline.reduce(outline[0]) { simd_min($0, $1) }, hi = outline.reduce(outline[0]) { simd_max($0, $1) }
      var x = lo.x + step / 2
      while x < hi.x {
        var z = lo.y + step / 2
        while z < hi.y {
          if inside(outline, SIMD2(x, z)) {
            out.append(Target(position: SIMD3(x, floorY, z), normal: SIMD3(0, 1, 0), area: step * step))
            out.append(Target(position: SIMD3(x, ceilingY, z), normal: SIMD3(0, -1, 0), area: step * step))
          }
          z += step
        }
        x += step
      }
    }
    for obj in room.objects {
      let t = obj.transform, d = obj.dimensions
      let x = simd_make_float3(t.columns.0), y = simd_make_float3(t.columns.1), z = simd_make_float3(t.columns.2)
      let c = simd_make_float3(t.columns.3)
      // top + four sides
      let halfX: SIMD3<Float> = x * d.x / 2
      let halfY: SIMD3<Float> = y * d.y / 2
      let halfZ: SIMD3<Float> = z * d.z / 2
      let faces: [(SIMD3<Float>, SIMD3<Float>, Float, Float, SIMD3<Float>, SIMD3<Float>)] = [
        (halfY, y, d.x, d.z, x, z),
        (halfZ, z, d.x, d.y, x, y), (-halfZ, -z, d.x, d.y, x, y),
        (halfX, x, d.z, d.y, z, y), (-halfX, -x, d.z, d.y, z, y),
      ]
      for (off, n, w, h, ax, ay) in faces {
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4(ax, 0); m.columns.1 = SIMD4(ay, 0); m.columns.2 = SIMD4(n, 0); m.columns.3 = SIMD4(c + off, 1)
        surface(m, w, h, n)
      }
    }
    return out
  }
}

// MARK: - copying ARKit's mesh buffers

extension ARMeshAnchor {
  struct Snapshot {
    var id: UUID
    var transform: simd_float4x4
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var faces: [UInt32]
    var classes: [UInt8]
  }

  /// Copy the geometry out of ARKit's Metal buffers (they're only valid while the anchor lives)
  func snapshot() -> Snapshot {
    let g = geometry
    func vec3(_ src: ARGeometrySource) -> [SIMD3<Float>] {
      let base = src.buffer.contents().advanced(by: src.offset)
      return (0..<src.count).map { i in
        let p = base.advanced(by: i * src.stride).assumingMemoryBound(to: Float.self)
        return SIMD3(p[0], p[1], p[2])
      }
    }
    let el = g.faces
    let n = el.count * el.indexCountPerPrimitive
    let fbase = el.buffer.contents()
    let faces: [UInt32] = (0..<n).map { i in
      el.bytesPerIndex == 4
        ? fbase.advanced(by: i * 4).assumingMemoryBound(to: UInt32.self).pointee
        : UInt32(fbase.advanced(by: i * 2).assumingMemoryBound(to: UInt16.self).pointee)
    }
    var classes: [UInt8] = []
    if let c = g.classification {
      let base = c.buffer.contents().advanced(by: c.offset)
      classes = (0..<c.count).map { base.advanced(by: $0 * c.stride).assumingMemoryBound(to: UInt8.self).pointee }
    }
    return Snapshot(id: identifier, transform: transform, positions: vec3(g.vertices), normals: vec3(g.normals), faces: faces, classes: classes)
  }
}


/// One scheduled consumer, newest value per key, FIFO fairness across keys. Producers
/// never enqueue closures retaining obsolete geometry while the consumer is busy.
final class CoverageMailbox<Key: Hashable, Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Key: Value] = [:]
  private var order: [Key] = []
  private var scheduled = false
  private var replacements = 0

  var counts: (pending: Int, replaced: Int) { lock.withLock { (values.count, replacements) } }

  /// True only when the caller must schedule a consumer.
  func offer(_ key: Key, _ value: Value) -> Bool {
    lock.withLock {
      if values[key] == nil { order.append(key) } else { replacements += 1 }
      values[key] = value
      guard !scheduled else { return false }
      scheduled = true
      return true
    }
  }

  func take(limit: Int = .max) -> [(Key, Value)] {
    lock.withLock {
      let keys = Array(order.prefix(max(0, limit)))
      order.removeFirst(keys.count)
      return keys.compactMap { key in values.removeValue(forKey: key).map { (key, $0) } }
    }
  }

  /// Called after processing. Producers arriving during work join the same consumer.
  /// True asks the consumer to schedule its next bounded slice.
  func finish() -> Bool {
    lock.withLock {
      if values.isEmpty { scheduled = false; return false }
      return true
    }
  }
}
