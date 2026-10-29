import SwiftUI

struct ScanReview: View {
  @StateObject private var model: PreviewModel
  init(source: PreviewSource) { _model = StateObject(wrappedValue: PreviewModel(source: source)) }
  var body: some View { PreviewScreen(model: model) }
}

import SceneKit
import SwiftUI
import simd

// MARK: - public entry points

/// 3D preview of a whole house: every room's active scan, all sessions in the house frame
struct HouseViewer: View {
  @StateObject private var model: PreviewModel
  init(house: HouseProject) {
    _model = StateObject(wrappedValue: PreviewModel(source: .house(house)))
  }
  var body: some View { PreviewScreen(model: model) }
}

/// 3D preview of one capture session (all its rooms), placed in the house frame
struct SessionViewer: View {
  @StateObject private var model: PreviewModel
  init(house: HouseProject, session: HouseProject.Session) {
    _model = StateObject(wrappedValue: PreviewModel(source: .session(house, session)))
  }
  var body: some View { PreviewScreen(model: model) }
}

// MARK: - model

@MainActor
final class PreviewModel: ObservableObject {
  let source: PreviewSource
  let scene = PreviewScene()

  enum Phase: Equatable { case loading, ready, empty(String) }
  @Published var phase: Phase = .loading
  @Published var loadStage = "Opening scan…"
  @Published var loadFraction: Double = 0

  @Published private(set) var style: RenderStyle = .photo
  @Published private(set) var styles: [RenderStyle] = []
  @Published private(set) var plan = false
  /// plan cut, meters above the floor
  @Published var cutHeight: Float = 1.4 { didSet { applyClip() } }
  @Published private(set) var cutRange: ClosedRange<Float> = 0.2...2.6

  @Published private(set) var visibleRooms: Set<String> = []
  @Published private(set) var showSurroundings = true

  @Published private(set) var bakeFraction: Double?
  @Published private(set) var bakeLabel = ""
  @Published private(set) var bakeNote: String?

  // walkthrough
  @Published private(set) var walkthrough = false
  @Published private(set) var photos: [PreviewPhoto] = []
  @Published private(set) var current: Int?
  @Published private(set) var atPhoto = false
  @Published var photoOpacity: Double = 1
  @Published private(set) var overlay: UIImage?
  let thumbnails = ThumbnailStore()

  // measuring
  @Published private(set) var measuring = false
  @Published private(set) var measureA: SIMD3<Float>?
  @Published private(set) var measureB: SIMD3<Float>?

  @Published private(set) var scaleBar: (width: CGFloat, label: String)?
  @Published var showNorth = false { didSet { scene.showNorth = showNorth } }
  @Published private(set) var hasNorth = false
  @Published var showStats = ProcessInfo.processInfo.arguments.contains("-preview-stats")
  @Published private(set) var stats = ""
  @Published private(set) var fps: Double?

  private var assets: [MeshAsset] = []
  private var allPhotos: [PreviewPhoto] = []
  private var bakeCancel = CancelFlag()
  private var started = false
  private var loadSeconds: Double = 0
  private var overlayTask: Task<Void, Never>?

  init(source: PreviewSource) {
    self.source = source
    visibleRooms = Set(source.rooms.filter { !source.hiddenSessions.contains($0.session) }.map(\.id))
    scene.setSessions(source.sessions)
    scene.onTap = { [weak self] p in self?.tapped(p) }
    scene.onArrivedAtPhoto = { [weak self] photo in self?.arrived(at: photo) }
    scene.onLeftPhoto = { [weak self] in
      guard let self else { return }
      self.atPhoto = false
      if self.walkthrough { self.scene.showMarkers(true) }
    }
    scene.onCameraChanged = { [weak self] in self?.cameraChanged() }
  }

  var sessions: [PreviewSession] { source.sessions }
  var rooms: [PreviewRoom] { source.rooms }
  var isSingleRoom: Bool { visibleRooms.count == 1 && rooms.count > 1 }

  // MARK: loading

  func start() {
    guard !started else { return }
    started = true
    Task { await load() }
  }

