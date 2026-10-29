import SwiftUI

/// Debug entry points for the 3D preview (launch arguments), so it can be tested without going
/// through the house screens:
///
///     -preview-house <folder>     open a house folder (house.json);
///                                 relative paths resolve against Documents (e.g. "Houses/Test")
///     -preview-session <n>        with a house: open session n (SessionViewer) instead of the house
///     -preview-room <id>          show only this room ("<session index>/<room index>", e.g. 1/0)
///     -preview-style <name>       photo | coverage | sessions | clay | wireframe | roomPlan
///     -preview-plan               start in the top-down plan view
///     -preview-walk <n>           start the walkthrough at photo n
///     -preview-opacity <0…1>      photo overlay opacity in the walkthrough
///     -preview-measure x1,y1,x2,y2  tap two screen points (points) in measure mode
///     -preview-bench              spin the camera for 4 s and log the frame rate
///     -preview-stats              show vertex/triangle counts, load time and fps
///
/// Log lines go to the console and `Documents/preview-debug.log`.
enum PreviewDebug {
  private static var args: [String] { ProcessInfo.processInfo.arguments }

  private static func value(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
  }

  /// The view to show instead of the home screen, when launched with `-preview-house`.
  /// App entry: `if let preview = PreviewDebug.launchView() { preview } else { … }`
  @MainActor static func launchView() -> AnyView? {
    #if DEBUG
    // Open the real Fieldwork room screen against simulator fixtures for visual checks.
    if let houseID = value("-fieldwork-house"), let roomID = value("-fieldwork-room") {
      return AnyView(NavigationStack {
        FieldworkRoomScreen(houseID: houseID, roomID: roomID, generation: 0, onCapture: { _, _, _, _ in })
      }.tint(Fieldwork.orange))
    }
    #endif
    guard let path = value("-preview-house") else { return nil }
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : docs.appendingPathComponent(path, isDirectory: true)
    try? FileManager.default.removeItem(at: logURL)
    do {
      let house = try HouseProject.load(url: url)
      log("house \(house.name): \(house.sessions.count) sessions, \(house.rooms.count) rooms")
      if let n = value("-preview-session").flatMap(Int.init), house.sessions.indices.contains(n) {
        return AnyView(SessionViewer(house: house, session: house.sessions[n]))
      }
      return AnyView(HouseViewer(house: house))
    } catch {
      log("can't read \(url.path)/house.json: \(error)")
      return AnyView(Text("Can't read house.json: \(error.localizedDescription)").padding())
    }
  }

  /// Applies the remaining debug arguments once the preview has loaded
  @MainActor static func didLoad(_ model: PreviewModel) {
    guard value("-preview-house") != nil else { return }
    log("ready: styles \(model.styles.map(\.rawValue).joined(separator: ","))")
    if let r = value("-preview-room") { model.showOnly(r) }
    if let s = value("-preview-style").flatMap(RenderStyle.init(rawValue:)) { model.setStyle(s) }
    if args.contains("-preview-plan") { model.togglePlan() }
    if let o = value("-preview-opacity").flatMap(Double.init) { model.photoOpacity = o }
    if let n = value("-preview-walk").flatMap(Int.init) {
      model.toggleWalkthrough()
      model.go(to: n)
    }
    if let m = value("-preview-measure") {
      let v = m.split(separator: ",").compactMap { Double($0) }
      if v.count == 4 {
        model.toggleMeasure()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
          model.debugTap(CGPoint(x: v[0], y: v[1]))
          model.debugTap(CGPoint(x: v[2], y: v[3]))
        }
      }
    }
    if args.contains("-preview-hitgrid") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        var line = ""
        for y in stride(from: 300, through: 700, by: 50) {
          for x in stride(from: 50, through: 350, by: 50) { line += model.scene.hitMesh(at: CGPoint(x: x, y: y)) == nil ? "." : "#" }
          line += "|"
        }
        log("hitgrid \(line)")
      }
    }
    if args.contains("-preview-bench") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.measureFPS() }
    }
  }

  private static let logURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("preview-debug.log")
  private static let logLock = NSLock()

  static func log(_ s: String) {
    print("[preview] \(s)")
    logLock.withLock {
      let line = Data("\(Date().formatted(.iso8601)) \(s)\n".utf8)
      if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        h.write(line)
        try? h.close()
      } else {
        try? line.write(to: logURL)
      }
    }
  }
}
