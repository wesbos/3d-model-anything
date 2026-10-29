import Metal
import SceneKit
import simd
import UIKit

/// How the mesh is drawn
enum RenderStyle: String, CaseIterable, Identifiable {
  case photo, coverage, sessions, clay, wireframe, roomPlan
  var id: String { rawValue }

  var title: String {
    switch self {
    case .photo: "Photo"
    case .coverage: "Coverage"
    case .sessions: "Sessions"
    case .clay: "Clay"
    case .wireframe: "Mesh"
    case .roomPlan: "RoomPlan"
    }
  }

  var icon: String {
    switch self {
    case .photo: "photo"
    case .coverage: "checkmark.seal"
    case .sessions: "square.stack.3d.up"
    case .clay: "cube"
    case .wireframe: "cube.transparent"
    case .roomPlan: "square.split.bottomrightquarter"
    }
  }
}

/// One room mesh, loaded and ready for SceneKit (built off the main thread)
final class MeshAsset: @unchecked Sendable {
  let room: PreviewRoom
  let mesh: PLYMesh
  let inside: [UInt32]
  /// surroundings shown with this room (empty for all but the newest room of a session)
  var outside: [UInt32]
  let insideMin: SIMD3<Float>
  let insideMax: SIMD3<Float>
  /// a few thousand points of the room, for framing the camera
  let samples: [SIMD3<Float>]
  let floorY: Float
  let ceilingY: Float
  /// dominant wall direction (radians, mod 90°) for squaring the plan view
  let wallYaw: Float
  let vertexSource: SCNGeometrySource
  let normalSource: SCNGeometrySource
  let coverageSource: SCNGeometrySource
  var photoTextures: PhotoTextures?
  var photoColors: [UInt8]?
  var photoSource: SCNGeometrySource?