  private func load() async {
    let t0 = CFAbsoluteTimeGetCurrent()
    let rooms = source.rooms
    let sessions = source.sessions
    var loaded: [MeshAsset] = []
    var failures: [String] = []
    for (i, room) in rooms.enumerated() {
      guard FileManager.default.fileExists(atPath: room.mesh.path) else { continue }
      loadStage = rooms.count > 1 ? "Loading \(room.name) (\(i + 1) of \(rooms.count))" : "Loading \(room.name)"
      let toHouse = sessions.first { $0.index == room.session }?.toHouse ?? matrix_identity_float4x4
      let base = Double(i) / Double(rooms.count), span = 1 / Double(rooms.count)
      let result = await Task.detached(priority: .userInitiated) { () -> Result<MeshAsset, Error> in
        Result {
          let mesh = try PLYMesh.load(url: room.mesh, transform: toHouse) { f in
            Task { @MainActor in self.loadFraction = base + span * 0.7 * f }
          }
          let asset = MeshAsset(room: room, mesh: mesh)
          if let cached = mesh.loadCachedColors() { asset.setPhotoColors(cached) }
          return asset
        }
      }.value
      switch result {
      case .success(let a): loaded.append(a)
      case .failure(let e):
        if (e as? PLYMesh.LoadError).map({ if case .empty = $0 { true } else { false } }) != true {
          failures.append("\(room.name): \(e.localizedDescription)")
        }
      }
      loadFraction = base + span
    }
    if loaded.count > 1 {
      loadStage = "Merging rooms"
      await Task.detached(priority: .userInitiated) { Self.trimSurroundings(loaded) }.value
    }
    var north: [String: PreviewNorth] = [:]
    for room in source.rooms {
      if let session = source.sessions.first(where: { $0.index == room.session }),
         let reading = PreviewNorth.load(session: session, room: room.index) { north[room.id] = reading }
    }
    hasNorth = !north.isEmpty
    scene.setNorth(north)
    assets = loaded
    for a in loaded { scene.add(a) }
    loadSeconds = CFAbsoluteTimeGetCurrent() - t0
    let levels = (scene.floorY, scene.ceilingY)
    cutRange = 0.2...max(1, levels.1 - levels.0 + 0.1)
    cutHeight = min(1.4, cutRange.upperBound)

    var available: [RenderStyle] = loaded.isEmpty ? [] : [.photo, .coverage, .clay, .wireframe]
    if !loaded.isEmpty, sessions.count > 1 { available.insert(.sessions, at: 2) }
    styles = available
    style = loaded.isEmpty ? .roomPlan : .photo
    scene.setStyle(style)
    scene.setVisibleRooms(visibleRooms, surroundings: showSurroundings)
    updateStats()
    if !loaded.isEmpty {
      scene.resetView(animated: false)
      phase = .ready
    }
    log("loaded \(loaded.count) meshes, \(scene.totalVertices) vertices, \(scene.totalTriangles) triangles in \(String(format: "%.2f", loadSeconds)) s")

    // photos (poses in the house frame)
    let photoLists = await Task.detached(priority: .userInitiated) { () -> [PreviewPhoto] in
      var all: [PreviewPhoto] = []
      for s in sessions { all += PreviewSource.photos(of: s, firstID: all.count) }
      return all.sorted { ($0.session, $0.timestamp) < ($1.session, $1.timestamp) }
    }.value
    allPhotos = photoLists
    refreshPhotoList()
    scene.setPhotos(photoLists)

    // RoomPlan models
    await loadRoomPlan()
    if loaded.isEmpty {
      if scene.hasRoomPlan {
        styles = [.roomPlan]
        scene.setStyle(.roomPlan)
        scene.resetView(animated: false)
        phase = .ready
      } else {
        phase = .empty(failures.first ?? "This scan has no LiDAR mesh or RoomPlan model yet.")
      }
    } else if scene.hasRoomPlan {
      styles.append(.roomPlan)
    }

    PreviewDebug.didLoad(self)
    bakeMissing()
  }

  /// Keep the outside part of only the newest room per session, minus what shown rooms (or newer
  /// sessions) already cover. See `SurroundingsFilter`.
  nonisolated private static func trimSurroundings(_ assets: [MeshAsset]) {
    var newest: [Int: MeshAsset] = [:]
    for a in assets where (newest[a.room.session]?.room.index ?? -1) < a.room.index { newest[a.room.session] = a }
    for a in assets where newest[a.room.session] !== a { a.outside = [] }
    var occupied = Set<Int64>()
    for a in assets { SurroundingsFilter.occupancy(a.mesh, a.inside, into: &occupied) }
    for a in newest.values.sorted(by: { $0.room.session > $1.room.session }) {
      a.outside = SurroundingsFilter.subtract(a.mesh, a.outside, occupied)
      SurroundingsFilter.occupancy(a.mesh, a.outside, into: &occupied)
    }
  }

