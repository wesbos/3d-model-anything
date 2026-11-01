import Foundation
import ImageIO

/// Writes one depth frame's files into a session bundle: the Float16 depth map, compressed with
/// raw DEFLATE (`zlib.decompress(data, -15)` in Python), and its UInt8 confidence map.
/// A frame is written whole or not at all, so frames.json never lists a file that is missing
/// or that holds uncompressed bytes under the `.f16z` name.
struct DepthFrameStore {
  let bundle: ScanBundle
  /// Apple's `.zlib` algorithm produces raw DEFLATE without the zlib header.
  var compress: (Data) throws -> Data = { try ($0 as NSData).compressed(using: .zlib) as Data }

  /// # Errors
  /// Rethrows a compression or write failure, after removing any file this call already wrote.
  func write(depth: Data, confidence: Data?, depthPath: String, confidencePath: String) throws {
    let compressed = try compress(depth)
    let depthURL = bundle.file(depthPath)
    try compressed.write(to: depthURL)
    do {
      try confidence?.write(to: bundle.file(confidencePath))
    } catch {
      try? FileManager.default.removeItem(at: depthURL)
      throw error
    }
  }
}

/// JPEG quality of the 640x480 color image stored with each depth frame.
private let colorQuality = 0.8

extension DepthFrameStore {
  /// Encodes the frame's color image as JPEG.
  ///
  /// # Returns
  /// Whether the file was written, so the caller can leave a missing image out of frames.json.
  func writeColor(_ image: CGImage, to path: String) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(bundle.file(path) as CFURL, "public.jpeg" as CFString, 1, nil) else {
      return false
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: colorQuality] as CFDictionary)
    return CGImageDestinationFinalize(destination)
  }
}