  init(room: PreviewRoom, mesh: PLYMesh) {
    self.room = room
    self.mesh = mesh
    let split = mesh.splitByRoom()
    inside = split.inside.isEmpty ? mesh.indices : split.inside
    outside = split.inside.isEmpty ? [] : split.outside
    // robust extent: 1st–99th percentile of the room's vertices (stray fragments don't blow up the framing)
    var xs: [Float] = [], ys: [Float] = [], zs: [Float] = []
    let step = max(1, inside.count / 60_000)
    var f = 0
    while f < inside.count {
      let p = mesh.position(Int(inside[f]))
      xs.append(p.x); ys.append(p.y); zs.append(p.z)
      f += step
    }
    let every = max(1, xs.count / 3000)
    samples = stride(from: 0, to: xs.count, by: every).map { SIMD3(xs[$0], ys[$0], zs[$0]) }
    xs.sort(); ys.sort(); zs.sort()
    func pct(_ a: [Float], _ q: Double) -> Float { a.isEmpty ? 0 : a[min(a.count - 1, Int(Double(a.count) * q))] }
    var lo = SIMD3(pct(xs, 0.01), pct(ys, 0.005), pct(zs, 0.01)) - 0.15
    var hi = SIMD3(pct(xs, 0.99), pct(ys, 0.995), pct(zs, 0.99)) + 0.15
    if xs.isEmpty { lo = mesh.boundsMin; hi = mesh.boundsMax }
    insideMin = lo; insideMax = hi
    (floorY, ceilingY) = mesh.levels()
    wallYaw = Self.wallDirection(mesh)
    vertexSource = mesh.positions.withUnsafeBytes {
      SCNGeometrySource(data: Data($0), semantic: .vertex, vectorCount: mesh.vertexCount, usesFloatComponents: true,
                        componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
    }
    normalSource = mesh.normals.withUnsafeBytes {
      SCNGeometrySource(data: Data($0), semantic: .normal, vectorCount: mesh.vertexCount, usesFloatComponents: true,
                        componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
    }
    coverageSource = Self.colorSource(mesh.coverageColors, count: mesh.vertexCount)
  }

  private static let device = MTLCreateSystemDefaultDevice()

  /// sRGB bytes → linear half4 vertex colors in a Metal buffer. (SceneKit reads a Data-backed uchar color
  /// source unnormalized, i.e. anything non-zero saturates; a buffer with an explicit vertex format
  /// doesn't, and linear values keep the photo colors exact after SceneKit's sRGB output.)
  static func colorSource(_ rgba: [UInt8], count: Int) -> SCNGeometrySource {
    var lut = [Float16](repeating: 0, count: 256)
    for i in 0..<256 {
      let c = Float(i) / 255
      lut[i] = Float16(c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4))
    }
    let bytes = count * 8
    if let device, let buffer = device.makeBuffer(length: max(8, bytes), options: .storageModeShared) {
      let out = buffer.contents().bindMemory(to: Float16.self, capacity: count * 4)
      rgba.withUnsafeBufferPointer { src in
        lut.withUnsafeBufferPointer { l in
          Self.fillHalf(src.baseAddress!, l.baseAddress!, out, count)
        }
      }
      return SCNGeometrySource(buffer: buffer, vertexFormat: .half4, semantic: .color, vertexCount: count, dataOffset: 0, dataStride: 8)
    }
    // no Metal device (shouldn't happen): float colors in Data
    var f = [Float](repeating: 1, count: count * 4)
    for i in 0..<count * 4 where i % 4 != 3 { f[i] = Float(lut[Int(rgba[i])]) }
    return f.withUnsafeBytes {
      SCNGeometrySource(data: Data($0), semantic: .color, vectorCount: count, usesFloatComponents: true,
                        componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
    }
  }

  @_optimize(speed)
  private static func fillHalf(_ src: UnsafePointer<UInt8>, _ l: UnsafePointer<Float16>, _ out: UnsafeMutablePointer<Float16>, _ count: Int) {
    let blocks = (count + 65535) / 65536
    DispatchQueue.concurrentPerform(iterations: blocks) { b in
      var i = b * 65536
      let end = Swift.min(count, i + 65536)
      while i < end {
        out[4 * i] = l[Int(src[4 * i])]
        out[4 * i + 1] = l[Int(src[4 * i + 1])]
        out[4 * i + 2] = l[Int(src[4 * i + 2])]
        out[4 * i + 3] = 1
        i += 1
      }
    }
  }

  func setPhotoColors(_ rgba: [UInt8]) {
    photoColors = rgba
    photoSource = Self.colorSource(rgba, count: mesh.vertexCount)
  }

  private static func wallDirection(_ mesh: PLYMesh) -> Float {
    var bins = [Float](repeating: 0, count: 90)
    let step = max(1, mesh.vertexCount / 200_000)
    var i = 0
    while i < mesh.vertexCount {
      let n = mesh.normal(i)
      if abs(n.y) < 0.2, n.x != 0 || n.z != 0 {
        var a = atan2(n.z, n.x) * 180 / .pi
        a = a.truncatingRemainder(dividingBy: 90)
        if a < 0 { a += 90 }
        bins[min(89, Int(a))] += 1
      }
      i += step
    }
    // smooth over ±2° (wrapping) and take the peak
    var best = 0, bestV: Float = -1
    for b in 0..<90 {
      var v: Float = 0
      for k in -2...2 { v += bins[(b + k + 90) % 90] }
      if v > bestV { bestV = v; best = b }
    }
    return (Float(best) + 0.5) * .pi / 180
  }
}

/// The SceneKit side of the preview: scene graph, materials, camera rig + gestures, photo markers,
/// measuring. Owned by `PreviewModel`; its `view` is embedded by `PreviewSceneView`.
@MainActor
final class PreviewScene: NSObject, UIGestureRecognizerDelegate {
  let view: SCNView
  let scene = SCNScene()
  private let meshRoot = SCNNode()
  private let roomPlanRoot = SCNNode()
  private let markersRoot = SCNNode()
  private let measureRoot = SCNNode()
  private let gridNode = SCNNode()
  private let northRoot = SCNNode()
  private var northReadings: [String: PreviewNorth] = [:]
  var showNorth = false { didSet { refreshNorth() } }
  let cameraNode = SCNNode()
  private let camera = SCNCamera()
  private let headlight = SCNNode()

  nonisolated static let meshCategory = 1 << 1

  // MARK: state

  private final class Part {
    let asset: MeshAsset
    let node: SCNNode
    let outsideNode: SCNNode?
    var geometries: [String: SCNGeometry] = [:]
    let insideElement: SCNGeometryElement
    let outsideElement: SCNGeometryElement?
    init(asset: MeshAsset) {
      self.asset = asset
      insideElement = asset.inside.withUnsafeBytes {
        SCNGeometryElement(data: Data($0), primitiveType: .triangles, primitiveCount: asset.inside.count / 3, bytesPerIndex: 4)
      }
      if asset.outside.isEmpty {
        outsideElement = nil
      } else {
        outsideElement = asset.outside.withUnsafeBytes {
          SCNGeometryElement(data: Data($0), primitiveType: .triangles, primitiveCount: asset.outside.count / 3, bytesPerIndex: 4)
        }
      }
      node = SCNNode()
      node.categoryBitMask = PreviewScene.meshCategory
      if outsideElement != nil {
        let n = SCNNode()
        n.categoryBitMask = PreviewScene.meshCategory
        outsideNode = n
      } else {
        outsideNode = nil
      }
    }
  }

  private var parts: [Part] = []
  private var roomPlanNodes: [String: SCNNode] = [:]
  private(set) var style: RenderStyle = .photo
  private var visibleRooms: Set<String> = []
  private var showSurroundings = true
  private var clipY: Float = 10_000
  private var sessionHues: [Int: UIColor] = [:]
  private var materials: [String: SCNMaterial] = [:]
  /// floor height of the whole model (grid + plan cut)
  private(set) var floorY: Float = 0
  private(set) var ceilingY: Float = 2.5
  private var wallYaw: Float = 0

  /// camera rig
  struct Orbit {
    var target = SIMD3<Float>(0, 0, 0)
    var yaw: Float = 0
    var pitch: Float = 0.8
    var distance: Float = 6
  }
  private(set) var orbit = Orbit()
  private(set) var isPlan = false
  private var fov: Float = 60 // vertical, degrees
  private static let defaultFov: Float = 60
  /// the photo the camera is sitting at (walkthrough), nil in orbit mode
  private(set) var photoView: PreviewPhoto?
  private var photos: [PreviewPhoto] = []
  private var markerNodes: [Int: SCNNode] = [:]
  private var selectedMarker: Int?

  /// called when the camera leaves a photo pose because the user moved it
  var onLeftPhoto: (() -> Void)?
  /// called at the end of a fly-to-photo
  var onArrivedAtPhoto: ((PreviewPhoto) -> Void)?
  /// tap handler for walkthrough selection / measuring: return true if handled
  var onTap: ((CGPoint) -> Void)?
  /// camera moved (throttled to display refresh): for the scale bar
  var onCameraChanged: (() -> Void)?

  // animation
  private struct Flight {
    var fromPos: SIMD3<Float>, toPos: SIMD3<Float>
    var fromRot: simd_quatf, toRot: simd_quatf
    var fromFov: Float, toFov: Float
    var start: CFTimeInterval, duration: CFTimeInterval
    var arc: Float
    var done: (() -> Void)?
  }
  private var flight: Flight?
  private var orbitVelocity = SIMD2<Float>(0, 0)
  private var panVelocity = SIMD3<Float>(0, 0, 0)
  private var displayLink: CADisplayLink?
  private var lastTick: CFTimeInterval = 0

  let frameCounter = FrameCounter()

  override init() {
    view = SCNView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
    super.init()
    view.scene = scene
    view.backgroundColor = .black
    view.antialiasingMode = .multisampling4X
    view.preferredFramesPerSecond = 120
    view.isJitteringEnabled = false
    view.rendersContinuously = false
    view.autoenablesDefaultLighting = false
    view.delegate = frameCounter
    scene.background.contents = Self.backgroundImage()

    camera.zNear = 0.02
    camera.zFar = 200
    camera.fieldOfView = CGFloat(fov)
    camera.projectionDirection = .vertical
    cameraNode.camera = camera
    scene.rootNode.addChildNode(cameraNode)
    view.pointOfView = cameraNode

    // lights: a soft headlight that follows the camera + a sky fill; unlit styles ignore them
    let head = SCNLight()
    head.type = .directional
    head.intensity = 330
    head.color = UIColor(white: 1, alpha: 1)
    headlight.light = head
    headlight.simdOrientation = simd_quatf(angle: 0.35, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: -0.25, axis: SIMD3(0, 1, 0))
    cameraNode.addChildNode(headlight)
    let sky = SCNNode()
    let skyLight = SCNLight()
    skyLight.type = .directional
    skyLight.intensity = 620
    sky.light = skyLight
    sky.simdOrientation = simd_quatf(angle: 0.6, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: -1.0, axis: SIMD3(1, 0, 0))
    scene.rootNode.addChildNode(sky)
    let ambient = SCNNode()
    let amb = SCNLight()
    amb.type = .ambient
    amb.intensity = 200
    ambient.light = amb
    scene.rootNode.addChildNode(ambient)

    for n in [gridNode, meshRoot, roomPlanRoot, markersRoot, measureRoot, northRoot] { scene.rootNode.addChildNode(n) }
    markersRoot.isHidden = true
    roomPlanRoot.isHidden = true
    buildGrid()
    installGestures()
    applyCamera()
  }

  // MARK: - content

  func setNorth(_ readings: [String: PreviewNorth]) {
    northReadings = readings
    refreshNorth()
  }

  private func refreshNorth() {
    northRoot.childNodes.forEach { $0.removeFromParentNode() }
    guard showNorth else { return }
    for (id, reading) in northReadings where visibleRooms.contains(id) {
      let b = bounds(rooms: [id])
      let origin = SIMD3<Float>((b.min.x + b.max.x) / 2, b.max.y + 0.2, (b.min.z + b.max.z) / 2)
      let length: Float = 0.8
      let shaft = SCNNode(geometry: SCNCylinder(radius: 0.025, height: CGFloat(length)))
      shaft.simdPosition = origin + reading.vector * length / 2
      shaft.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: reading.vector)
      let tip = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.10, height: 0.22))
      tip.simdPosition = origin + reading.vector * (length + 0.11)
      tip.simdOrientation = shaft.simdOrientation
      let text = SCNText(string: "N · \(reading.reference) · ±\(Int(ceil(reading.accuracy)))°", extrusionDepth: 0)
      text.font = .systemFont(ofSize: 12, weight: .bold)
      let label = SCNNode(geometry: text)
      label.simdScale = SIMD3(repeating: 0.012)
      label.simdPosition = origin + reading.vector * (length + 0.3)
      label.constraints = [SCNBillboardConstraint()]
      for node in [shaft, tip, label] {
        node.geometry?.firstMaterial?.diffuse.contents = UIColor.systemOrange
        node.geometry?.firstMaterial?.lightingModel = .constant
        node.geometry?.firstMaterial?.readsFromDepthBuffer = false
        node.geometry?.firstMaterial?.writesToDepthBuffer = false
        node.renderingOrder = 100
        northRoot.addChildNode(node)
      }
    }
  }

  func setSessions(_ sessions: [PreviewSession]) {
    for s in sessions { sessionHues[s.index] = s.hue }
  }

  func add(_ asset: MeshAsset) {
    let part = Part(asset: asset)
    parts.append(part)
    meshRoot.addChildNode(part.node)
    if let o = part.outsideNode { meshRoot.addChildNode(o) }
    visibleRooms.insert(asset.room.id)
    refreshLevels()
    apply(part)
  }

  var hasMeshes: Bool { !parts.isEmpty }
  var totalVertices: Int { parts.reduce(0) { $0 + $1.asset.mesh.vertexCount } }
  var totalTriangles: Int { parts.reduce(0) { $0 + ($1.asset.inside.count + $1.asset.outside.count) / 3 } }

  private func refreshLevels() {
    // the floor under most of the geometry: the lowest room floor, ceiling the highest
    floorY = parts.map(\.asset.floorY).min() ?? 0
    ceilingY = parts.map(\.asset.ceilingY).max() ?? 2.5
    if let biggest = parts.max(by: { $0.asset.inside.count < $1.asset.inside.count }) { wallYaw = biggest.asset.wallYaw }
    gridNode.simdPosition = SIMD3(modelCenter.x, floorY - 0.004, modelCenter.z)
  }

  func photoColorsChanged(for roomID: String) {
    for p in parts where p.asset.room.id == roomID {
      p.geometries = p.geometries.filter { !$0.key.hasPrefix("photo") }
      apply(p)
    }
  }

  func addRoomPlan(_ node: SCNNode, roomID: String) {
    roomPlanNodes[roomID] = node
    node.isHidden = !visibleRooms.contains(roomID) && !parts.isEmpty
    roomPlanRoot.addChildNode(node)
    Self.styleRoomPlan(node, clip: clipModifier)
    node.enumerateHierarchy { n, _ in
      n.categoryBitMask = PreviewScene.meshCategory
      n.geometry?.materials.forEach { $0.setValue(NSNumber(value: self.clipY), forKey: "clipY") }
    }
  }

  var hasRoomPlan: Bool { !roomPlanNodes.isEmpty }

  func setStyle(_ s: RenderStyle) {
    style = s
    // contact shadows make the untextured styles read as shapes
    let ao = s == .clay || s == .coverage || s == .roomPlan
    camera.screenSpaceAmbientOcclusionIntensity = ao ? 1.4 : 0
    camera.screenSpaceAmbientOcclusionRadius = 0.25
    camera.screenSpaceAmbientOcclusionBias = 0.02
    camera.screenSpaceAmbientOcclusionDepthThreshold = 0.3
    camera.screenSpaceAmbientOcclusionNormalThreshold = 0.3
    meshRoot.isHidden = s == .roomPlan
    roomPlanRoot.isHidden = s != .roomPlan
    for p in parts { apply(p) }
  }

  func setVisibleRooms(_ ids: Set<String>, surroundings: Bool) {
    visibleRooms = ids
    showSurroundings = surroundings
    for p in parts { apply(p) }
    for (id, n) in roomPlanNodes { n.isHidden = !ids.contains(id) }
    refreshNorth()
  }

  func setClip(_ y: Float?) {
    clipY = y ?? 10_000
    for m in materials.values { m.setValue(NSNumber(value: clipY), forKey: "clipY") }
    for p in parts {
      for g in [p.asset.photoTextures?.inside, p.asset.photoTextures?.outside] {
        g?.materials.forEach { $0.setValue(NSNumber(value: clipY), forKey: "clipY") }
      }
    }
    for n in roomPlanNodes.values {
      n.enumerateHierarchy { c, _ in c.geometry?.materials.forEach { $0.setValue(NSNumber(value: self.clipY), forKey: "clipY") } }
    }
  }

  private func apply(_ p: Part) {
    let visible = visibleRooms.contains(p.asset.room.id)
    p.node.isHidden = !visible
    p.outsideNode?.isHidden = !(visible && showSurroundings)
    guard visible else { return }
    let hasPhoto = p.asset.photoSource != nil
    let colors: String
    switch style {
    case .photo, .sessions, .wireframe: colors = hasPhoto ? "photo" : "none"
    case .coverage: colors = "coverage"
    case .clay, .roomPlan: colors = "none"
    }
    p.node.geometry = geometry(p, colors: colors, outside: false)
    p.node.geometry?.firstMaterial = material(colors: colors, session: p.asset.room.session, dim: false)
    if let o = p.outsideNode {
      o.geometry = geometry(p, colors: colors, outside: true)
      o.geometry?.firstMaterial = material(colors: colors, session: p.asset.room.session, dim: true)
    }
    for (node, textured) in [(p.node, p.asset.photoTextures?.inside), (p.outsideNode, p.asset.photoTextures?.outside)] {
      guard let node else { continue }
      let old = node.childNode(withName: "photo-textures", recursively: false)
      if style == .photo, let textured {
        let child = old ?? SCNNode()
        child.name = "photo-textures"
        child.categoryBitMask = PreviewScene.meshCategory
        child.isHidden = false
        child.geometry = textured
        for m in textured.materials {
          m.shaderModifiers = [.surface: clipModifier]
          m.setValue(NSNumber(value: clipY), forKey: "clipY")
        }
        if child.parent == nil { node.addChildNode(child) }
      } else { old?.isHidden = true }
    }
    // mesh style: a dark solid just behind the lines so the far side doesn't shine through
    for (node, outside) in [(p.node, false), (p.outsideNode, true)] {
      guard let node else { continue }
      let under = node.childNode(withName: "under", recursively: false)
      if style == .wireframe {
        let n = under ?? {
          let n = SCNNode()
          n.name = "under"
          n.categoryBitMask = PreviewScene.meshCategory
          node.addChildNode(n)
          return n
        }()
        n.isHidden = false
        n.geometry = geometry(p, colors: "under", outside: outside)
        n.geometry?.firstMaterial = underMaterial
      } else {
        under?.isHidden = true
      }
    }
  }

  private lazy var underMaterial: SCNMaterial = {
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = UIColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1)
    m.shaderModifiers = [
      .geometry: "_geometry.position.xyz -= _geometry.normal * 0.004;",
      .surface: clipModifier,
    ]
    m.setValue(NSNumber(value: clipY), forKey: "clipY")
    materials["under"] = m
    return m
  }()

  private func geometry(_ p: Part, colors: String, outside: Bool) -> SCNGeometry? {
    let textured = style == .photo ? p.asset.photoTextures : nil
    let key = colors + (textured == nil ? "" : "-fallback") + (outside ? "-out" : "-in")
    if let g = p.geometries[key] { return g }
    let element: SCNGeometryElement
    if let textured {
      let indices = outside ? textured.outsideFallback : textured.insideFallback
      guard !indices.isEmpty else { return nil }
      element = indices.withUnsafeBytes {
        SCNGeometryElement(data: Data($0), primitiveType: .triangles, primitiveCount: indices.count / 3, bytesPerIndex: 4)
      }
    } else {
      guard let original = outside ? p.outsideElement : p.insideElement else { return nil }
      element = original
    }
    var sources = [p.asset.vertexSource, p.asset.normalSource]
    switch colors {
    case "photo": if let s = p.asset.photoSource { sources.append(s) }
    case "coverage": sources.append(p.asset.coverageSource)
    default: break
    }
    let g = SCNGeometry(sources: sources, elements: [element])
    p.geometries[key] = g
    return g
  }

  // MARK: materials

  /// Drops fragments above the plan cut. World position from the view-space position.
  private let clipModifier = """
  #pragma arguments
  float clipY;
  #pragma body
  float4 clipWorld = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
  if (clipWorld.y > clipY) { discard_fragment(); }
  """

  private func material(colors: String, session: Int, dim: Bool) -> SCNMaterial {
    let key = "\(style.rawValue)-\(colors)-\(style == .sessions ? session : 0)-\(dim)"
    if let m = materials[key] { return m }
    let m = SCNMaterial()
    m.isDoubleSided = false
    m.shaderModifiers = [.surface: clipModifier]
    m.setValue(NSNumber(value: clipY), forKey: "clipY")
    let clay = UIColor(red: 0.80, green: 0.79, blue: 0.76, alpha: 1)
    let dimTint = UIColor(white: 0.55, alpha: 1)
    switch (style, colors) {
    case (.photo, "photo"):
      m.lightingModel = .constant
      m.diffuse.contents = UIColor.white
      if dim { m.multiply.contents = dimTint }
    case (.sessions, _):
      let hue = sessionHues[session] ?? .systemGreen
      if colors == "photo" {
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.white
        m.multiply.contents = hue.mixed(with: .white, amount: dim ? 0.1 : 0.35).scaled(dim ? 0.6 : 1)
      } else {
        m.lightingModel = .lambert
        m.diffuse.contents = hue.mixed(with: .white, amount: 0.3).scaled(dim ? 0.6 : 1)
      }
    case (.coverage, _):
      m.lightingModel = .lambert
      m.diffuse.contents = UIColor.white
      if dim { m.multiply.contents = dimTint }
    case (.wireframe, _):
      m.lightingModel = .constant
      m.fillMode = .lines
      m.isDoubleSided = true
      m.diffuse.contents = colors == "photo" ? UIColor.white : UIColor(red: 0.55, green: 0.85, blue: 1, alpha: 1)
      // see-through lines over the dark underlayer: the triangle structure shows even where it's dense
      m.transparency = 0.6
      m.blendMode = .alpha
      m.writesToDepthBuffer = false
      if dim { m.multiply.contents = dimTint }
    default: // clay, and photo style before colors exist
      m.lightingModel = .lambert
      m.diffuse.contents = dim ? clay.scaled(0.6) : clay
    }
    materials[key] = m
    return m
  }

  private static func styleRoomPlan(_ root: SCNNode, clip: String) {
    root.enumerateHierarchy { node, _ in
      guard let g = node.geometry else { return }
      let name = (node.name ?? node.parent?.name ?? "").lowercased()
      let color: UIColor
      if name.contains("wall") { color = UIColor(red: 0.93, green: 0.92, blue: 0.90, alpha: 1) }
      else if name.contains("floor") { color = UIColor(red: 0.60, green: 0.58, blue: 0.56, alpha: 1) }
      else if name.contains("window") { color = UIColor(red: 0.55, green: 0.78, blue: 0.98, alpha: 1) }
      else if name.contains("door") || name.contains("opening") { color = UIColor(red: 0.78, green: 0.62, blue: 0.45, alpha: 1) }
      else { color = UIColor(red: 0.45, green: 0.72, blue: 0.95, alpha: 1).mixed(with: .white, amount: 0.25) }
      let m = SCNMaterial()
      m.lightingModel = .lambert
      m.diffuse.contents = color
      m.isDoubleSided = true
      m.shaderModifiers = [.surface: clip]
      g.materials = [m]
    }
  }

  // MARK: - grid + background

  private func buildGrid() {
    let plane = SCNPlane(width: 60, height: 60)
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.isDoubleSided = true
    m.writesToDepthBuffer = false
    m.blendMode = .alpha
    m.diffuse.contents = UIColor.clear
    m.shaderModifiers = [.fragment: """
    #pragma transparent
    #pragma arguments
    float3 gridCenter;
    #pragma body
    float4 gw = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
    float2 p = gw.xz;
    float2 w = max(fwidth(p), float2(1e-4));
    float2 g = abs(fract(p - 0.5) - 0.5) / w;
    float line = 1.0 - min(min(g.x, g.y), 1.0);
    float2 p5 = p * 4.0;
    float2 w5 = max(fwidth(p5), float2(1e-4));
    float2 g5 = abs(fract(p5 - 0.5) - 0.5) / w5;
    float fine = (1.0 - min(min(g5.x, g5.y), 1.0)) * saturate(1.0 - max(w5.x, w5.y) * 1.5);
    float d = length(p - gridCenter.xz);
    float fade = 1.0 - smoothstep(4.0, 16.0, d);
    float a = (line * 0.26 + fine * 0.07) * fade;
    _output.color = float4(float3(0.62, 0.68, 0.80) * a, a);
    """]
    plane.materials = [m]
    gridNode.geometry = plane
    gridNode.simdOrientation = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
    gridNode.renderingOrder = -10
  }

  private static func backgroundImage() -> UIImage {
    let size = CGSize(width: 4, height: 512)
    return UIGraphicsImageRenderer(size: size).image { ctx in
      let colors = [UIColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 1).cgColor,
                    UIColor(red: 0.05, green: 0.055, blue: 0.07, alpha: 1).cgColor]
      let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
      ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
    }
  }

  // MARK: - bounds

  private var modelCenter: SIMD3<Float> { let b = bounds(); return (b.min + b.max) / 2 }

  func bounds(rooms: Set<String>? = nil) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
    var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
    for p in parts where rooms?.contains(p.asset.room.id) ?? true {
      lo = simd_min(lo, p.asset.insideMin); hi = simd_max(hi, p.asset.insideMax)
    }
    if lo.x > hi.x {
      for (id, n) in roomPlanNodes where rooms?.contains(id) ?? true {
        let (a, b) = n.boundingBox
        let t = n.simdWorldTransform
        for c in [SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z)), SIMD3<Float>(Float(b.x), Float(b.y), Float(b.z))] {
          let w = simd_make_float3(t * SIMD4(c, 1))
          lo = simd_min(lo, w); hi = simd_max(hi, w)
        }
      }
    }
    if lo.x > hi.x { return (SIMD3(-2, 0, -2), SIMD3(2, 2.5, 2)) }
    return (lo, hi)
  }

  // MARK: - camera

  private var viewSize: CGSize {
    view.bounds.size.width > 0 ? view.bounds.size : CGSize(width: 390, height: 844)
  }

  /// Frames the visible rooms from a 3/4 view (or straight down in plan mode)
  func resetView(animated: Bool) {
    fly(to: framedOrbit(plan: isPlan, yaw: nil), fov: Self.defaultFov, animated: animated)
  }

  /// An orbit that frames the visible rooms: a 3/4 view from a corner, or straight down (walls square
  /// to the screen) in plan mode. `yaw` keeps the user's heading (snapped to the walls in plan mode).
  private func framedOrbit(plan: Bool, yaw: Float?) -> Orbit {
    let b = bounds(rooms: visibleRooms)
    let center = (b.min + b.max) / 2
    let aspect = Float(viewSize.width / viewSize.height)
    let half = Self.defaultFov / 2 * .pi / 180
    let hHalf = atan(tan(half) * aspect)
    var o = Orbit()
    if plan {
      o.target = SIMD3(center.x, floorY, center.z)
      o.yaw = yaw.map(nearestSquareYaw) ?? planYaw(b)
      o.pitch = .pi / 2
      o.distance = fitDistance(b, o, tanH: tan(hHalf) * 0.9, tanV: tan(half) * 0.62)
    } else {
      o.target = center
      o.yaw = yaw ?? wallYaw + .pi / 4 + .pi // looking in from a corner
      o.pitch = 0.72
      o.distance = fitDistance(b, o, tanH: tan(hHalf) * 0.8, tanV: tan(half) * 0.64)
      // perspective makes near parts look bigger: re-center on what the screen actually shows
      let pts = parts.filter { visibleRooms.contains($0.asset.room.id) }.flatMap(\.asset.samples)
      if pts.count > 10 {
        let (_, q) = pose(for: o)
        let right = q.act(SIMD3(1, 0, 0)), up = q.act(SIMD3(0, 1, 0)), fwd = q.act(SIMD3(0, 0, -1))
        var xs: [Float] = [], ys: [Float] = []
        for p in pts {
          let c = p - o.target
          let depth = o.distance + simd_dot(c, fwd)
          guard depth > 0.1 else { continue }
          xs.append(simd_dot(c, right) / depth); ys.append(simd_dot(c, up) / depth)
        }
        xs.sort(); ys.sort()
        if xs.count > 10 {
          let mx = (xs[xs.count / 50] + xs[xs.count - 1 - xs.count / 50]) / 2
          let my = (ys[ys.count / 50] + ys[ys.count - 1 - ys.count / 50]) / 2
          o.target += (right * mx + up * my) * o.distance
        }
      }
    }
    return o
  }

  /// the camera distance at which (98% of) the visible rooms' sample points fit the view (margins as tangents)
  private func fitDistance(_ b: (min: SIMD3<Float>, max: SIMD3<Float>), _ o: Orbit, tanH: Float, tanV: Float) -> Float {
    var probe = o
    probe.distance = 1
    let (_, q) = pose(for: probe)
    let right = q.act(SIMD3(1, 0, 0)), up = q.act(SIMD3(0, 1, 0)), fwd = q.act(SIMD3(0, 0, -1))
    var pts = parts.filter { visibleRooms.contains($0.asset.room.id) }.flatMap(\.asset.samples)
    if pts.isEmpty {
      pts = (0..<8).map { i in SIMD3<Float>(i & 1 == 0 ? b.min.x : b.max.x, i & 2 == 0 ? b.min.y : b.max.y, i & 4 == 0 ? b.min.z : b.max.z) }
    }
    var need = pts.map { p -> Float in
      let c = p - o.target
      let x = simd_dot(c, right), y = simd_dot(c, up), z = simd_dot(c, fwd)
      return max(abs(x) / tanH - z, abs(y) / tanV - z)
    }
    need.sort()
    return max(0.5, need[min(need.count - 1, Int(Float(need.count) * 0.98))])
  }

  /// in plan view: walls square to the screen, long side vertical (portrait)
  private func planYaw(_ b: (min: SIMD3<Float>, max: SIMD3<Float>)) -> Float {
    let yaw = -wallYaw
    // of the two square orientations, the one that puts the longer side vertical (portrait screen)
    let pts = parts.filter { visibleRooms.contains($0.asset.room.id) }.flatMap(\.asset.samples)
    guard !pts.isEmpty else { return (b.max.x - b.min.x) > (b.max.z - b.min.z) ? yaw + .pi / 2 : yaw }
    let right = SIMD2<Float>(cos(yaw), -sin(yaw))
    var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
    for p in pts {
      let q = SIMD2(p.x * right.x + p.z * right.y, -p.x * right.y + p.z * right.x)
      lo = simd_min(lo, q); hi = simd_max(hi, q)
    }
    let e = hi - lo
    return e.x > e.y ? yaw + .pi / 2 : yaw
  }

  func setPlan(_ plan: Bool, animated: Bool) {
    guard plan != isPlan else { return }
    leavePhotoView()
    isPlan = plan
    if plan {
      fly(to: framedOrbit(plan: true, yaw: orbit.yaw), fov: Self.defaultFov, animated: animated) { [weak self] in
        self?.camera.usesOrthographicProjection = true
        self?.applyCamera()
      }
    } else {
      camera.usesOrthographicProjection = false
      fly(to: framedOrbit(plan: false, yaw: orbit.yaw + .pi / 4), fov: Self.defaultFov, animated: animated)
    }
  }

  private func nearestSquareYaw(_ yaw: Float) -> Float {
    let base = -wallYaw
    let k = ((yaw - base) / (.pi / 2)).rounded()
    return base + k * .pi / 2
  }

  private func pose(for o: Orbit) -> (SIMD3<Float>, simd_quatf) {
    let q = simd_quatf(angle: o.yaw, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: -o.pitch, axis: SIMD3(1, 0, 0))
    let forward = q.act(SIMD3(0, 0, -1))
    return (o.target - forward * o.distance, q)
  }

  private func applyCamera() {
    guard flight == nil else { return }
    if let photo = photoView {
      let (p, q, f) = photoPose(photo)
      cameraNode.simdPosition = p
      cameraNode.simdOrientation = q
      camera.fieldOfView = CGFloat(f)
    } else {
      let (p, q) = pose(for: orbit)
      cameraNode.simdPosition = p
      cameraNode.simdOrientation = q
      camera.fieldOfView = CGFloat(fov)
      camera.orthographicScale = Double(orbit.distance * tan(fov / 2 * .pi / 180))
    }
    updateZRange()
    onCameraChanged?()
  }

  private func updateZRange() {
    let d = photoView != nil ? 1 : orbit.distance
    camera.zNear = Double(max(0.01, min(0.25, d * 0.01)))
    camera.zFar = Double(max(60, d * 8))
  }

  /// meters per screen point at the target depth (plan mode: exact)
  var metersPerPoint: Float {
    let h = Float(viewSize.height)
    return 2 * orbit.distance * tan(fov / 2 * .pi / 180) / h
  }

  private func fly(to o: Orbit, fov newFov: Float, animated: Bool, duration: CFTimeInterval = 0.7, done: (() -> Void)? = nil) {
    orbitVelocity = .zero
    panVelocity = .zero
    let (p, q) = pose(for: o)
    if !animated {
      flight = nil
      orbit = o
      fov = newFov
      applyCamera()
      done?()
      return
    }
    startFlight(to: p, rotation: q, fov: newFov, duration: duration) { [weak self] in
      guard let self else { return }
      self.orbit = o
      self.fov = newFov
      self.applyCamera()
      done?()
    }
  }

  private func startFlight(to p: SIMD3<Float>, rotation q: simd_quatf, fov f: Float, duration: CFTimeInterval, done: (() -> Void)?) {
    let from = cameraNode.simdPosition
    var fromRot = cameraNode.simdOrientation
    if simd_dot(fromRot.vector, q.vector) < 0 { fromRot = simd_quatf(vector: -fromRot.vector) }
    let travel = simd_distance(from, p)
    flight = Flight(fromPos: from, toPos: p, fromRot: fromRot, toRot: q, fromFov: Float(camera.fieldOfView), toFov: f,
                    start: CACurrentMediaTime(), duration: duration + Double(min(0.5, travel * 0.05)),
                    arc: min(1.5, travel * 0.12), done: done)
    startTicking()
  }

  // MARK: photo poses

  /// Camera pose + vertical FOV that reproduce `photo` on this screen: the sensor image is landscape
  /// and shown upright (EXIF 6 = rotate 90° clockwise), so the SceneKit camera is the photo camera
  /// rolled +90° about its view axis, and the screen's vertical span is fit to the photo's width.
  func photoPose(_ photo: PreviewPhoto) -> (SIMD3<Float>, simd_quatf, Float) {
    let m = photo.cameraToHouse
    let r = simd_float3x3(simd_normalize(simd_make_float3(m.columns.0)), simd_normalize(simd_make_float3(m.columns.1)),
                          simd_normalize(simd_make_float3(m.columns.2)))
    let q = simd_quatf(r) * simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1))
    let rect = photoRect(photo, in: viewSize)
    let scale = Float(rect.width) / Float(photo.height)
    let halfV = Float(viewSize.height) / scale / 2
    let vfov = 2 * atan(halfV / photo.fx) * 180 / .pi
    return (photo.position, q, vfov)
  }

  /// Where the upright photo sits on screen so its pixels line up with the 3D view (principal point at
  /// the screen center, aspect fit)
  func photoRect(_ photo: PreviewPhoto, in size: CGSize) -> CGRect {
    let dw = CGFloat(photo.height), dh = CGFloat(photo.width) // upright size
    let scale = min(size.width / dw, size.height / dh)
    // principal point in upright pixel coordinates
    let ppx = CGFloat(Float(photo.height) - photo.cy), ppy = CGFloat(photo.cx)
    return CGRect(x: size.width / 2 - ppx * scale, y: size.height / 2 - ppy * scale, width: dw * scale, height: dh * scale)
  }

  func fly(to photo: PreviewPhoto, duration: CFTimeInterval = 0.9) {
    orbitVelocity = .zero
    panVelocity = .zero
    if camera.usesOrthographicProjection {
      camera.usesOrthographicProjection = false
      isPlan = false
    }
    let (p, q, f) = photoPose(photo)
    select(marker: photo.id)
    startFlight(to: p, rotation: q, fov: f, duration: duration) { [weak self] in
      guard let self else { return }
      self.photoView = photo
      self.markerNodes[photo.id]?.isHidden = true
      self.applyCamera()
      self.onArrivedAtPhoto?(photo)
    }
  }

  /// Turn the photo pose into an orbit around what the camera looks at (keeps the view, drops the roll)
  func leavePhotoView() {
    guard let photo = photoView else { return }
    photoView = nil
    markerNodes[photo.id]?.isHidden = false
    let forward = photo.forward
    let focus = hitDistance(at: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)) ?? 1.5
    var o = Orbit()
    o.distance = max(0.3, min(focus, 6))
    o.target = photo.position + forward * o.distance
    o.pitch = asin(max(-1, min(1, -forward.y)))
    o.yaw = atan2(-forward.x, -forward.z)
    fov = Float(camera.fieldOfView)
    orbit = o
    applyCamera()
    onLeftPhoto?()
  }

  private func hitDistance(at point: CGPoint) -> Float? {
    guard let p = hitMesh(at: point) else { return nil }
    return simd_distance(p, cameraNode.simdPosition)
  }

  /// First visible mesh / RoomPlan surface under a screen point (respects the plan cut)
  func hitMesh(at point: CGPoint) -> SIMD3<Float>? {
    let hits = view.hitTest(point, options: [
      .categoryBitMask: PreviewScene.meshCategory,
      .searchMode: SCNHitTestSearchMode.all.rawValue,
      .ignoreHiddenNodes: true,
      .backFaceCulling: false,
    ])
    let cam = cameraNode.simdPosition
    let sorted = hits.map { SIMD3<Float>(Float($0.worldCoordinates.x), Float($0.worldCoordinates.y), Float($0.worldCoordinates.z)) }
      .filter { $0.y <= clipY + 0.001 }
      .sorted { simd_distance($0, cam) < simd_distance($1, cam) }
    return sorted.first
  }

  // MARK: - ticking (inertia + flights)

  private func startTicking() {
    guard displayLink == nil else { return }
    let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
    link.add(to: .main, forMode: .common)
    displayLink = link
    lastTick = CACurrentMediaTime()
  }

  private func stopTicking() {
    displayLink?.invalidate()
    displayLink = nil
  }

  fileprivate func tick() {
    let now = CACurrentMediaTime()
    let dt = Float(min(0.05, now - lastTick))
    lastTick = now
    var busy = false
    if let f = flight {
      let t = min(1, (now - f.start) / f.duration)
      let e = Float(t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2)
      var p = simd_mix(f.fromPos, f.toPos, SIMD3(repeating: e))
      p.y += f.arc * 4 * e * (1 - e) // a little hop on long flights
      cameraNode.simdPosition = p
      cameraNode.simdOrientation = simd_slerp(f.fromRot, f.toRot, e)
      camera.fieldOfView = CGFloat(f.fromFov + (f.toFov - f.fromFov) * e)
      if camera.usesOrthographicProjection {
        camera.orthographicScale = Double(max(0.2, p.y - floorY) * tan(Float(camera.fieldOfView) / 2 * .pi / 180))
      }
      camera.zNear = 0.02
      onCameraChanged?()
      if t >= 1 {
        flight = nil
        f.done?()
      }
      busy = flight != nil
    }
    if flight == nil, photoView == nil {
      if simd_length(orbitVelocity) > 0.01 {
        orbit.yaw += orbitVelocity.x * dt
        orbit.pitch = clampPitch(orbit.pitch + orbitVelocity.y * dt)
        orbitVelocity *= exp(-5 * dt)
        busy = true
      } else {
        orbitVelocity = .zero
      }
      if simd_length(panVelocity) > 0.005 {
        orbit.target += panVelocity * dt
        panVelocity *= exp(-6 * dt)
        busy = true
      } else {
        panVelocity = .zero
      }
      if busy { applyCamera() }
    }
    if !busy && flight == nil { stopTicking() }
  }

  private func clampPitch(_ p: Float) -> Float { isPlan ? .pi / 2 : max(-0.35, min(.pi / 2 - 0.01, p)) }

  // MARK: - gestures

  private var pinchStart: Float = 0
  private var lastPan = CGPoint.zero
  private var lastPan2 = CGPoint.zero
  private var lastRotation: CGFloat = 0

  private func installGestures() {
    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    pan.maximumNumberOfTouches = 1
    pan.delegate = self
    let pan2 = UIPanGestureRecognizer(target: self, action: #selector(handlePan2(_:)))
    pan2.minimumNumberOfTouches = 2
    pan2.delegate = self
    let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
    pinch.delegate = self
    let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
    rotate.delegate = self
    let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
    double.numberOfTapsRequired = 2
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    tap.require(toFail: double)
    for g in [pan, pan2, pinch, rotate, double, tap] as [UIGestureRecognizer] { view.addGestureRecognizer(g) }
  }

  func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
    !(g is UITapGestureRecognizer) && !(other is UITapGestureRecognizer)
  }

  private func beginInteraction() {
    if flight != nil {
      flight = nil
      // settle the rig where the camera is now
      if photoView == nil { syncOrbitToCamera() }
    }
    if photoView != nil { leavePhotoView() }
    orbitVelocity = .zero
    panVelocity = .zero
  }

  /// after an interrupted flight: orbit around the point in front of the camera
  private func syncOrbitToCamera() {
    let q = cameraNode.simdOrientation
    let forward = q.act(SIMD3(0, 0, -1))
    let d = orbit.distance
    orbit.target = cameraNode.simdPosition + forward * d
    orbit.pitch = clampPitch(asin(max(-1, min(1, -forward.y))))
    orbit.yaw = atan2(-forward.x, -forward.z)
    fov = Float(camera.fieldOfView)
    applyCamera()
  }

  @objc private func handlePan(_ g: UIPanGestureRecognizer) {
    let t = g.translation(in: view)
    switch g.state {
    case .began:
      beginInteraction()
      lastPan = t
    case .changed:
      let d = CGPoint(x: t.x - lastPan.x, y: t.y - lastPan.y)
      lastPan = t
      if isPlan {
        panBy(d)
      } else {
        orbit.yaw -= Float(d.x) * 0.0065
        orbit.pitch = clampPitch(orbit.pitch + Float(d.y) * 0.0055)
      }
      applyCamera()
    case .ended, .cancelled:
      let v = g.velocity(in: view)
      if isPlan {
        panVelocity = panVector(CGPoint(x: v.x * 0.8, y: v.y * 0.8))
      } else {
        orbitVelocity = SIMD2(-Float(v.x) * 0.0065 * 0.8, Float(v.y) * 0.0055 * 0.8)
      }
      startTicking()
    default: break
    }
  }

  @objc private func handlePan2(_ g: UIPanGestureRecognizer) {
    let t = g.translation(in: view)
    switch g.state {
    case .began:
      beginInteraction()
      lastPan2 = t
    case .changed:
      panBy(CGPoint(x: t.x - lastPan2.x, y: t.y - lastPan2.y))
      lastPan2 = t
      applyCamera()
    case .ended, .cancelled:
      let v = g.velocity(in: view)
      panVelocity = panVector(CGPoint(x: v.x * 0.6, y: v.y * 0.6))
      startTicking()
    default: break
    }
  }

  private func panVector(_ d: CGPoint) -> SIMD3<Float> {
    let q = cameraNode.simdOrientation
    let right = q.act(SIMD3(1, 0, 0)), up = q.act(SIMD3(0, 1, 0))
    let k = metersPerPoint
    return (-right * Float(d.x) + up * Float(d.y)) * k
  }

  private func panBy(_ d: CGPoint) {
    orbit.target += panVector(d)
  }

  @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
    switch g.state {
    case .began:
      beginInteraction()
      pinchStart = orbit.distance
    case .changed:
      orbit.distance = max(0.25, min(80, pinchStart / Float(max(0.05, g.scale))))
      applyCamera()
    default: break
    }
  }

  @objc private func handleRotate(_ g: UIRotationGestureRecognizer) {
    switch g.state {
    case .began:
      beginInteraction()
      lastRotation = 0
    case .changed:
      orbit.yaw -= Float(g.rotation - lastRotation)
      lastRotation = g.rotation
      applyCamera()
    default: break
    }
  }

  @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
    let pt = g.location(in: view)
    guard let hit = hitMesh(at: pt) else { return }
    beginInteraction()
    var o = orbit
    o.target = isPlan ? SIMD3(hit.x, orbit.target.y, hit.z) : hit
    o.distance = max(0.6, simd_distance(cameraNode.simdPosition, hit) * 0.55)
    fly(to: o, fov: fov, animated: true, duration: 0.5)
  }

  @objc private func handleTap(_ g: UITapGestureRecognizer) {
    onTap?(g.location(in: view))
  }

  // MARK: - photo markers

  func setPhotos(_ list: [PreviewPhoto]) {
    photos = list
    markersRoot.childNodes.forEach { $0.removeFromParentNode() }
    markerNodes = [:]
    let lineMat = SCNMaterial()
    lineMat.lightingModel = .constant
    lineMat.diffuse.contents = UIColor(red: 1, green: 0.84, blue: 0.30, alpha: 1)
    var shapes: [String: SCNGeometry] = [:]
    for p in list {
      let key = "\(p.width)x\(p.height)@\(Int(p.fx))"
      let g = shapes[key] ?? {
        let g = Self.frustum(p, depth: 0.16)
        g.materials = [lineMat]
        shapes[key] = g
        return g
      }()
      let node = SCNNode(geometry: g)
      node.simdTransform = p.cameraToHouse
      node.name = "photo-\(p.id)"
      let plane = SCNPlane(width: CGFloat(Float(p.width) / p.fx * 0.16), height: CGFloat(Float(p.height) / p.fy * 0.16))
      let m = SCNMaterial()
      m.lightingModel = .constant
      m.diffuse.contents = UIColor(white: 0.15, alpha: 1)
      m.isDoubleSided = true
      plane.materials = [m]
      let image = SCNNode(geometry: plane)
      image.simdPosition = SIMD3(0, 0, -0.16)
      image.name = "image"
      node.addChildNode(image)
      markersRoot.addChildNode(node)
      markerNodes[p.id] = node
    }
    // the walked path, per session, in time order
    for session in Set(list.map(\.session)) {
      let pts = list.filter { $0.session == session }.sorted { $0.timestamp < $1.timestamp }.map(\.position)
      guard pts.count > 1 else { continue }
      let src = SCNGeometrySource(vertices: pts.map { SCNVector3($0.x, $0.y, $0.z) })
      var idx: [UInt32] = []
      for i in 0..<(pts.count - 1) { idx += [UInt32(i), UInt32(i + 1)] }
      let path = SCNGeometry(sources: [src], elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
      let m = SCNMaterial()
      m.lightingModel = .constant
      m.diffuse.contents = UIColor(white: 1, alpha: 0.35)
      m.blendMode = .alpha
      path.materials = [m]
      markersRoot.addChildNode(SCNNode(geometry: path))
    }
  }

  func setThumbnail(_ image: CGImage, for id: Int) {
    guard let plane = markerNodes[id]?.childNode(withName: "image", recursively: false)?.geometry else { return }
    plane.firstMaterial?.diffuse.contents = image
  }

  func showMarkers(_ show: Bool) {
    markersRoot.isHidden = !show
  }

  func select(marker id: Int?) {
    if let old = selectedMarker, let n = markerNodes[old] {
      n.simdScale = SIMD3(repeating: 1)
      n.isHidden = false
    }
    selectedMarker = id
    if let id, let n = markerNodes[id] {
      n.simdScale = SIMD3(repeating: 1.5)
    }
  }

  /// the marker nearest a screen point (within ~44 pt), for tap-to-select
  func marker(at point: CGPoint) -> PreviewPhoto? {
    var best: (PreviewPhoto, CGFloat)?
    for p in photos {
      guard let node = markerNodes[p.id], !node.isHidden else { continue }
      let tip = p.cameraToHouse * SIMD4(0, 0, -0.1, 1)
      let s = view.projectPoint(SCNVector3(tip.x, tip.y, tip.z))
      guard s.z > 0, s.z < 1 else { continue }
      let d = hypot(CGFloat(s.x) - point.x, CGFloat(s.y) - point.y)
      if d < 44, d < (best?.1 ?? .infinity) { best = (p, d) }
    }
    return best?.0
  }

  private static func frustum(_ p: PreviewPhoto, depth: Float) -> SCNGeometry {
    let hx = Float(p.width) / 2 / p.fx * depth, hy = Float(p.height) / 2 / p.fy * depth
    let pts: [SIMD3<Float>] = [.zero, SIMD3(-hx, -hy, -depth), SIMD3(hx, -hy, -depth), SIMD3(hx, hy, -depth), SIMD3(-hx, hy, -depth),
                               // an "up" tick on the upright top edge (sensor −X side)
                               SIMD3(-hx * 1.25, 0, -depth)]
    let idx: [UInt16] = [0, 1, 0, 2, 0, 3, 0, 4, 1, 2, 2, 3, 3, 4, 4, 1, 1, 5, 5, 4]
    let src = SCNGeometrySource(vertices: pts.map { SCNVector3($0.x, $0.y, $0.z) })
    return SCNGeometry(sources: [src], elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
  }

  // MARK: - measuring

  func setMeasure(_ a: SIMD3<Float>?, _ b: SIMD3<Float>?, label: String?) {
    measureRoot.childNodes.forEach { $0.removeFromParentNode() }
    let accent = UIColor(red: 1, green: 0.84, blue: 0.30, alpha: 1)
    func onTop(_ m: SCNMaterial) {
      m.lightingModel = .constant
      m.readsFromDepthBuffer = false
      m.writesToDepthBuffer = false
    }
    let camDist = { (p: SIMD3<Float>) in max(0.3, simd_distance(p, self.cameraNode.simdPosition)) }
    for p in [a, b].compactMap({ $0 }) {
      let s = SCNSphere(radius: CGFloat(0.008 * camDist(p)))
      let m = SCNMaterial()
      onTop(m)
      m.diffuse.contents = UIColor.white
      s.materials = [m]
      let n = SCNNode(geometry: s)
      n.simdPosition = p
      n.renderingOrder = 100
      measureRoot.addChildNode(n)
    }
    guard let a, let b else { return }
    let len = simd_distance(a, b)
    let cyl = SCNCylinder(radius: CGFloat(0.0025 * camDist((a + b) / 2)), height: CGFloat(len))
    let m = SCNMaterial()
    onTop(m)
    m.diffuse.contents = accent
    cyl.materials = [m]
    let line = SCNNode(geometry: cyl)
    line.simdPosition = (a + b) / 2
    let dir = simd_normalize(b - a)
    let up = SIMD3<Float>(0, 1, 0)
    if abs(simd_dot(dir, up)) < 0.9999 {
      line.simdOrientation = simd_quatf(from: up, to: dir)
    } else if dir.y < 0 {
      line.simdOrientation = simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0))
    }
    line.renderingOrder = 99
    measureRoot.addChildNode(line)
    if let label {
      let img = Self.labelImage(label)
      let h = 0.045 * camDist((a + b) / 2)
      let plane = SCNPlane(width: CGFloat(h) * img.size.width / img.size.height, height: CGFloat(h))
      let pm = SCNMaterial()
      onTop(pm)
      pm.diffuse.contents = img
      pm.isDoubleSided = true
      plane.materials = [pm]
      let tag = SCNNode(geometry: plane)
      tag.simdPosition = (a + b) / 2
      tag.constraints = [SCNBillboardConstraint()]
      tag.renderingOrder = 101
      measureRoot.addChildNode(tag)
    }
  }

  private static func labelImage(_ text: String) -> UIImage {
    let font = UIFont.systemFont(ofSize: 44, weight: .semibold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
    let size = (text as NSString).size(withAttributes: attrs)
    let pad: CGFloat = 22
    let box = CGSize(width: size.width + pad * 2, height: size.height + pad)
    return UIGraphicsImageRenderer(size: box).image { _ in
      let r = CGRect(origin: .zero, size: box)
      UIColor(red: 1, green: 0.84, blue: 0.30, alpha: 1).setFill()
      UIBezierPath(roundedRect: r, cornerRadius: box.height / 2).fill()
      (text as NSString).draw(at: CGPoint(x: pad, y: pad / 2), withAttributes: attrs)
    }
  }

  // MARK: - benchmark

  /// Spins the camera for `seconds` with continuous rendering and reports frames per second
  func benchmark(seconds: Double, done: @escaping (Double) -> Void) {
    view.rendersContinuously = true
    frameCounter.reset()
    let start = CACurrentMediaTime()
    let startYaw = orbit.yaw
    let link = CADisplayLink(target: BenchProxy { [weak self] link in
      guard let self else { return }
      let t = CACurrentMediaTime() - start
      self.orbit.yaw = startYaw + Float(t) * 0.8
      self.applyCamera()
      if t >= seconds {
        link.invalidate()
        self.view.rendersContinuously = false
        done(Double(self.frameCounter.count) / t)
      }
    }, selector: #selector(BenchProxy.tick(_:)))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
    link.add(to: .main, forMode: .common)
  }
}

/// Counts rendered frames (called on SceneKit's render thread)
final class FrameCounter: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var frames = 0
  var count: Int { lock.withLock { frames } }
  func reset() { lock.withLock { frames = 0 } }
  func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
    lock.withLock { frames += 1 }
  }
}

private final class DisplayLinkProxy: NSObject {
  weak var target: PreviewScene?
  init(_ t: PreviewScene) { target = t }
  @objc func tick(_ link: CADisplayLink) {
    MainActor.assumeIsolated {
      guard let target else { link.invalidate(); return }
      target.tick()
    }
  }
}

private final class BenchProxy: NSObject {
  let body: (CADisplayLink) -> Void
  init(_ body: @escaping (CADisplayLink) -> Void) { self.body = body }
  @objc func tick(_ link: CADisplayLink) { body(link) }
}

extension UIColor {
  func mixed(with other: UIColor, amount: CGFloat) -> UIColor {
    var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
    var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
    getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
    other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
    return UIColor(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount, blue: b1 + (b2 - b1) * amount, alpha: 1)
  }

  func scaled(_ k: CGFloat) -> UIColor {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    getRed(&r, green: &g, blue: &b, alpha: &a)
    return UIColor(red: r * k, green: g * k, blue: b * k, alpha: a)
  }
}
