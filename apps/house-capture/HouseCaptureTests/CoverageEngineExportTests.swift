import XCTest
import simd
@testable import HouseCapture

final class CoverageEngineExportTests: XCTestCase {
  private func export(_ engine: CoverageEngine, to url: URL) async throws {
    let result = await withCheckedContinuation { continuation in
      engine.exportPLY(to: url) { continuation.resume(returning: $0) }
    }
    _ = try result.get()
  }

  /// Re-exporting a room's mesh must not truncate the previous file if the app dies mid-write.
  func testReexportingTheMeshReplacesTheFileInsteadOfRewritingItInPlace() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-\(UUID()).ply")
    defer { try? FileManager.default.removeItem(at: url) }
    let engine = CoverageEngine()
    engine.update(snapshot: .init(id: UUID(), transform: matrix_identity_float4x4,
      positions: [SIMD3(0, 0, 0), SIMD3(0.1, 0, 0), SIMD3(0, 0.1, 0)],
      normals: Array(repeating: SIMD3(0, 0, 1), count: 3), faces: [0, 1, 2], classes: [1]))
    try await export(engine, to: url)
    let before = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int

    try await export(engine, to: url)

    XCTAssertNotEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int, before)
  }
}
