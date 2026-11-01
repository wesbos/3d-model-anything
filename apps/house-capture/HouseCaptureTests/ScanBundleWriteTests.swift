import XCTest
@testable import HouseCapture

/// A crash or power loss while rewriting an index must leave the previous file intact.
/// Atomic writes go through a temporary file renamed over the destination, so the
/// destination's file identity changes; an in-place rewrite keeps it.
final class ScanBundleWriteTests: XCTestCase {
  private var folder: URL!

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    for sub in ScanBundle.subfolders {
      try FileManager.default.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: folder)
  }

  private func fileNumber(_ url: URL) throws -> Int {
    try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
  }

  private func photo(room: Int) -> PhotoRecord {
    PhotoRecord(file: "photos/0000.jpg", room: room, timestamp: 0, width: 1920, height: 1440,
                transform: Array(repeating: 0, count: 16), intrinsics: Array(repeating: 0, count: 9),
                tracking: "normal", manual: false)
  }

  func testSavingPhotosReplacesTheIndexInsteadOfRewritingItInPlace() throws {
    let bundle = ScanBundle(url: folder)
    try bundle.savePhotos([photo(room: 0)])
    let before = try fileNumber(bundle.file("photos/photos.json"))

    try bundle.savePhotos([photo(room: 0), photo(room: 1)])

    XCTAssertNotEqual(try fileNumber(bundle.file("photos/photos.json")), before)
    XCTAssertEqual(bundle.photos.count, 2)
  }
}
