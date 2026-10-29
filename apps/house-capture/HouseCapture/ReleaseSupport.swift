import SwiftUI
import AVFoundation

struct CaptureReadinessError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

enum CaptureReadiness {
  static let reserve: Int64 = 500_000_000
  static let pauseReserve: Int64 = 200_000_000
  static func available(at url: URL) -> Int64? {
    try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
  }
  static func requireStorage(at url: URL, bytes: Int64 = reserve) throws {
    try checkStorage(available: available(at: url), required: bytes)
  }
  static func checkStorage(available: Int64?, required: Int64) throws {
    if let available, available < required {
      throw CaptureReadinessError(message: "Not enough storage. Free at least \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)) on this device, then try again. Saved scans are kept.")
    }
  }
  @MainActor static func prepare() async throws {
    guard CaptureController.isSupported else {
      throw CaptureReadinessError(message: "Scanning needs a LiDAR-equipped iPhone Pro or iPad Pro. You can import, view and share existing scans on this device.")
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: break
    case .notDetermined:
      guard await AVCaptureDevice.requestAccess(for: .video) else {
        throw CaptureReadinessError(message: "Camera access is off. Enable Camera for 3D Model Anything in Settings, then try scanning again.")
      }
    case .denied:
      throw CaptureReadinessError(message: "Camera access is off. Enable Camera for 3D Model Anything in Settings, then try scanning again.")
    case .restricted:
      throw CaptureReadinessError(message: "Camera access is restricted on this device. Check Screen Time or device-management restrictions. You can still import and view scans.")
    @unknown default:
      throw CaptureReadinessError(message: "Camera access is unavailable. You can still import and view scans.")
    }
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    try requireStorage(at: docs)
  }
}

struct HelpDocument: Decodable {
  struct Section: Decodable, Identifiable {
    let title: String
    let body: String
    var id: String { title }
  }
  let title: String
  let updated: String
  let sections: [Section]
  static func load(_ name: String) -> HelpDocument? {
    guard let url = Bundle.main.url(forResource: name, withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(Self.self, from: data)
  }
}

struct HelpDocumentView: View {
  let resource: String
  var body: some View {
    ScrollView {
      if let document = HelpDocument.load(resource) {
        VStack(alignment: .leading, spacing: 24) {
          Text(document.title).font(.largeTitle.bold())
          FieldworkEyebrow(text: "Updated \(document.updated)")
          ForEach(document.sections) { section in
            VStack(alignment: .leading, spacing: 8) {
              Text(section.title).font(.headline)
              Text(section.body).foregroundStyle(Fieldwork.secondary).textSelection(.enabled)
            }
          }
        }.padding(24).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
      } else {
        ContentUnavailableView("Help is unavailable", systemImage: "doc.text", description: Text("Please reinstall the app update to restore its bundled help."))
      }
    }.background(Fieldwork.paper).foregroundStyle(Fieldwork.ink)
  }
}

struct AppHelpScreen: View {
  private func publicURL(_ key: String) -> URL? {
    guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
          let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
    return url
  }
  var body: some View {
    List {
      Section("3D Model Anything") {
        NavigationLink("Scanning, importing & sharing") { HelpDocumentView(resource: "Support") }
        NavigationLink("Privacy policy") { HelpDocumentView(resource: "PrivacyPolicy") }
        if let url = publicURL("HouseCapturePrivacyURL") { Link("Privacy policy online", destination: url) }
        if let url = publicURL("HouseCaptureSupportURL") { Link("Contact support", destination: url) }
      }
      Section("Permissions") {
        Text("The camera is used while capturing rooms. Record compass directions is optional and off for every new session. Enabling it requests Location for true-north labels; geographic coordinates are not saved. Importing and reviewing saved scans does not require these permissions.")
        Button("Open app settings") {
          if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
      }
      Section("About") {
        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))")
        Text("Scans are approximate. Verify measurements before construction or other precision work.").font(.footnote)
      }
    }
    .scrollContentBackground(.hidden).background(Fieldwork.paper)
    .navigationTitle("Help & privacy").navigationBarTitleDisplayMode(.inline)
  }
}
