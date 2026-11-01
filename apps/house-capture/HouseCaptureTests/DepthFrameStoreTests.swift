import XCTest
@testable import HouseCapture

final class DepthFrameStoreTests: XCTestCase {
  private var folder: URL!
  private struct CompressionFailed: Error {}

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("depth"), withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: folder)
  }

  private func exists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path)
  }

  func testWritesCompressedDepthAndConfidence() throws {
    let store = DepthFrameStore(bundle: ScanBundle(url: folder))

    try store.write(depth: Data([1, 2, 3, 4]), confidence: Data([2, 2]), depthPath: "depth/00000.f16z", confidencePath: "depth/00000.conf")

    let written = try Data(contentsOf: folder.appendingPathComponent("depth/00000.f16z"))
    XCTAssertEqual(try (written as NSData).decompressed(using: .zlib) as Data, Data([1, 2, 3, 4]))
    XCTAssertTrue(exists("depth/00000.conf"))
  }

  func testAFailedCompressionWritesNothingRatherThanRawBytesUnderTheCompressedName() {
    let store = DepthFrameStore(bundle: ScanBundle(url: folder), compress: { _ in throw CompressionFailed() })

    XCTAssertThrowsError(try store.write(depth: Data([1, 2]), confidence: Data([2]), depthPath: "depth/00000.f16z", confidencePath: "depth/00000.conf"))

    XCTAssertFalse(exists("depth/00000.f16z"))
    XCTAssertFalse(exists("depth/00000.conf"))
  }

  func testAFailedConfidenceWriteRemovesTheDepthFileSoNoHalfFrameIsLeft() {
    let store = DepthFrameStore(bundle: ScanBundle(url: folder))

    XCTAssertThrowsError(try store.write(depth: Data([1, 2]), confidence: Data([2]), depthPath: "depth/00000.f16z", confidencePath: "missing-folder/00000.conf"))

    XCTAssertFalse(exists("depth/00000.f16z"))
  }
}

final class DepthRecorderSaveTests: XCTestCase {
  func testSavingTheFrameIndexReplacesItInsteadOfRewritingItInPlace() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("depth"), withIntermediateDirectories: true)
    let recorder = DepthRecorder(bundle: ScanBundle(url: folder))
    let index = folder.appendingPathComponent("depth/frames.json")
    try recorder.save()
    let before = try FileManager.default.attributesOfItem(atPath: index.path)[.systemFileNumber] as? Int

    try recorder.save()

    XCTAssertNotEqual(try FileManager.default.attributesOfItem(atPath: index.path)[.systemFileNumber] as? Int, before)
  }
}

final class DepthFrameColorTests: XCTestCase {
  private func image() throws -> CGImage {
    let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    return try XCTUnwrap(context.makeImage())
  }

  func testWritesTheColorImageAsJPEG() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("depth"), withIntermediateDirectories: true)

    let written = DepthFrameStore(bundle: ScanBundle(url: folder)).writeColor(try image(), to: "depth/00000.jpg")

    XCTAssertTrue(written)
    let data = try Data(contentsOf: folder.appendingPathComponent("depth/00000.jpg"))
    XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
  }

  func testReportsAColorImageThatCouldNotBeWritten() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

    XCTAssertFalse(DepthFrameStore(bundle: ScanBundle(url: folder)).writeColor(try image(), to: "missing/00000.jpg"))
  }
}
