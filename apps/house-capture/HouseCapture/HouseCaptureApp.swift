import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

@main
struct HouseCaptureApp: App {
  var body: some Scene {
    WindowGroup {
      #if DEBUG
      let args = ProcessInfo.processInfo.arguments
      if let preview = PreviewDebug.launchView() {
        preview // -preview-house <folder> (see PreviewDebug.swift)
      } else if args.contains("-diag") {
        DiagnosticsView()
      } else if args.contains("-selftest") {
        SelfTestView()
      } else if args.contains("-autotest") || args.contains("-autotest-continue") {
        AutoTestView(continueLatest: args.contains("-autotest-continue"))
      } else {
        HomeView()
      }
      #else
      HomeView()
      #endif
    }
  }
}

/// Houses scanned over several sessions
struct HomeView: View {
  @State private var houses: [HouseProject] = []
  @State private var path: [String] = [] // house ids
  @State private var capture: CaptureController?
  @State private var error: String?
  @State private var naming = false
  @State private var importing = false
  @State private var importHelp = false
  @State private var chooseImportFolder = false
  @State private var working = false
  @State private var newName = ""
  @State private var deleting: HouseProject?
  /// bumped when a capture closes so the house screen reloads
  @State private var generation = 0
  @State private var openedFromArgs = false