  private func loadRoomPlan() async {
    var perSessionStructure: Set<Int> = []
    for room in rooms {
      guard let session = sessions.first(where: { $0.index == room.session }) else { continue }
      var url = room.usdz
      if url == nil, !perSessionStructure.contains(session.index) {
        let s = session.folder.appendingPathComponent("structure.usdz")
        if FileManager.default.fileExists(atPath: s.path) { url = s; perSessionStructure.insert(session.index) }
      }
      guard let url else { continue }
      let toHouse = session.toHouse
      let node = await Task.detached(priority: .utility) { () -> SCNNode? in
        guard let s = try? SCNScene(url: url, options: [.checkConsistency: false]) else { return nil }
        let container = SCNNode()
        for c in s.rootNode.childNodes { container.addChildNode(c) }
        container.simdTransform = toHouse
        return container
      }.value
      if let node { scene.addRoomPlan(node, roomID: room.id) }
    }
  }

  // MARK: photo colors

  func bakeMissing(force: Bool = false) {
    let todo = assets.filter { force || $0.photoTextures == nil }
    guard !todo.isEmpty, !allPhotos.isEmpty else {
      if allPhotos.isEmpty && assets.contains(where: { $0.photoColors == nil }) { bakeNote = "No photos to color the mesh with" }
      return
    }
    bakeCancel.cancel()
    let flag = CancelFlag()
    bakeCancel = flag
    bakeNote = nil
    bakeFraction = 0
    let photos = allPhotos
    Task {
      for (k, asset) in todo.enumerated() {
        if flag.isCancelled { break }
        let isAligned = source.sessions.first { $0.index == asset.room.session }?.aligned == true
        let alignedSessions = Set(source.sessions.filter(\.aligned).map(\.index))
        let sessionPhotos = photos.filter {
          $0.session == asset.room.session || (isAligned && alignedSessions.contains($0.session))
        }
        bakeLabel = todo.count > 1 ? "Coloring \(asset.room.name)" : "Coloring from photos"
        let base = Double(k) / Double(todo.count), span = 1 / Double(todo.count)
        // Retain the small vertex-color cache as a quick fallback for occluded/unseen faces.
        if asset.photoColors == nil {
          let colors = await Task.detached(priority: .utility) {
            VertexColorBaker.bake(mesh: asset.mesh, photos: sessionPhotos, progress: { _, _ in }, isCancelled: { flag.isCancelled })
          }.value
          guard !flag.isCancelled else { break }
          if let colors {
            asset.setPhotoColors(colors.rgba)
            scene.photoColorsChanged(for: asset.room.id)
            let mesh = asset.mesh, rgba = colors.rgba
            Task.detached(priority: .utility) { try? mesh.saveColors(rgba) }
          }
        }
        let pixelBudget = 48_000_000 / max(1, assets.count)
        bakeLabel = "Adding photo detail to \(asset.room.name)"
        let mesh = asset.mesh, inside = asset.inside, outside = asset.outside
        let result = await Task.detached(priority: .utility) {
          PhotoTextures.build(mesh: mesh, inside: inside, outside: outside, photos: sessionPhotos,
                              pixelBudget: pixelBudget, progress: { f in
            Task { @MainActor in
              guard !flag.isCancelled else { return }
              self.bakeFraction = base + span * f
            }
          }, isCancelled: { flag.isCancelled })
        }.value
        guard let result, !flag.isCancelled else { break }
        asset.photoTextures = result
        scene.photoColorsChanged(for: asset.room.id)
        log("textured \(asset.room.name): \(result.triangleCount) triangles from \(result.photoCount) photos, \(result.pixelCount) texture pixels")
      }
      if flag.isCancelled {
        // leave partially painted meshes as they are; next open resumes (no cache was written)
        bakeNote = "Coloring paused"
      }
      bakeFraction = nil
    }
  }

  func cancelBake() {
    bakeCancel.cancel()
    bakeFraction = nil
    bakeNote = "Coloring paused"
  }

  var canRecolor: Bool { !assets.isEmpty && !allPhotos.isEmpty && bakeFraction == nil }

  // MARK: style + view

  func setStyle(_ s: RenderStyle) {
    guard s != style else { return }
    style = s
    scene.setStyle(s)
  }

