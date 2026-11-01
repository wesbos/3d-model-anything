import ARKit
import ImageIO
import RoomPlan
import SceneKit

/// The scanning view: camera feed with ARKit's LiDAR mesh drawn over it, each
/// surface tinted by how well the photos cover it, plus RoomPlan's live walls,
/// doors and windows as outlines. Renders whatever configuration the session runs.
@MainActor
final class ScanView: NSObject, ARSCNViewDelegate {
  let view: ARSCNView
  let engine: CoverageEngine
  var onSessionFailure: (([Diagnostics.ErrorDetail]) -> Void)?
  var onSessionEvent: ((String) -> Void)?
  private var nodes: [UUID: SCNNode] = [:]
  /// meshes that arrived before their node was registered
  private var waiting: [UUID: CoverageEngine.AnchorMesh] = [:]
  private let outline = SCNNode()
  private var lastOutline: CFTimeInterval = 0

  /// Red facets need photos; green facets have good photo coverage.
  /// Keep the camera visible through the fill and trace the actual LiDAR triangles on top.
  private let materials: [SCNMaterial] = [
    (0xFF3939, 0.28), (0xF94B4B, 0.23), (0xE82B2B, 0.25),
    (0xFF3939, 0.28), (0xF94B4B, 0.23), (0xE82B2B, 0.25),
    (0x39ED75, 0.24), (0x51F589, 0.22), (0x26D966, 0.23),
    (0xFFFFFF, 0.0), (0xFFFFFF, 0.0), (0xFFFFFF, 0.0),
  ].map { hex, alpha in
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                                green: CGFloat((hex >> 8) & 255) / 255,
                                blue: CGFloat(hex & 255) / 255, alpha: 1)
    m.transparency = alpha
    m.blendMode = .alpha
    m.isDoubleSided = false
    m.writesToDepthBuffer = true
    m.readsFromDepthBuffer = true
    return m
  }
  private let triangleLine: SCNMaterial = {
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = UIColor.white
    m.transparency = 0.42
    m.fillMode = .lines
    m.blendMode = .alpha
    m.isDoubleSided = false
    m.readsFromDepthBuffer = true
    m.writesToDepthBuffer = false
    return m
  }()
  private let wallLine: SCNMaterial = {
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = UIColor.white
    m.transparency = 0.9
    m.readsFromDepthBuffer = false // always visible, like RoomPlan's own outlines
    return m
  }()
  private let openingLine: SCNMaterial = {
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = UIColor.cyan
    m.readsFromDepthBuffer = false
    return m
  }()

  /// Whether live mesh anchors go to the coverage engine. Off while relocalizing (the world
  /// isn't the zone's yet, and the engine keeps every anchor it's given) and while paused.
  /// Read on SceneKit's render thread.
  nonisolated let feed = FeedGate()
  /// earlier scans of the zone (Continue sessions), drawn under the live mesh
  private let ghost = SCNNode()
  private let ghostEdges = SCNNode()
  private let ghostMaterial: SCNMaterial = {
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = UIColor(red: 0.2, green: 1, blue: 0.45, alpha: 1)
    m.blendMode = .alpha
    m.isDoubleSided = true
    // nearest ghost surface only (don't stack the rooms behind a wall); the ghost sits 1.5 cm
    // behind the saved surface so the live mesh draws over it without z-fighting
    m.writesToDepthBuffer = true
    m.readsFromDepthBuffer = true
    return m
  }()

  init(session: ARSession, engine: CoverageEngine) {
    view = ARSCNView(frame: .zero)
    self.engine = engine
    super.init()
    view.session = session
    view.delegate = self
    view.automaticallyUpdatesLighting = false
    view.rendersCameraGrain = false
    view.rendersMotionBlur = false
    view.antialiasingMode = .multisampling4X
    view.scene = SCNScene()
    outline.renderingOrder = 10
    view.scene.rootNode.addChildNode(outline)
    ghost.renderingOrder = -5 // before the live coverage mesh
    ghost.isHidden = true
    view.scene.rootNode.addChildNode(ghost)
    ghostEdges.renderingOrder = -4
    ghost.addChildNode(ghostEdges)
    engine.onMeshes = { [weak self] meshes in self?.apply(meshes) }
  }

  // MARK: ghost of earlier scans

  var hasGhost: Bool { ghost.geometry != nil }

  /// Zone frame = this session's world once relocalized, so the ghost sits at the origin
  func setGhost(_ g: ZoneReference.Ghost?) {
    guard let g, g.triangleCount > 0 else {
      ghost.geometry = nil
      ghostEdges.geometry = nil
      return
    }
    let positions = g.positions.withUnsafeBufferPointer { Data(buffer: $0) }
    let normals = g.normals.withUnsafeBufferPointer { Data(buffer: $0) }
    let stride = MemoryLayout<SIMD3<Float>>.stride
    let vs = SCNGeometrySource(data: positions, semantic: .vertex, vectorCount: g.positions.count,
                               usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
    let ns = SCNGeometrySource(data: normals, semantic: .normal, vectorCount: g.normals.count,
                               usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
    let idx = g.indices.withUnsafeBufferPointer { Data(buffer: $0) }
    let el = SCNGeometryElement(data: idx, primitiveType: .triangles, primitiveCount: g.triangleCount, bytesPerIndex: 4)
    let geometry = SCNGeometry(sources: [vs, ns], elements: [el])
    geometry.materials = [ghostMaterial]
    ghost.geometry = geometry
    let edges = SCNGeometry(sources: [vs], elements: [el])
    let material = triangleLine.copy() as! SCNMaterial
    material.diffuse.contents = UIColor.systemGreen
    edges.materials = [material]
    ghostEdges.geometry = edges
  }

  /// 0 hides it
  func setGhostOpacity(_ alpha: CGFloat) {
    ghost.isHidden = alpha <= 0 || ghost.geometry == nil
    ghostMaterial.transparency = alpha
    ghostEdges.opacity = min(1, alpha * 2)
  }

  /// Hand every live mesh anchor to the engine again (after it wasn't fed for a while).
  /// Copying the buffers is heavy, so it happens off main; holding the anchors keeps them valid.
  func refeedEngine(from session: ARSession) {
    let anchors = session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
    let engine = engine
    DispatchQueue.global(qos: .userInitiated).async {
      for a in anchors { engine.update(a) }
    }
  }

  /// RoomPlan's current walls (white) and doors/windows/openings (cyan), as outlines
  func showRoom(_ room: CapturedRoom?) {
    let now = CACurrentMediaTime()
    guard room == nil || now - lastOutline > 0.4 else { return } // RoomPlan updates a lot
    lastOutline = now
    outline.childNodes.forEach { $0.removeFromParentNode() }
    guard let room else { return }
    for w in room.walls { outline.addChildNode(rectangle(w.transform, w.dimensions, wallLine, inset: 0)) }
    for o in room.doors + room.windows + room.openings { outline.addChildNode(rectangle(o.transform, o.dimensions, openingLine, inset: 0.01)) }
  }

  private func rectangle(_ t: simd_float4x4, _ d: SIMD3<Float>, _ material: SCNMaterial, inset: Float) -> SCNNode {
    let hw = d.x / 2 - inset, hh = d.y / 2 - inset
    let pts = [SIMD3<Float>(-hw, -hh, 0.005), SIMD3(hw, -hh, 0.005), SIMD3(hw, hh, 0.005), SIMD3(-hw, hh, 0.005)]
    let src = SCNGeometrySource(vertices: pts.map { SCNVector3($0.x, $0.y, $0.z) })
    let idx: [UInt16] = [0, 1, 1, 2, 2, 3, 3, 0]
    let el = SCNGeometryElement(indices: idx, primitiveType: .line)
    let g = SCNGeometry(sources: [src], elements: [el])
    g.materials = [material]
    let node = SCNNode(geometry: g)
    node.simdTransform = t
    node.renderingOrder = 10
    return node
  }

  // MARK: ARSCNViewDelegate (render thread)

  /// Clip anything within 30 cm of the lens: it only blocks the view, and it's too close
  /// to photograph usefully anyway
  nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
    if let cam = renderer.pointOfView?.camera, cam.zNear != 0.3 { cam.zNear = 0.3 }
  }

  /// Relocalize after an interruption (a phone call, the app in the background) instead of
  /// starting a new world
  nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

  // Observe through ARSCNView, without replacing RoomPlan's ARSession delegate.
  nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
    let chain = Diagnostics.errorChain(error)
    Task { @MainActor in self.onSessionFailure?(chain) }
  }

  nonisolated func sessionWasInterrupted(_ session: ARSession) {
    Task { @MainActor in self.onSessionEvent?("ARKit session interrupted") }
  }

  nonisolated func sessionInterruptionEnded(_ session: ARSession) {
    Task { @MainActor in self.onSessionEvent?("ARKit session interruption ended") }
  }


  nonisolated func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
    guard let mesh = anchor as? ARMeshAnchor else { return nil }
    if feed.isOn { engine.update(mesh) }
    let node = SCNNode()
    let id = mesh.identifier
    Task { @MainActor in
      self.nodes[id] = node
      if let m = self.waiting.removeValue(forKey: id) { self.apply([m]) }
    }
    return node
  }

  nonisolated func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
    guard let mesh = anchor as? ARMeshAnchor, feed.isOn else { return }
    engine.update(mesh)
  }

  nonisolated func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
    guard anchor is ARMeshAnchor else { return }
    let id = anchor.identifier
    engine.remove(id)
    Task { @MainActor in
      self.nodes[id] = nil
      self.waiting[id] = nil
    }
  }

  // MARK: geometry

  private func apply(_ meshes: [CoverageEngine.AnchorMesh]) {
    for m in meshes {
      guard m.vertexCount > 0, m.bandCounts.reduce(0, +) > 0 else { continue }
      guard let node = nodes[m.id] else {
        waiting[m.id] = m
        continue
      }
      // SIMD3<Float> is padded to 16 bytes in Swift arrays
      let stride = MemoryLayout<SIMD3<Float>>.stride
      let vertices = SCNGeometrySource(
        data: m.positions, semantic: .vertex, vectorCount: m.vertexCount,
        usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
      let normals = SCNGeometrySource(
        data: m.normals, semantic: .normal, vectorCount: m.vertexCount,
        usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
      var elements: [SCNGeometryElement] = []
      var mats: [SCNMaterial] = []
      var lineIndices = Data()
      var triangleCount = 0
      for (band, data) in m.bands.enumerated() where m.bandCounts[band] > 0 && materials[band].transparency > 0 {
        elements.append(SCNGeometryElement(data: data, primitiveType: .triangles, primitiveCount: m.bandCounts[band], bytesPerIndex: 4))
        mats.append(materials[band])
        lineIndices.append(data)
        triangleCount += m.bandCounts[band]
      }
      guard !elements.isEmpty else {
        node.geometry = nil
        node.childNode(withName: "scan-triangles", recursively: false)?.removeFromParentNode()
        continue
      }
      let geometry = SCNGeometry(sources: [vertices, normals], elements: elements)
      geometry.materials = mats
      let isNew = node.geometry == nil
      node.geometry = geometry
      let edges = node.childNode(withName: "scan-triangles", recursively: false) ?? SCNNode()
      edges.name = "scan-triangles"
      let lines = SCNGeometry(sources: [vertices], elements: [
        SCNGeometryElement(data: lineIndices, primitiveType: .triangles,
                           primitiveCount: triangleCount, bytesPerIndex: 4)
      ])
      lines.materials = [triangleLine]
      edges.geometry = lines
      edges.renderingOrder = 1
      if edges.parent == nil { node.addChildNode(edges) }
      if isNew && !UIAccessibility.isReduceMotionEnabled {
        node.opacity = 0.15
        let reveal = SCNAction.fadeIn(duration: 0.65)
        reveal.timingMode = .easeOut
        node.runAction(reveal, forKey: "scan-reveal")
      }
    }
  }
}

/// A thread-safe on/off switch
final class FeedGate: @unchecked Sendable {
  private let lock = NSLock()
  private var on = true
  var isOn: Bool {
    get { lock.withLock { on } }
    set { lock.withLock { on = newValue } }
  }
}

/// Records LiDAR depth frames (with pose + intrinsics) up to 5× a second while moving:
/// zlib-compressed Float16 depth + UInt8 confidence + a 640×480 color JPEG of the same
/// frame. A full RGB-D sequence, so the Mac can build a fully colored mesh.
final class DepthRecorder: @unchecked Sendable {
  struct Record: Codable {
    /// Float16 meters, row-major, raw DEFLATE (zlib.decompress(data, -15) in Python)
    var file: String
    var confidence: String
    /// 640×480 JPEG of the camera image at this frame (sensor orientation, no EXIF rotation)
    var rgb: String?
    /// intrinsics for the rgb image (column-major 3×3)
    var rgbIntrinsics: [Float]?
    var camera: CameraState?
    var room: Int
    var timestamp: TimeInterval
    var width: Int
    var height: Int
    /// camera-to-world, column-major (same convention as photos)
    var transform: [Float]
    /// column-major 3x3, scaled to the depth map's resolution
    var intrinsics: [Float]
  }

  private let bundle: ScanBundle
  private let queue = DispatchQueue(label: "depth-writer", qos: .utility)
  private(set) var records: [Record] = []
  private var last: (time: TimeInterval, pose: simd_float4x4)?
  private var next = 0
  private var inFlight = 0
  private let ci = CIContext()
  private let store: DepthFrameStore
  /// Called on the main queue when a frame could not be written; that frame is left out of
  /// frames.json so the index never points at a missing or half-written file.
  var onWriteFailure: ((Error) -> Void)?

  init(bundle: ScanBundle) {
    self.bundle = bundle
    store = DepthFrameStore(bundle: bundle)
  }

  /// Call every frame; keeps one when the camera has moved or turned enough (≤ 5/s)
  func consider(_ frame: ARFrame, room: Int, camera: CameraState?, interval: TimeInterval = 0.2) {
    guard let depth = frame.sceneDepth, inFlight < 3 else { return }
    guard case .normal = frame.camera.trackingState else { return }
    let pose = frame.camera.transform
    if let last {
      let moved = simd_distance(pose.columns.3, last.pose.columns.3)
      let turned = acos(min(1, max(-1, simd_dot(simd_make_float3(pose.columns.2), simd_make_float3(last.pose.columns.2)))))
      guard frame.timestamp - last.time > interval, moved > 0.04 || turned > 0.06 else { return }
    }
    last = (frame.timestamp, pose)
    let w = CVPixelBufferGetWidth(depth.depthMap), h = CVPixelBufferGetHeight(depth.depthMap)
    let scale = Float(w) / Float(frame.camera.imageResolution.width)
    var k = frame.camera.intrinsics
    k.columns.0.x *= scale; k.columns.1.y *= scale; k.columns.2.x *= scale; k.columns.2.y *= scale
    let name = String(format: "%05d", next)
    next += 1
    // color: downscale on the GPU now (so we don't hold ARKit's buffer), encode later
    let rgbScale = 640 / Float(frame.camera.imageResolution.width)
    var kc = frame.camera.intrinsics
    kc.columns.0.x *= rgbScale; kc.columns.1.y *= rgbScale; kc.columns.2.x *= rgbScale; kc.columns.2.y *= rgbScale
    let small = CIImage(cvPixelBuffer: frame.capturedImage).transformed(by: CGAffineTransform(scaleX: CGFloat(rgbScale), y: CGFloat(rgbScale)))
    let cg = ci.createCGImage(small, from: CGRect(x: 0, y: 0, width: 640, height: CGFloat((Float(frame.camera.imageResolution.height) * rgbScale).rounded())))
    let record = Record(
      file: "depth/\(name).f16z", confidence: "depth/\(name).conf", rgb: cg == nil ? nil : "depth/\(name).jpg",
      rgbIntrinsics: kc.columnMajor, camera: camera, room: room, timestamp: frame.timestamp,
      width: w, height: h, transform: pose.columnMajor, intrinsics: k.columnMajor)
    let depthData = Self.float16(depth.depthMap)
    let confData = depth.confidenceMap.map(Self.bytes)
    inFlight += 1
    queue.async {
      do {
        try self.store.write(depth: depthData, confidence: confData, depthPath: record.file, confidencePath: record.confidence)
      } catch {
        DispatchQueue.main.async {
          self.inFlight -= 1
          self.onWriteFailure?(error)
        }
        return
      }
      var stored = record
      if let cg, let rgb = record.rgb, !self.store.writeColor(cg, to: rgb) {
        stored.rgb = nil // depth stays usable; never list an image that is not there
        stored.rgbIntrinsics = nil
      }
      DispatchQueue.main.async {
        self.records.append(stored)
        self.inFlight -= 1
      }
    }
  }

  func save() throws {
    try bundle.writeJSON(records, to: "depth/frames.json")
  }

  func discard(room: Int) {
    for r in records where r.room == room {
      try? FileManager.default.removeItem(at: bundle.file(r.file))
      try? FileManager.default.removeItem(at: bundle.file(r.confidence))
      if let rgb = r.rgb { try? FileManager.default.removeItem(at: bundle.file(rgb)) }
    }
    records.removeAll { $0.room == room }
  }

  static func float16(_ buffer: CVPixelBuffer) -> Data {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    let row = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!
    var out = [Float16](repeating: 0, count: w * h)
    for y in 0..<h {
      let src = base.advanced(by: y * row).assumingMemoryBound(to: Float32.self)
      for x in 0..<w { out[y * w + x] = Float16(src[x]) }
    }
    return out.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  static func bytes(_ buffer: CVPixelBuffer) -> Data {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    let row = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!
    var out = Data(capacity: w * h)
    for y in 0..<h { out.append(base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self), count: w) }
    return out
  }

  /// 64×48 grid of each block's median depth (robust to LiDAR speckle; low-confidence
  /// pixels ignored), for the coverage engine's occlusion test
  static func grid(for frame: ARFrame, cells: (Int, Int) = (64, 48)) -> CoverageEngine.DepthGrid? {
    guard let sd = frame.sceneDepth else { return nil }
    let depth = sd.depthMap
    CVPixelBufferLockBaseAddress(depth, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
    let conf = sd.confidenceMap
    if let conf { CVPixelBufferLockBaseAddress(conf, .readOnly) }
    defer { if let conf { CVPixelBufferUnlockBaseAddress(conf, .readOnly) } }
    let w = CVPixelBufferGetWidth(depth), h = CVPixelBufferGetHeight(depth)
    let row = CVPixelBufferGetBytesPerRow(depth)
    let base = CVPixelBufferGetBaseAddress(depth)!
    let confBase = conf.flatMap { CVPixelBufferGetBaseAddress($0) }
    let confRow = conf.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
    let (gw, gh) = cells
    var buckets = [[Float]](repeating: [], count: gw * gh)
    for y in 0..<h {
      let src = base.advanced(by: y * row).assumingMemoryBound(to: Float32.self)
      let c = confBase?.advanced(by: y * confRow).assumingMemoryBound(to: UInt8.self)
      let gy = y * gh / h
      for x in 0..<w {
        let v = src[x]
        guard v > 0, (c?[x] ?? 2) >= 1 else { continue }
        buckets[gy * gw + x * gw / w].append(v)
      }
    }
    let values = buckets.map { b -> Float in
      guard !b.isEmpty else { return 0 } // unknown: the engine skips the test there
      let s = b.sorted()
      return s[s.count / 2]
    }
    let scale = Float(gw) / Float(frame.camera.imageResolution.width)
    let k = frame.camera.intrinsics
    return CoverageEngine.DepthGrid(
      width: gw, height: gh, values: values, worldToCamera: frame.camera.transform.inverse,
      fx: k.columns.0.x * scale, fy: k.columns.1.y * scale, cx: k.columns.2.x * scale, cy: k.columns.2.y * scale)
  }
}
