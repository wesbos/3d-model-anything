import SwiftUI
import SceneKit
import simd

enum AppAppearance: String, CaseIterable, Identifiable {
  case system, light, dark

  var id: String { rawValue }
  var title: String { rawValue.capitalized }

  static func colorScheme(for rawValue: String) -> ColorScheme? {
    switch AppAppearance(rawValue: rawValue) ?? .system {
    case .system: return nil
    case .light: return .light
    case .dark: return .dark
    }
  }
}

/// Fieldwork: paper, ink, ruled sections and one purposeful accent.
enum Fieldwork {
  static let uiPaper = UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(red: 0.075, green: 0.082, blue: 0.078, alpha: 1)
      : UIColor(red: 0.965, green: 0.951, blue: 0.922, alpha: 1)
  }
  static let paper = Color(uiColor: uiPaper)
  static let ink = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(red: 0.92, green: 0.92, blue: 0.88, alpha: 1)
      : UIColor(red: 0.12, green: 0.13, blue: 0.12, alpha: 1)
  })
  static let secondary = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(red: 0.66, green: 0.67, blue: 0.63, alpha: 1)
      : UIColor(red: 0.39, green: 0.39, blue: 0.36, alpha: 1)
  })
  static let orange = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(red: 0.79, green: 0.28, blue: 0.13, alpha: 1)
      : UIColor(red: 0.76, green: 0.28, blue: 0.12, alpha: 1)
  })
  static let rule = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(red: 0.25, green: 0.26, blue: 0.24, alpha: 1)
      : UIColor(red: 0.81, green: 0.79, blue: 0.75, alpha: 1)
  })
}

struct FieldworkButtonStyle: ButtonStyle {
  var filled = true
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.body.weight(.semibold))
      .frame(maxWidth: .infinity, minHeight: 52)
      .padding(.horizontal, 12)
      .foregroundStyle(filled ? Color.white : Fieldwork.orange)
      .background(filled ? Fieldwork.orange : .clear, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Fieldwork.orange, lineWidth: filled ? 0 : 1))
      .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
  }
}

struct FieldworkEyebrow: View {
  let text: String
  var body: some View {
    Text(text.uppercased()).font(.system(.caption, design: .monospaced)).tracking(2)
      .foregroundStyle(Fieldwork.secondary)
  }
}

struct FieldworkRule: View {
  var body: some View { Rectangle().fill(Fieldwork.rule).frame(height: 0.5).accessibilityHidden(true) }
}

struct FieldworkCorners: Shape {
  func path(in r: CGRect) -> Path {
    var p = Path()
    let d: CGFloat = 14
    for (x, y, sx, sy) in [(r.minX,r.minY,1.0,1.0),(r.maxX,r.minY,-1.0,1.0),(r.minX,r.maxY,1.0,-1.0),(r.maxX,r.maxY,-1.0,-1.0)] {
      p.move(to: CGPoint(x: x, y: y + sy*d)); p.addLine(to: CGPoint(x: x,y: y)); p.addLine(to: CGPoint(x: x+sx*d,y: y))
    }
    return p
  }
}

struct FieldworkThumbnail: View {
  let folder: URL?
  let index: Int
  @State private var image: UIImage?
  @State private var loaded = false
  var body: some View {
    ZStack {
      if let image { Image(uiImage: image).resizable().scaledToFit() }
      else if loaded {
        VStack(spacing: 8) {
          Image(systemName: "cube.transparent").font(.largeTitle.weight(.ultraLight))
          Text("No preview yet").font(.caption)
        }.foregroundStyle(Fieldwork.secondary)
      } else { ProgressView().tint(Fieldwork.orange) }
    }
    .task(id: "\(folder?.path ?? "")/\(index)") {
      image = nil; loaded = false
      if let folder {
        let result = await FieldworkThumbnails.shared.image(folder: folder, index: index)
        guard !Task.isCancelled else { return }
        image = result
      }
      loaded = true
    }
    .accessibilityHidden(true)
  }
}

/// Serialize thumbnail work so a library never loads several full meshes concurrently.
/// Cache only small rendered images, not scenes or mesh buffers.
actor FieldworkThumbnails {
  static let shared = FieldworkThumbnails()
  private let cache = NSCache<NSString, UIImage>()
  init() { cache.totalCostLimit = 24 * 1024 * 1024 }
  func image(folder: URL, index: Int) -> UIImage? {
    let meshURL = folder.appendingPathComponent("mesh/room-\(index).ply")
    let colorURL = folder.appendingPathComponent("mesh/room-\(index)-colors.bin")
    let modelURL = folder.appendingPathComponent("rooms/room-\(index).usdz")
    let dates = [meshURL, colorURL, modelURL].map { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0 }
    let key = "\(folder.path)/\(index)/\(dates)" as NSString
    if let image = cache.object(forKey: key) { return image }
    let image: UIImage? = autoreleasepool {
      let scene = SCNScene()
      let content = SCNNode()
      scene.rootNode.addChildNode(content)
      var lo = SIMD3<Float>(repeating: -1), hi = SIMD3<Float>(repeating: 1)
      if let mesh = try? PLYMesh.load(url: meshURL) {
        let room = PreviewRoom(session: 0, index: index, name: "", mesh: meshURL, usdz: nil)
        let asset = MeshAsset(room: room, mesh: mesh)
        lo = asset.insideMin; hi = asset.insideMax
        var sources = [asset.vertexSource, asset.normalSource]
        let colors = mesh.loadCachedColors()
        if let colors { sources.append(MeshAsset.colorSource(colors, count: mesh.vertexCount)) }
        let element = SCNGeometryElement(indices: asset.inside, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = colors == nil ? UIColor(red: 0.69, green: 0.65, blue: 0.57, alpha: 1) : UIColor.white
        material.lightingModel = colors == nil ? .lambert : .constant
        material.isDoubleSided = false
        geometry.materials = [material]
        content.addChildNode(SCNNode(geometry: geometry))
      } else if let model = try? SCNScene(url: modelURL) {
        for node in model.rootNode.childNodes { content.addChildNode(node) }
        let bounds = content.boundingBox
        lo = SIMD3(bounds.min.x, bounds.min.y, bounds.min.z); hi = SIMD3(bounds.max.x, bounds.max.y, bounds.max.z)
      } else { return nil }
      let center = (lo + hi) / 2
      let extent = max(1, simd_length(hi - lo))
      let camera = SCNNode(); camera.camera = SCNCamera()
      camera.camera?.usesOrthographicProjection = true
      camera.camera?.orthographicScale = Double(extent * 0.43)
      camera.camera?.zFar = Double(extent * 8)
      camera.simdPosition = center + SIMD3(extent, extent * 0.9, extent)
      camera.look(at: SCNVector3(center.x, center.y, center.z))
      scene.rootNode.addChildNode(camera)
      let light = SCNNode(); light.light = SCNLight(); light.light?.type = .ambient; light.light?.intensity = 700
      scene.rootNode.addChildNode(light)
      let sun = SCNNode(); sun.light = SCNLight(); sun.light?.type = .omni; sun.light?.intensity = 700
      sun.simdPosition = camera.simdPosition; scene.rootNode.addChildNode(sun)
      let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
      renderer.scene = scene; renderer.pointOfView = camera
      return renderer.snapshot(atTime: 0, with: CGSize(width: 440, height: 360), antialiasingMode: .multisampling4X)
    }
    if let image { cache.setObject(image, forKey: key, cost: 440 * 360 * 4) }
    return image
  }
}