  func togglePlan() {
    if walkthrough { endWalkthrough() }
    plan.toggle()
    scene.setPlan(plan, animated: true)
    applyClip()
    if !plan { scaleBar = nil } else { cameraChanged() }
  }

  private func applyClip() {
    scene.setClip(plan ? scene.floorY + cutHeight : nil)
  }

  func resetView() {
    if walkthrough, atPhoto { scene.leavePhotoView() }
    scene.resetView(animated: true)
  }

  func setRoomVisible(_ id: String, _ visible: Bool) {
    var v = visibleRooms
    if visible { v.insert(id) } else { v.remove(id) }
    guard !v.isEmpty else { return }
    applyFilter(v)
  }

  func showOnly(_ id: String?) {
    applyFilter(id.map { [$0] } ?? Set(rooms.map(\.id)))
  }

  func setSessionVisible(_ index: Int, _ visible: Bool) {
    var v = visibleRooms
    for r in rooms where r.session == index {
      if visible { v.insert(r.id) } else { v.remove(r.id) }
    }
    guard !v.isEmpty else { return }
    applyFilter(v)
  }

  func isSessionVisible(_ index: Int) -> Bool { rooms.contains { $0.session == index && visibleRooms.contains($0.id) } }

  func setSurroundings(_ on: Bool) {
    showSurroundings = on
    scene.setVisibleRooms(visibleRooms, surroundings: on)
  }

  private func applyFilter(_ v: Set<String>) {
    visibleRooms = v
    scene.setVisibleRooms(v, surroundings: showSurroundings)
    refreshPhotoList()
    if walkthrough { scene.setPhotos(photos) ; loadMarkerThumbnails() }
    scene.resetView(animated: true)
    updateStats()
  }

  private func refreshPhotoList() {
    let shown = rooms.filter { visibleRooms.contains($0.id) }
    let keys = Set(shown.map { "\($0.session)/\($0.index)" })
    let sessionsShown = Set(shown.map(\.session))
    // whole sessions shown: all their photos; otherwise the photos taken while scanning the shown rooms
    let all = rooms.filter { sessionsShown.contains($0.session) }
    photos = allPhotos.filter { p in
      guard sessionsShown.contains(p.session) else { return false }
      let sessionRooms = all.filter { $0.session == p.session }
      if sessionRooms.allSatisfy({ visibleRooms.contains($0.id) }) { return true }
      return keys.contains("\(p.session)/\(p.room)")
    }
    if let c = current, c >= photos.count { current = nil }
  }

  // MARK: walkthrough

  func toggleWalkthrough() {
    walkthrough ? endWalkthrough() : startWalkthrough()
  }

  private func startWalkthrough() {
    guard !photos.isEmpty else { return }
    if measuring { toggleMeasure() }
    if plan {
      plan = false
      scene.setPlan(false, animated: false)
      applyClip()
      scaleBar = nil
    }
    walkthrough = true
    scene.setPhotos(photos)
    scene.showMarkers(true)
    loadMarkerThumbnails()
    go(to: current ?? 0)
  }

  func endWalkthrough() {
    walkthrough = false
    atPhoto = false
    overlay = nil
    scene.showMarkers(false)
    scene.select(marker: nil)
    if scene.photoView != nil {
      scene.leavePhotoView()
      scene.resetView(animated: true)
    }
  }

  func go(to index: Int) {
    guard photos.indices.contains(index) else { return }
    let far = current.map { simd_distance(photos[$0].position, photos[index].position) > 2 } ?? true
    current = index
    atPhoto = false
    let photo = photos[index]
    loadOverlay(photo)
    scene.fly(to: photo, duration: far ? 1.0 : 0.6)
  }

  func next() { if let c = current { go(to: min(photos.count - 1, c + 1)) } }
  func previous() { if let c = current { go(to: max(0, c - 1)) } }

  private func arrived(at photo: PreviewPhoto) {
    guard walkthrough, let c = current, photos.indices.contains(c), photos[c].id == photo.id else { return }
    scene.showMarkers(false)
    withAnimation(.easeOut(duration: 0.25)) { atPhoto = true }
  }

  func photoRect(in size: CGSize) -> CGRect? {
    guard let c = current, photos.indices.contains(c) else { return nil }
    return scene.photoRect(photos[c], in: size)
  }

