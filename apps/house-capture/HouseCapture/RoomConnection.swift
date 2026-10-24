import SwiftUI
import simd

struct RoomDoor: Identifiable {
  let id: String
  let width: Float
  let transform: simd_float4x4
  static func load(house: HouseProject, room: HouseProject.Room) -> [RoomDoor] {
    RoomJSON.load(house: house, room: room).map(parse) ?? []
  }
  static func parse(_ json: [String: Any]) -> [RoomDoor] {
    (["doors", "openings"].flatMap { json[$0] as? [[String: Any]] ?? [] }).compactMap { d in
      guard let t = RoomJSON.floats(d["transform"]), t.count == 16,
            let width = RoomJSON.floats(d["dimensions"])?.first,
            let id = d["identifier"] as? String else { return nil }
      return .init(id: id, width: width, transform: simd_float4x4(columnMajor: t))
    }
  }
}

/// RoomPlan's saved CapturedRoom JSON, read untyped for the doorway tools.
enum RoomJSON {
  static func load(house: HouseProject, room: HouseProject.Room) -> [String: Any]? {
    guard let ref = room.active, let session = house.session(ref.session),
          let data = try? Data(contentsOf: house.bundle(for: session).file("rooms/room-\(ref.index).json")) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }
  /// JSONSerialization numbers are NSNumbers holding Doubles, and `as? [Float]` rejects any
  /// value a Float can't hold exactly (-0.7317813 included), so read NSNumber and narrow.
  static func floats(_ value: Any?) -> [Float]? { (value as? [NSNumber])?.map(\.floatValue) }
  /// Wall centre lines on the floor plane (x, z)
  static func wallSegments(_ json: [String: Any]) -> [(SIMD2<Float>, SIMD2<Float>)] {
    (json["walls"] as? [[String: Any]] ?? []).compactMap { w in
      guard let t = floats(w["transform"]), t.count == 16, let width = floats(w["dimensions"])?.first else { return nil }
      let center = SIMD2(t[12], t[14]), half = SIMD2(t[0], t[2]) * width / 2
      return (center-half, center+half)
    }
  }
}

