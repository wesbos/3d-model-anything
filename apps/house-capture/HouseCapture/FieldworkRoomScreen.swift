import SwiftUI

struct FieldworkRoomScreen: View {
  let houseID: String
  let roomID: String
  let generation: Int
  let onCapture: (String, String?, String?, String?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var house: HouseProject?
  @State private var manifests: [String: Manifest] = [:]
  @State private var sharing: URL?
  @State private var busy = false
  @State private var error: String?
  @State private var renaming = false
  @State private var name = ""
  @State private var deleting = false
  @State private var deletingScan: HouseProject.RoomRef?
  @State private var historyOpen = false
  private var room: HouseProject.Room? { house?.rooms.first { $0.id == roomID } }

  var body: some View {
    ScrollView {
      if let house, let room {
        VStack(alignment: .leading, spacing: 22) {
          VStack(alignment: .leading, spacing: 10) {
            FieldworkEyebrow(text: "Saved room")
            Text(room.name).font(.largeTitle.weight(.bold)).tracking(-1)
            if let active = room.active {
              Text("SCANNED " + active.capturedAt.formatted(date: .abbreviated, time: .shortened).uppercased())
                .font(.system(.caption, design: .monospaced)).foregroundStyle(Fieldwork.secondary)
            }
          }
          if let active = room.active, let session = house.session(active.session) {
            FieldworkRoomPreview(source: source(house, room, session, active))
              .id("\(active.session)/\(active.index)")
            let record = manifests[active.session]?.rooms.first { $0.index == active.index }
            HStack(alignment: .top, spacing: 28) {
              metric(record?.photographedPercent.map { "\($0)%" } ?? "—", label: "photo detail")
              Rectangle().fill(Fieldwork.rule).frame(width: 0.5, height: 42)
              metric(record?.detailPhotos.map(String.init) ?? "—", label: "detail photos")
              Spacer(minLength: 0)
            }
            VStack(spacing: 10) {
              Button { share(house.bundle(for: session), active.index, room.name) } label: {
                Label(busy ? "Preparing room…" : "Share room", systemImage: "square.and.arrow.up")
              }.buttonStyle(FieldworkButtonStyle()).disabled(busy)
              Button { onCapture(house.id, room.zone, nil, room.id) } label: {
                Label("Continue scanning", systemImage: "viewfinder")
              }.buttonStyle(FieldworkButtonStyle(filled: false)).disabled(!CaptureController.isSupported || busy)
              Text("Start in this room so the device can recognize your surroundings.")
                .font(.caption).foregroundStyle(Fieldwork.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            FieldworkRule()
            DisclosureGroup(isExpanded: $historyOpen) {
              history(house, room)
            } label: {
              Label {
                VStack(alignment: .leading, spacing: 4) {
                  Text("Scan history").foregroundStyle(Fieldwork.ink)
                  Text("\(room.history.count) saved scan\(room.history.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(Fieldwork.secondary)
                }
              } icon: { Image(systemName: "clock").foregroundStyle(Fieldwork.secondary).frame(width: 28) }
            }.padding(.vertical, 4)
            FieldworkRule()
            NavigationLink {
              RoomConnection(house: house, source: room, onSave: reload)
            } label: { actionRow("Connect room", subtitle: "Match a doorway with another scan", icon: "link") }
            FieldworkRule()
            Text("Photo detail measures useful photography on observed surfaces. It is not the percentage of the room scanned.")
              .font(.caption).foregroundStyle(Fieldwork.secondary)
          } else {
            ContentUnavailableView("No active scan", systemImage: "cube.transparent", description: Text("Scan this room to create its first preview."))
            Button("Scan this room") { onCapture(house.id, room.zone, nil, room.id) }
              .buttonStyle(FieldworkButtonStyle()).disabled(!CaptureController.isSupported)
          }
        }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 32)
          .frame(maxWidth: 820).frame(maxWidth: .infinity)
      } else { ProgressView().padding(40) }
    }
    .background(Fieldwork.paper).foregroundStyle(Fieldwork.ink)
    .navigationTitle("").navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) { FieldworkEyebrow(text: house?.name ?? "3D Model Anything") }
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button("Rename room", systemImage: "pencil") { name = room?.name ?? ""; renaming = true }
          Button("Delete room", systemImage: "trash", role: .destructive) { deleting = true }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Room options")
      }
    }
    .onAppear(perform: reload).onChange(of: generation) { _, _ in reload() }
    .sheet(item: $sharing) { ShareSheet(items: [$0]) }
    .alert("Rename room", isPresented: $renaming) {
      TextField("Room name", text: $name)
      Button("Save") { perform { try HouseProject.renameRoom(houseID: houseID, roomID: roomID, name: name) } }
      Button("Cancel", role: .cancel) {}
    }
    .confirmationDialog("Move room to Recently Deleted?", isPresented: $deleting, titleVisibility: .visible) {
      Button("Delete room", role: .destructive) {
        perform { try HouseProject.moveRoomToTrash(houseID: houseID, roomID: roomID) }
      }
    } message: { Text("You can restore this room and its scans from the house's Recently Deleted section.") }
    .confirmationDialog("Move this scan to Recently Deleted?", isPresented: Binding(get: { deletingScan != nil }, set: { if !$0 { deletingScan = nil } }), titleVisibility: .visible) {
      Button("Delete scan", role: .destructive) {
        if let ref = deletingScan { perform { try HouseProject.deleteScan(houseID: houseID, roomID: roomID, ref: ref) } }
        deletingScan = nil
      }
    }
    .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("OK") { error = nil }
    } message: { Text(error ?? "") }
  }

  private func metric(_ value: String, label: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(value).font(.title2.bold()).monospacedDigit()
      Text(label).font(.system(.caption, design: .monospaced)).foregroundStyle(Fieldwork.secondary)
    }
  }
  private func actionRow(_ title: String, subtitle: String, icon: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon).frame(width: 28).font(.title3)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.body)
        Text(subtitle).font(.caption).foregroundStyle(Fieldwork.secondary)
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.right").font(.caption).foregroundStyle(Fieldwork.secondary)
    }.foregroundStyle(Fieldwork.ink).frame(minHeight: 48).contentShape(Rectangle())
  }
  private func source(_ house: HouseProject, _ room: HouseProject.Room, _ session: HouseProject.Session, _ ref: HouseProject.RoomRef) -> PreviewSource {
    var source = PreviewSource.session(house, session)
    source.title = room.name
    source.rooms = source.rooms.filter { $0.index == ref.index }
    return source
  }
  private func history(_ house: HouseProject, _ room: HouseProject.Room) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      ForEach(Array(room.history.reversed().enumerated()), id: \.offset) { _, ref in
        VStack(alignment: .leading, spacing: 10) {
          Text(ref.capturedAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline.weight(.semibold))
          if ref == room.active { Label("Active scan", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Fieldwork.orange) }
          ViewThatFits(in: .horizontal) {
            HStack { versionActions(house, room, ref) }
            VStack(alignment: .leading) { versionActions(house, room, ref) }
          }
        }
        FieldworkRule()
      }
    }.padding(.top, 18)
  }
  @ViewBuilder private func versionActions(_ house: HouseProject, _ room: HouseProject.Room, _ ref: HouseProject.RoomRef) -> some View {
    if let session = house.session(ref.session) {
      NavigationLink("Inspect / compare") { ScanVersionReview(house: house, room: room, ref: ref, session: session) }
        .buttonStyle(.bordered)
    }
    if ref != room.active {
      Button("Use this scan") { perform { _ = try HouseProject.modify(houseID) { $0.setActive(room: roomID, ref) } } }.buttonStyle(.bordered)
    }
    Button(role: .destructive) { deletingScan = ref } label: { Image(systemName: "trash").frame(minWidth: 32, minHeight: 32) }
      .accessibilityLabel("Delete scan from \(ref.capturedAt.formatted())")
  }
  private func reload() {
    do {
      let h = try HouseProject.load(id: houseID)
      guard h.rooms.contains(where: { $0.id == roomID }) else { dismiss(); return }
      house = h
      Task {
        let records = await Task.detached(priority: .utility) { h.sessions.reduce(into: [String: Manifest]()) { $0[$1.id] = h.bundle(for: $1).manifest } }.value
        manifests = records
      }
    } catch { self.error = error.localizedDescription }
  }
  private func perform(_ action: () throws -> Void) {
    do { try action(); reload() } catch { self.error = error.localizedDescription }
  }
  private func share(_ bundle: ScanBundle, _ index: Int, _ name: String) {
    busy = true
    Task {
      let result = await Task.detached(priority: .userInitiated) { Result { try bundle.zippedRoom(index: index, name: name) } }.value
      busy = false
      switch result {
      case .success(let url): sharing = url
      case .failure(let err): error = err.localizedDescription
      }
    }
  }
}