  private func loadOverlay(_ photo: PreviewPhoto) {
    overlayTask?.cancel()
    overlayTask = Task {
      let img = await thumbnails.upright(photo.url, maxPixels: 1600)
      guard !Task.isCancelled else { return }
      overlay = img
    }
  }

  private func loadMarkerThumbnails() {
    let list = photos
    Task {
      for p in list {
        guard walkthrough else { return }
        if let img = await thumbnails.sensor(p.url) { scene.setThumbnail(img, for: p.id) }
      }
    }
  }

  // MARK: measuring

  func toggleMeasure() {
    measuring.toggle()
    if walkthrough, measuring { endWalkthrough() }
    measureA = nil
    measureB = nil
    scene.setMeasure(nil, nil, label: nil)
  }

  func clearMeasure() {
    measureA = nil
    measureB = nil
    scene.setMeasure(nil, nil, label: nil)
  }

  var measureDistance: Float? {
    guard let a = measureA, let b = measureB else { return nil }
    return simd_distance(a, b)
  }

  func debugTap(_ point: CGPoint) { tapped(point) }

  private func tapped(_ point: CGPoint) {
    if measuring {
      guard let hit = scene.hitMesh(at: point) else { return }
      if measureA == nil || measureB != nil {
        measureA = hit
        measureB = nil
      } else {
        measureB = hit
      }
      scene.setMeasure(measureA, measureB, label: measureDistance.map(Self.format))
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    } else if walkthrough {
      if let p = scene.marker(at: point), let i = photos.firstIndex(where: { $0.id == p.id }) { go(to: i) }
    }
  }

  static func format(_ meters: Float) -> String {
    let inches = meters / 0.0254
    let ft = Int(inches / 12), inch = Int((inches - Float(ft) * 12).rounded())
    let imperial = inch == 12 ? "\(ft + 1)′ 0″" : "\(ft)′ \(inch)″"
    return String(format: "%.2f m", meters) + "  ·  " + imperial
  }

  // MARK: HUD

  private func cameraChanged() {
    guard plan else { return }
    let mpp = scene.metersPerPoint
    guard mpp > 0 else { return }
    let target: Float = 110
    let candidates: [Float] = [0.1, 0.2, 0.25, 0.5, 1, 2, 2.5, 5, 10, 20]
    let len = candidates.min { abs($0 / mpp - target) < abs($1 / mpp - target) } ?? 1
    let width = CGFloat(len / mpp)
    let label = len < 1 ? "\(Int(len * 100)) cm" : (len == len.rounded() ? "\(Int(len)) m" : String(format: "%.1f m", len))
    if scaleBar?.label != label || abs((scaleBar?.width ?? 0) - width) > 0.5 { scaleBar = (width, label) }
  }

  private func updateStats() {
    let v = scene.totalVertices, t = scene.totalTriangles
    func k(_ n: Int) -> String { n >= 1_000_000 ? String(format: "%.2fM", Double(n) / 1e6) : "\(n / 1000)k" }
    stats = "\(k(v)) vertices · \(k(t)) triangles · loaded in \(String(format: "%.2f", loadSeconds)) s" + (fps.map { String(format: " · %.0f fps", $0) } ?? "")
  }

  func measureFPS() {
    scene.benchmark(seconds: 4) { [weak self] f in
      self?.fps = f
      self?.updateStats()
      self?.log(String(format: "benchmark: %.1f fps", f))
    }
  }

  func log(_ s: String) {
    PreviewDebug.log(s)
  }
}

/// Thread-safe cancel flag for background work
final class CancelFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var isCancelled: Bool { lock.withLock { value } }
  func cancel() { lock.withLock { value = true } }
}

// MARK: - screen

struct PreviewScreen: View {
  @ObservedObject var model: PreviewModel
  @Environment(\.dismiss) private var dismiss
  @Namespace private var styleNS

  var body: some View {
    ZStack {
      PreviewSceneView(scene: model.scene)
        .ignoresSafeArea()

      // the photo, exactly where its pixels land on the 3D view (full-screen coordinates)
      GeometryReader { geo in
        if model.walkthrough, model.atPhoto, let img = model.overlay, let rect = model.photoRect(in: geo.size) {
          Image(uiImage: img)
            .resizable()
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .opacity(model.photoOpacity)
            .transition(.opacity)
        }
      }
      .ignoresSafeArea()
      .allowsHitTesting(false)

      overlays
    }
    .toolbar(.hidden, for: .navigationBar)
    .preferredColorScheme(.dark)
    .environment(\.colorScheme, .dark)
    .onAppear { model.start() }
    .onDisappear { model.cancelBake() }
  }

