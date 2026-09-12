// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//  Records camera frames to an H.264 .mov with their capture timestamps, and helpers to trim a clip and save it to
//  the Photos library.

import AVFoundation
import Photos

final class FrameRecorder: @unchecked Sendable {
  let url: URL
  private let queue = DispatchQueue(label: "swing.recorder")
  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var sessionStarted = false

  init() {
    url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swing-recording-\(Int(Date().timeIntervalSince1970)).mov")
  }

  /// Appends a frame. Safe to call from the capture queue; the first frame sizes the encoder and starts the
  /// session at its timestamp, so file time == capture time minus the first frame's time.
  func append(_ sampleBuffer: CMSampleBuffer) {
    queue.async { [self] in
      guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
      if writer == nil {
        do {
          let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
          let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
              AVVideoCodecKey: AVVideoCodecType.h264,
              AVVideoWidthKey: CVPixelBufferGetWidth(pixelBuffer),
              AVVideoHeightKey: CVPixelBufferGetHeight(pixelBuffer),
            ])
          input.expectsMediaDataInRealTime = true
          writer.add(input)
          guard writer.startWriting() else {
            print("[SwingAnalyzer] recorder failed to start: \(String(describing: writer.error))")
            return
          }
          self.writer = writer
          self.input = input
        } catch {
          print("[SwingAnalyzer] recorder init failed: \(error)")
          return
        }
      }
      guard let writer, let input, writer.status == .writing else { return }
      let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      if !sessionStarted {
        writer.startSession(atSourceTime: time)
        sessionStarted = true
      }
      if input.isReadyForMoreMediaData {
        input.append(sampleBuffer)
      }
    }
  }

  /// Finishes the file and returns its URL, or nil if nothing was written.
  func finish() async -> URL? {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        guard let writer, sessionStarted, writer.status == .writing else {
          continuation.resume(returning: nil)
          return
        }
        input?.markAsFinished()
        writer.finishWriting {
          continuation.resume(returning: writer.status == .completed ? self.url : nil)
        }
      }
    }
  }
}

enum VideoFile {
  enum VideoFileError: Error {
    case exportFailed(String)
    case photosDenied
  }

  /// Re-encodes `start...end` of the clip into a new temp file. Passthrough export is deliberately avoided: cutting
  /// mid-GOP leaves leading frames with negative timestamps and AVPlayer then starts the item several seconds in,
  /// while AVAssetReader reads it from zero, so the replayed pose track no longer lines up with playback.
  static func trim(_ url: URL, start: Double, end: Double) async throws -> URL {
    let asset = AVURLAsset(url: url)
    guard
      let export = AVAssetExportSession(
        asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality)  // HEVC keeps HDR clips HDR
    else { throw VideoFileError.exportFailed("no export session") }
    // The quality presets still pass an H.264 track through untouched; a video composition forces every frame
    // through the compositor and therefore a clean re-encode.
    export.videoComposition = try await AVMutableVideoComposition.videoComposition(
      withPropertiesOf: asset)
    let output = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swing-trimmed-\(Int(Date().timeIntervalSince1970)).mov")
    export.outputURL = output
    export.outputFileType = .mov
    export.timeRange = CMTimeRange(
      start: CMTime(seconds: start, preferredTimescale: 600),
      end: CMTime(seconds: end, preferredTimescale: 600))
    await export.export()
    guard export.status == .completed else {
      throw VideoFileError.exportFailed(export.error?.localizedDescription ?? "unknown")
    }
    return output
  }

  /// Saves the clip to Photos and returns the new asset's local identifier.
  static func saveToPhotos(_ url: URL) async throws -> String? {
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard status == .authorized || status == .limited else { throw VideoFileError.photosDenied }
    var identifier: String?
    try await PHPhotoLibrary.shared().performChanges {
      let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
      identifier = request?.placeholderForCreatedAsset?.localIdentifier
    }
    return identifier
  }
}
