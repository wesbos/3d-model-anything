import Foundation
import simd

/// Review saved observations only; never starts sensors or requests permission.
struct PreviewNorth {
  var vector: SIMD3<Float>
  var reference: String
  var accuracy: Double

  static func load(session: PreviewSession, room: Int) -> PreviewNorth? {
    guard let data = try? Data(contentsOf: session.folder.appendingPathComponent("compass/headings.json")),
          let records = try? JSONDecoder().decode([CompassRecord].self, from: data) else { return nil }
    let valid = records.filter {
      $0.room == room && $0.rejection == nil && $0.headingAccuracy.isFinite &&
      (0...25).contains($0.headingAccuracy) && $0.timestamp.isFinite && $0.frameTimestamp.isFinite &&
      abs($0.timestamp - $0.frameTimestamp) <= 0.15 && (0...0.15).contains($0.poseTimeOffsetSeconds) &&
      $0.northInSession?.count == 3 && $0.northInSession!.allSatisfy { $0.isFinite } &&
      abs($0.northInSession![1]) <= 0.05 &&
      (0.8...1.2).contains(hypot($0.northInSession![0], $0.northInSession![2])) &&
      ["true", "magnetic"].contains($0.reference)
    }
    let trueCount = valid.filter { $0.reference == "true" }.count
    let reference = trueCount >= 3 ? "true" : (trueCount > valid.count - trueCount ? "true" : "magnetic")
    let selected = valid.filter { $0.reference == reference }
    guard selected.count >= 3,
          selected.map(\.timestamp).max()! - selected.map(\.timestamp).min()! >= 1 else { return nil }
    let angles = selected.map { atan2(Double($0.northInSession![0]), -Double($0.northInSession![2])) }
    let weights = selected.map { 1 / pow(max(1, $0.headingAccuracy), 2) }
    func mean(_ indices: [Int]) -> (Double, Double) {
      let x = indices.reduce(0.0) { $0 + sin(angles[$1]) * weights[$1] }
      let z = indices.reduce(0.0) { $0 + cos(angles[$1]) * weights[$1] }
      return (atan2(x, z), hypot(x, z) / indices.reduce(0.0) { $0 + weights[$1] })
    }
    func distance(_ a: Double, _ b: Double) -> Double { abs(atan2(sin(a-b), cos(a-b))) * 180 / .pi }
    let (initial, agreement) = mean(Array(selected.indices))
    let inliers = selected.indices.filter { distance(angles[$0], initial) <= 20 }
    guard agreement >= 0.9, inliers.count >= max(3, Int(ceil(Double(selected.count) * 0.7))) else { return nil }
    let (center, _) = mean(inliers)
    let spread = inliers.map { distance(angles[$0], center) }.max()!
    let accuracy = inliers.map { selected[$0].headingAccuracy }.max()! + spread
    guard spread <= 15, accuracy <= 25 else { return nil }
    let transformed = session.toHouse * SIMD4<Float>(Float(sin(center)), 0, -Float(cos(center)), 0)
    let horizontal = SIMD3<Float>(transformed.x, 0, transformed.z)
    guard horizontal.x.isFinite, horizontal.z.isFinite, simd_length(horizontal) > 0.001 else { return nil }
    return PreviewNorth(vector: simd_normalize(horizontal), reference: reference, accuracy: accuracy)
  }
}