private struct FieldworkRoomPreview: View {
  @Environment(\.horizontalSizeClass) private var sizeClass
  @StateObject private var model: PreviewModel
  @State private var coverage = false
  @State private var expanded = false
  init(source: PreviewSource) { _model = StateObject(wrappedValue: PreviewModel(source: source)) }
  var body: some View {
    VStack(spacing: 12) {
      Picker("Preview style", selection: $coverage) {
        Text("3D").tag(false)
        Text("Photo detail").tag(true)
      }.pickerStyle(.segmented).disabled(model.phase != .ready || !model.styles.contains(.coverage))
      ZStack {
        if !expanded { PreviewSceneView(scene: model.scene) }
        switch model.phase {
        case .loading: ProgressView(model.loadStage).font(.caption).padding().background(Fieldwork.paper.opacity(0.95))
        case .empty(let message): ContentUnavailableView("No preview yet", systemImage: "cube.transparent", description: Text(message))
        case .ready: EmptyView()
        }
      }
      .frame(height: sizeClass == .regular ? 420 : 280).clipped()
      .overlay(FieldworkCorners().stroke(Fieldwork.orange, lineWidth: 1.5).allowsHitTesting(false))
      HStack {
        Text(coverage ? "Green surfaces have useful photos" : "Drag to rotate · pinch to zoom")
          .font(.caption).foregroundStyle(Fieldwork.secondary)
        Spacer()
        Button {
          model.scene.scene.background.contents = UIColor(white: 0.07, alpha: 1)
          model.scene.view.backgroundColor = .black
          expanded = true
        } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44) }
          .accessibilityLabel("Open full screen viewer")
      }
    }
    .onAppear { paperBackground(); model.start() }
    .onDisappear { if !expanded { model.cancelBake() } }
    .onChange(of: coverage) { _, value in model.setStyle(value ? .coverage : .photo) }
    .fullScreenCover(isPresented: $expanded, onDismiss: {
      paperBackground()
      coverage = model.style == .coverage
      if !coverage, model.styles.contains(.photo) { model.setStyle(.photo) }
    }) { PreviewScreen(model: model) }
  }
  private func paperBackground() {
    model.scene.scene.background.contents = Fieldwork.uiPaper
    model.scene.view.backgroundColor = Fieldwork.uiPaper
  }
}