/// Doorway correspondence is user-verified; never silently treat separate maps as aligned.
struct RoomConnection: View {
  let house: HouseProject
  let source: HouseProject.Room
  let onSave: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var targetID = ""
  @State private var sourceDoorID = ""
  @State private var targetDoorID = ""
  @State private var flip = true
  @State private var previewing = false
  @State private var checked = false
  @State private var error: String?
  private var target: HouseProject.Room? { house.rooms.first { $0.id == targetID } }
  private var sourceDoors: [RoomDoor] { RoomDoor.load(house: house, room: source) }
  private var targetDoors: [RoomDoor] { target.map { RoomDoor.load(house: house, room: $0) } ?? [] }
  private var candidate: HouseProject? {
    guard let target, let sr = source.active, let tr = target.active,
          let ss = house.session(sr.session), let ts = house.session(tr.session), ss.zone != ts.zone,
          let sd = sourceDoors.first(where: { $0.id == sourceDoorID }),
          let td = targetDoors.first(where: { $0.id == targetDoorID }), abs(sd.width-td.width) < 0.2,
          let zi = house.zones.firstIndex(where: { $0.id == ss.zone }), house.zone(ts.zone)?.aligned == true,
          ts.alignment.method != "unaligned", ss.alignment.method != "unaligned" else { return nil }
    let turn = simd_float4x4(simd_quatf(angle: flip ? .pi : 0, axis: SIMD3(0,1,0)))
    let transform = house.toHouse(ts) * td.transform * turn * sd.transform.inverse * simd_float4x4(columnMajor: ss.alignment.toZone).inverse
    var result = house
    result.zones[zi].toHouse = transform.columnMajor
    result.zones[zi].aligned = true
    return result
  }
  var body: some View {
    Form {
      Section {
        Text("Match the same doorway in two rooms. If it wasn't captured in both scans, continue scanning from a saved room and include both sides of the doorway.")
        Picker("Connect \(source.name) to", selection: $targetID) {
          Text("Choose room").tag("")
          ForEach(house.rooms.filter { $0.id != source.id }) { Text($0.name).tag($0.id) }
        }
        DoorwayMap(house: house, room: source, doors: sourceDoors, selected: $sourceDoorID)
        doorPicker("Doorway in \(source.name)", doors: sourceDoors, selection: $sourceDoorID)
        if let target { DoorwayMap(house: house, room: target, doors: targetDoors, selected: $targetDoorID) }
        doorPicker("Doorway in other room", doors: targetDoors, selection: $targetDoorID)
        Text("Tap the matching doorway numbers on each room plan. Widths help distinguish similar openings.").font(.caption)
        Toggle("Rooms face opposite sides of doorway", isOn: $flip)
        if target?.zone == source.zone { Text("These rooms already share a tracking frame.") }
        if let target, house.zone(target.zone)?.aligned != true { Text("Choose a room already placed in the house as the reference.") }
        if sourceDoors.isEmpty || (target != nil && targetDoors.isEmpty) { Text("A doorway is missing. Capture a connecting hallway or doorway before joining these rooms.") }
        if candidate == nil { Text("Choose compatible doorways (within 20 cm in width) in separately captured rooms with established tracking.").font(.caption) }
        Button("Preview connection") { previewing = true; checked = true }.disabled(candidate == nil)
        Text("Check walls, floor levels, and which side of the doorway each room occupies. This is a manual placement, not an automatic match.").font(.caption)
        let companions = house.rooms.filter { $0.zone == source.zone && $0.id != source.id }.map(\.name)
        if !companions.isEmpty { Text("Also moves with this room: " + companions.joined(separator: ", ")).font(.caption) }
        Button("Save connection") {
          guard let candidate, let ref = source.active, let session = house.session(ref.session), let zone = candidate.zone(session.zone) else { return }
          do {
            try HouseProject.modify(house.id) { h in
              guard let i = h.zones.firstIndex(where: { $0.id == zone.id }) else { return }
              h.zones[i].toHouse = zone.toHouse; h.zones[i].aligned = true
            }
            onSave(); dismiss()
          } catch { self.error = error.localizedDescription }
        }.disabled(!checked || candidate == nil)
        if let error { Text(error).foregroundStyle(.red) }
      }
    }
    .navigationTitle("Connect rooms")
    .onChange(of: targetID) { _, _ in targetDoorID = ""; checked = false }
    .onChange(of: sourceDoorID) { _, _ in checked = false }
    .onChange(of: targetDoorID) { _, _ in checked = false }
    .onChange(of: flip) { _, _ in checked = false }
    .sheet(isPresented: $previewing) {
      if let candidate { NavigationStack { HouseViewer(house: candidate).toolbar { Button("Done") { previewing = false } } } }
    }
  }
  private func doorPicker(_ title: String, doors: [RoomDoor], selection: Binding<String>) -> some View {
    Picker(title, selection: selection) {
      Text("Choose doorway").tag("")
      ForEach(Array(doors.enumerated()), id: \.element.id) { i, door in
        Text(String(format: "Doorway %d · %.2f m wide", i+1, door.width)).tag(door.id)
      }
    }
  }
}

private struct DoorwayMap: View {
  let house: HouseProject
  let room: HouseProject.Room
  let doors: [RoomDoor]
  @Binding var selected: String
  private var segments: [(SIMD2<Float>, SIMD2<Float>)] {
    RoomJSON.load(house: house, room: room).map(RoomJSON.wallSegments) ?? []
  }
  var body: some View {
    let lines = segments
    let points = lines.flatMap { [$0.0, $0.1] } + doors.map { SIMD2($0.transform.columns.3.x, $0.transform.columns.3.z) }
    let lo = points.reduce(SIMD2<Float>(repeating: .infinity)) { simd_min($0,$1) }
    let hi = points.reduce(SIMD2<Float>(repeating: -.infinity)) { simd_max($0,$1) }
    GeometryReader { geo in
      let scale = min(Float(geo.size.width-40)/max(hi.x-lo.x,1), Float(geo.size.height-40)/max(hi.y-lo.y,1))
      let project: (SIMD2<Float>) -> CGPoint = { p in CGPoint(x: CGFloat((p.x-(lo.x+hi.x)/2)*scale)+geo.size.width/2, y: CGFloat((p.y-(lo.y+hi.y)/2)*scale)+geo.size.height/2) }
      ZStack {
        Canvas { context, _ in
          for line in lines {
            var path = Path(); path.move(to: project(line.0)); path.addLine(to: project(line.1))
            context.stroke(path, with: .color(.secondary), lineWidth: 3)
          }
        }
        ForEach(Array(doors.enumerated()), id: \.element.id) { i, door in
          Button("\(i+1)") { selected = door.id }
            .font(.caption.bold()).frame(width: 28, height: 28)
            .background(selected == door.id ? Color.green : Color.blue, in: Circle()).foregroundStyle(.white)
            .position(project(SIMD2(door.transform.columns.3.x, door.transform.columns.3.z)))
            .buttonStyle(.plain)
        }
      }
    }.frame(height: points.isEmpty ? 0 : 180).accessibilityLabel("Doorway plan for \(room.name)")
  }
}