  var body: some View {
    NavigationStack(path: $path) {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          VStack(alignment: .leading, spacing: 14) {
            FieldworkEyebrow(text: "A record of your spaces")
            Text("3D Model Anything").font(.largeTitle.weight(.bold)).tracking(-1)
            Text("Room by room. Every detail.").font(.title3).foregroundStyle(Fieldwork.secondary)
          }.padding(.top, 20).padding(.bottom, 36)
          FieldworkRule()
          if houses.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
              Image(systemName: "house.lodge").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(Fieldwork.orange)
              Text(CaptureController.isSupported ? "Start with a space you know." : "Explore a shared scan.").font(.title2.bold())
              Text(CaptureController.isSupported ? "Create a house, then scan your first room. Your scans and photos stay saved on this device." : "Import a room shared from 3D Model Anything to explore its 3D scan and photos. No camera access needed.")
                .foregroundStyle(Fieldwork.secondary)
            }.padding(.vertical, 40)
          }
          ForEach(Array(houses.enumerated()), id: \.element.id) { number, house in
            NavigationLink(value: house.id) {
              VStack(alignment: .leading, spacing: 14) {
                HStack {
                  FieldworkEyebrow(text: String(format: "%02d / HOUSE", number + 1))
                  Spacer()
                  Image(systemName: "arrow.up.right").foregroundStyle(Fieldwork.orange)
                }
                HouseRow(house: house)
                if let active = house.rooms.first?.active, let session = house.session(active.session) {
                  FieldworkThumbnail(folder: house.bundle(for: session).url, index: active.index).frame(height: 180).frame(maxWidth: .infinity)
                }
              }.padding(.vertical, 24).contentShape(Rectangle())
            }.buttonStyle(.plain)
            .contextMenu {
              Button("Delete house", systemImage: "trash", role: .destructive) { deleting = house }
            }
            FieldworkRule()
          }
          if !CaptureController.isSupported {
            Text("Scanning requires an iPhone or iPad with LiDAR. Import an extracted room folder to view and share scans on this device.")
              .font(.footnote).foregroundStyle(Fieldwork.secondary).padding(.vertical, 24)
          }
        }.padding(.horizontal, 24).padding(.bottom, 24)
      }
      .disabled(working)
      .overlay { if working { ProgressView("Preparing…").padding(24).background(Fieldwork.paper, in: RoundedRectangle(cornerRadius: 12)) } }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button { importHelp = true } label: { Image(systemName: "square.and.arrow.down").frame(width: 44, height: 44) }
            .accessibilityLabel("Import room folder").disabled(working)
        }
        ToolbarItem(placement: .topBarTrailing) {
          NavigationLink { AppHelpScreen() } label: { Image(systemName: "questionmark.circle").frame(width: 44, height: 44) }.accessibilityLabel("Help and privacy")
        }
      }
      .sheet(isPresented: $importHelp, onDismiss: {
        if chooseImportFolder { chooseImportFolder = false; importing = true }
      }) {
        NavigationStack {
          ScrollView {
            VStack(alignment: .leading, spacing: 24) {
              Text("Import a shared room").font(.largeTitle.bold())
              Label("Save the shared ZIP to Files.", systemImage: "1.circle")
              Label("Tap the ZIP in Files to unzip it.", systemImage: "2.circle")
              Label("Choose the extracted folder containing manifest.json.", systemImage: "3.circle")
              Text("Choose a room or session export. Whole-house imports aren’t supported yet. Your original files stay untouched.").foregroundStyle(Fieldwork.secondary)
              Button("Choose extracted folder") { chooseImportFolder = true; importHelp = false }
                .buttonStyle(FieldworkButtonStyle())
            }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
          }.background(Fieldwork.paper)
            .toolbar { Button("Done") { importHelp = false } }
        }.tint(Fieldwork.orange)
      }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
        switch result {
        case .success(let url): importFolder(url)
        case .failure(let e): error = e.localizedDescription
        }
      }
      .background(Fieldwork.paper).foregroundStyle(Fieldwork.ink)
      .navigationTitle("").navigationBarTitleDisplayMode(.inline)
      .safeAreaInset(edge: .bottom) {
        Button {
          if CaptureController.isSupported {
            newName = houses.isEmpty ? "Our house" : ""
            naming = true
          } else { importHelp = true }
        } label: {
          Label(CaptureController.isSupported ? "New house" : "Import a room",
                systemImage: CaptureController.isSupported ? "plus" : "square.and.arrow.down")
        }
          .buttonStyle(FieldworkButtonStyle()).disabled(working)
          .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 10).background(Fieldwork.paper)
      }
      .navigationDestination(for: String.self) { id in
        HouseScreen(houseID: id, generation: generation, onCapture: startCapture, onGone: { path.removeAll() })
      }
      .onAppear(perform: reload)
      .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
        Button("OK") { error = nil }
        if AVCaptureDevice.authorizationStatus(for: .video) == .denied {
          Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
          }
        }
      } message: {
        Text(error ?? "")
      }
      .alert("New house", isPresented: $naming) {
        TextField("Name", text: $newName)
        Button("Create and scan", action: createHouse)
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Then scan your first room. You can add more rooms later.")
      }
      .confirmationDialog("Delete \(deleting?.name ?? "house")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
        Button("Delete house and all its scans", role: .destructive) {
          if let h = deleting {
            do { try h.delete() } catch { self.error = error.localizedDescription }
          }
          deleting = nil
          reload()
        }
      } message: {
        Text("This removes every session, photo and mesh of this house from this device.")
      }
      .fullScreenCover(item: $capture, onDismiss: captureClosed) { controller in
        CaptureScreen(controller: controller) { capture = nil }
      }
    }
    .tint(Fieldwork.orange)
    .preferredColorScheme(.light)
    .toolbarBackground(Fieldwork.paper, for: .navigationBar)
    .toolbarBackground(.visible, for: .navigationBar)
  }

  private func reload() {
    houses = HouseProject.all()
    // `-house <id>`: open that house directly (screenshots, debugging)
    let args = ProcessInfo.processInfo.arguments
    if path.isEmpty, !openedFromArgs, let i = args.firstIndex(of: "-house"), i + 1 < args.count {
      openedFromArgs = true
      path = [args[i + 1]]
    }
  }

  private func captureClosed() {
    generation += 1
    reload()
  }

  private func createHouse() {
    guard !working else { return }
    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    working = true
    Task {
      defer { working = false }
      do {
        try await CaptureReadiness.prepare()
        var house = try HouseProject.create(name: name.isEmpty ? "House" : name)
        let zone = house.addZone(named: "Area 1")
        try house.save()
        reload()
        path = [house.id]
        try? await Task.sleep(for: .milliseconds(450))
        capture = try CaptureController.start(houseID: house.id, zoneID: zone.id)
      } catch { self.error = error.localizedDescription }
    }
  }

  private func startCapture(houseID: String, zoneID: String?, newZone: String?, roomID: String? = nil) {
    guard !working else { return }
    working = true
    Task {
      defer { working = false }
      do {
        try await CaptureReadiness.prepare()
        capture = try CaptureController.start(houseID: houseID, zoneID: zoneID, newZone: newZone)
        if let roomID, let room = try HouseProject.load(id: houseID).rooms.first(where: { $0.id == roomID }) {
          capture?.selectedRoomID = room.id
          capture?.roomName = room.name
        }
      } catch { self.error = error.localizedDescription }
    }
  }

  private func importFolder(_ url: URL) {
    guard !working else { return }
    working = true
    Task {
      defer { working = false }
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      do {
        let id = try await Task.detached(priority: .userInitiated) { try ScanImport.importFolder(url) }.value
        reload(); path = [id]
      } catch { self.error = error.localizedDescription }
    }
  }


}

private struct HouseRow: View {
  let house: HouseProject
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(house.name).font(.title2.bold()).foregroundStyle(Fieldwork.ink)
      Text(summary).font(.footnote).foregroundStyle(.secondary)
    }
  }

  private var summary: String {
    let rooms = house.rooms.count, sessions = house.sessions.count
    var s = "\(rooms) room\(rooms == 1 ? "" : "s") · \(sessions) session\(sessions == 1 ? "" : "s")"
    if house.zones.count > 1 { s += " · \(house.zones.count) areas" }
    if let last = house.sessions.map(\.startedAt).max() { s += " · last \(last.formatted(date: .abbreviated, time: .shortened))" }
    return s
  }
}

struct ShareSheet: UIViewControllerRepresentable {
  let items: [Any]
  func makeCoordinator() -> [URL] { items.compactMap { $0 as? URL } }
  static func dismantleUIViewController(_ controller: UIActivityViewController, coordinator: [URL]) {
    for url in coordinator { FolderZipper.removeArchive(url) }
  }
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: items, applicationActivities: nil)
  }
  func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
  public var id: String { absoluteString }
}

extension CaptureController: Identifiable {}