  @ViewBuilder private var overlays: some View {
    switch model.phase {
    case .loading:
      VStack(spacing: 0) {
        topBar
        Spacer()
        LoadingCard(stage: model.loadStage, fraction: model.loadFraction)
        Spacer()
      }
    case .empty(let message):
      VStack(spacing: 0) {
        topBar
        Spacer()
        VStack(spacing: 10) {
          Image(systemName: "cube.transparent").font(.system(size: 40, weight: .light))
          Text("Nothing to preview").font(.headline)
          Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: 320)
        .glass(RoundedRectangle(cornerRadius: 28, style: .continuous))
        Spacer()
      }
    case .ready:
      VStack(spacing: 10) {
        topBar
        statusPills
        HStack(alignment: .top) {
          if model.plan { CutSlider(model: model).transition(.move(edge: .leading).combined(with: .opacity)) }
          Spacer()
          toolRail
        }
        .padding(.horizontal, 16)
        Spacer()
        bottom
      }
      .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.walkthrough)
      .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.plan)
      .animation(.easeInOut(duration: 0.2), value: model.measuring)
    }
  }

  // MARK: top

  private var topBar: some View {
    HStack(spacing: 10) {
      GlassIconButton(icon: "xmark") { dismiss() }
      VStack(alignment: .leading, spacing: 1) {
        Text(model.source.title).font(.headline).lineLimit(1)
        Text(filterSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      .padding(.horizontal, 16)
      .frame(height: 44)
      .glass(Capsule())
      .onLongPressGesture { model.showStats.toggle() }
      Spacer(minLength: 0)
      if model.phase == .ready { filterMenu }
    }
    .padding(.horizontal, 16)
    .padding(.top, 4)
  }

  private var filterSubtitle: String {
    let shown = model.rooms.filter { model.visibleRooms.contains($0.id) }
    if shown.count == model.rooms.count { return model.source.subtitle }
    if shown.count == 1 { return shown[0].name }
    return "\(shown.count) of \(model.rooms.count) rooms"
  }

  private var filterMenu: some View {
    Menu {
      if model.rooms.count > 1 {
        Section("Rooms") {
          Button { model.showOnly(nil) } label: {
            Label("All rooms", systemImage: model.visibleRooms.count == model.rooms.count ? "checkmark" : "square.grid.2x2")
          }
          ForEach(model.rooms) { room in
            Toggle(isOn: Binding(get: { model.visibleRooms.contains(room.id) }, set: { model.setRoomVisible(room.id, $0) })) {
              Text(room.name + (model.sessions.count > 1 ? " · \(sessionTitle(room.session))" : ""))
            }
          }
          Menu("Show only…") {
            ForEach(model.rooms) { room in Button(room.name) { model.showOnly(room.id) } }
          }
        }
      }
      if model.sessions.count > 1 {
        Section("Sessions") {
          ForEach(model.sessions) { s in
            Toggle(isOn: Binding(get: { model.isSessionVisible(s.index) }, set: { model.setSessionVisible(s.index, $0) })) {
              Text(s.title + (s.aligned ? "" : " (not aligned)"))
            }
          }
        }
      }
      Section {
        Toggle("Surroundings", isOn: Binding(get: { model.showSurroundings }, set: { model.setSurroundings($0) }))
        Toggle("Recorded north", isOn: $model.showNorth).disabled(!model.hasNorth)
        Toggle("Statistics", isOn: $model.showStats)
        if model.canRecolor {
          Button { model.bakeMissing(force: true) } label: { Label("Recolor from photos", systemImage: "paintbrush") }
        }
      }
    } label: {
      Image(systemName: "line.3.horizontal.decrease")
        .font(.system(size: 17, weight: .semibold))
        .frame(width: 44, height: 44)
        .contentShape(Circle())
    }
    .foregroundStyle(.white)
    .glass(Circle(), interactive: true)
  }

  private func sessionTitle(_ index: Int) -> String { model.sessions.first { $0.index == index }?.title ?? "" }

  @ViewBuilder private var statusPills: some View {
    VStack(spacing: 8) {
      if let f = model.bakeFraction {
        HStack(spacing: 10) {
          ProgressRing(fraction: f).frame(width: 18, height: 18)
          Text("\(model.bakeLabel) · \(Int(f * 100))%").font(.footnote.weight(.medium)).monospacedDigit()
          Button { model.cancelBake() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .glass(Capsule())
        .transition(.move(edge: .top).combined(with: .opacity))
      } else if let note = model.bakeNote, model.style == .photo || model.style == .sessions {
        Button { model.bakeMissing() } label: {
          Label(note == "Coloring paused" ? "Coloring paused · Resume" : note, systemImage: "paintbrush")
            .font(.footnote.weight(.medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .glass(Capsule(), interactive: true)
      }
      if model.measuring {
        MeasureBanner(model: model).transition(.move(edge: .top).combined(with: .opacity))
      }
      if model.showStats, !model.stats.isEmpty {
        Button { model.measureFPS() } label: {
          Text(model.stats).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .glass(Capsule())
      }
    }
    .animation(.easeInOut(duration: 0.25), value: model.bakeFraction == nil)
  }

  private var toolRail: some View {
    VStack(spacing: 10) {
      GlassIconButton(icon: "scope") { model.resetView() }
      GlassIconButton(icon: model.plan ? "view.3d" : "map", active: model.plan) { model.togglePlan() }
        .disabled(model.walkthrough)
      if !model.photos.isEmpty {
        GlassIconButton(icon: "camera.viewfinder", active: model.walkthrough) { model.toggleWalkthrough() }
      }
      GlassIconButton(icon: "ruler", active: model.measuring) { model.toggleMeasure() }
    }
  }

  // MARK: bottom

  @ViewBuilder private var bottom: some View {
    if model.walkthrough {
      WalkthroughPanel(model: model)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    } else {
      VStack(spacing: 10) {
        HStack(alignment: .bottom) {
          if model.plan, let bar = model.scaleBar { ScaleBar(width: bar.width, label: bar.label) }
          Spacer()
          legend
        }
        .padding(.horizontal, 20)
        stylePicker
      }
      .padding(.bottom, 4)
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }

  @ViewBuilder private var legend: some View {
    switch model.style {
    case .coverage:
      LegendView(items: [(Color(red: 1, green: 0.23, blue: 0.19), "Needs photos"), (Color(red: 1, green: 0.8, blue: 0), "Almost"),
                         (Color(red: 0.2, green: 0.78, blue: 0.35), "Done"), (Color(white: 0.6), "Outside room")])
    case .sessions:
      LegendView(items: model.sessions.filter { model.isSessionVisible($0.index) }.map { (Color(uiColor: $0.hue), $0.title) })
    default:
      EmptyView()
    }
  }

  private var stylePicker: some View {
    HStack(spacing: 2) {
      ForEach(model.styles) { s in
        Button {
          withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.setStyle(s) }
        } label: {
          VStack(spacing: 3) {
            Image(systemName: s.icon).font(.system(size: 17, weight: .medium)).frame(height: 22)
            Text(s.title).font(.system(size: 10, weight: .semibold))
          }
          .frame(width: 58, height: 52)
          .foregroundStyle(model.style == s ? Color.black : Color.white)
          .background {
            if model.style == s {
              Capsule().fill(PreviewTheme.accent).matchedGeometryEffect(id: "style", in: styleNS)
            }
          }
          .contentShape(Capsule())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(5)
    .glass(Capsule())
  }
}

// MARK: - pieces

enum PreviewTheme {
  static let accent = Color(red: 1, green: 0.84, blue: 0.30)
}

struct PreviewSceneView: UIViewRepresentable {
  let scene: PreviewScene
  func makeUIView(context: Context) -> SCNView {
    scene.view.showsStatistics = ProcessInfo.processInfo.arguments.contains("-preview-scnstats")
    return scene.view
  }
  func updateUIView(_ uiView: SCNView, context: Context) {}
}

extension View {
  /// Liquid Glass on iOS 26+, a material before that
  @ViewBuilder func glass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
    if #available(iOS 26.0, *) {
      self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
    } else {
      self.background(.ultraThinMaterial, in: shape)
        .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5))
    }
  }
}

struct GlassIconButton: View {
  let icon: String
  var active = false
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 17, weight: .semibold))
        .frame(width: 44, height: 44)
        .foregroundStyle(active ? Color.black : Color.white)
        .background { if active { Circle().fill(PreviewTheme.accent) } }
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .glass(Circle(), interactive: true)
  }
}

private struct LoadingCard: View {
  let stage: String
  let fraction: Double
  var body: some View {
    VStack(spacing: 14) {
      ProgressRing(fraction: max(0.02, fraction)).frame(width: 44, height: 44)
      Text(stage).font(.subheadline.weight(.medium))
      Text("\(Int(fraction * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 32)
    .padding(.vertical, 24)
    .glass(RoundedRectangle(cornerRadius: 28, style: .continuous))
    .animation(.easeOut(duration: 0.2), value: fraction)
  }
}

struct ProgressRing: View {
  let fraction: Double
  var body: some View {
    ZStack {
      Circle().stroke(Color.white.opacity(0.15), lineWidth: 3)
      Circle().trim(from: 0, to: fraction)
        .stroke(PreviewTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
  }
}

private struct LegendView: View {
  let items: [(Color, String)]
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      ForEach(items.indices, id: \.self) { i in
        HStack(spacing: 7) {
          Circle().fill(items[i].0).frame(width: 9, height: 9)
          Text(items[i].1).font(.caption2.weight(.medium))
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .glass(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

private struct ScaleBar: View {
  let width: CGFloat
  let label: String
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.caption2.weight(.semibold)).monospacedDigit()
      ZStack(alignment: .bottom) {
        Rectangle().frame(width: width, height: 2)
        HStack { Rectangle().frame(width: 2, height: 8); Spacer(); Rectangle().frame(width: 2, height: 8) }.frame(width: width)
      }
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .glass(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .animation(.easeOut(duration: 0.15), value: width)
  }
}

/// Vertical slider for the plan cut height
private struct CutSlider: View {
  @ObservedObject var model: PreviewModel
  private let height: CGFloat = 200
  var body: some View {
    let range = model.cutRange
    let t = CGFloat((model.cutHeight - range.lowerBound) / (range.upperBound - range.lowerBound))
    VStack(spacing: 8) {
      Image(systemName: "scissors").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      ZStack(alignment: .bottom) {
        Capsule().fill(Color.white.opacity(0.15)).frame(width: 4)
        Capsule().fill(PreviewTheme.accent).frame(width: 4, height: max(0, t * height))
        Circle().fill(.white).frame(width: 22, height: 22).shadow(radius: 2)
          .offset(y: -t * (height - 22))
      }
      .frame(width: 44, height: height)
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0).onChanged { g in
        let f = Float(1 - max(0, min(1, (g.location.y - 11) / (height - 22))))
        model.cutHeight = range.lowerBound + f * (range.upperBound - range.lowerBound)
      })
      Text(String(format: "%.1f m", model.cutHeight)).font(.caption2.weight(.semibold)).monospacedDigit()
    }
    .padding(.vertical, 12)
    .frame(width: 56)
    .glass(Capsule())
  }
}

private struct MeasureBanner: View {
  @ObservedObject var model: PreviewModel
  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "ruler").foregroundStyle(PreviewTheme.accent)
      if let d = model.measureDistance {
        Text(PreviewModel.format(d)).font(.subheadline.weight(.semibold)).monospacedDigit()
        Button { model.clearMeasure() } label: { Image(systemName: "arrow.counterclockwise").font(.caption.weight(.bold)) }
          .foregroundStyle(.secondary)
      } else {
        Text(model.measureA == nil ? "Tap a point on the scan" : "Tap a second point").font(.footnote.weight(.medium))
      }
    }
    .padding(.horizontal, 14)
    .frame(height: 38)
    .glass(Capsule())
  }
}

struct ScanVersionReview: View {
  let house: HouseProject
  let room: HouseProject.Room
  let ref: HouseProject.RoomRef
  let session: HouseProject.Session
  @State private var showingActive = false
  var body: some View {
    let selected = showingActive ? (room.active ?? ref) : ref
    let selectedSession = house.session(selected.session) ?? session
    var source = PreviewSource.session(house, selectedSession)
    let _ = source.rooms = source.rooms.filter { $0.index == selected.index }
    VStack {
      if room.active != ref {
        Picker("Compare versions", selection: $showingActive) {
          Text("Selected scan").tag(false)
          Text("Current scan").tag(true)
        }.pickerStyle(.segmented).padding()
      }
      ScanReview(source: source).id("\(selected.session)-\(selected.index)")
    }.navigationTitle(room.name)
  }
}
