// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//  Post-real-time pass: reads every frame of a clip in order with AVAssetReader (rotation applied via a video
//  composition), runs pose inference as fast as the Neural Engine allows, and returns a complete SwingPipeline.

import AVFoundation
import UIKit
import UltralyticsYOLO

enum OfflineAnalyzer {
  enum OfflineError: Error {
    case noVideoTrack
    case readerFailed(String)
  }

  struct Summary {
    let frames: Int
    let elapsed: Double
    let averageInferenceMs: Double
  }

  /// Captures the result `predict` delivers synchronously on the calling thread.
  private final class ResultCatcher: ResultsListener, InferenceTimeListener {
    var result: YOLOResult?
    func on(result: YOLOResult) { self.result = result }
    func on(inferenceTime: Double, fpsRate: Double) {}
  }

  static func run(
    url: URL, predictor: BasePredictor, progress: @escaping @Sendable (Double) -> Void
  ) async throws -> (SwingPipeline, Summary) {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw OfflineError.noVideoTrack
    }
    let duration = try await asset.load(.duration).seconds
    let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)

    return try await Task.detached(priority: .userInitiated) {
      let reader = try AVAssetReader(asset: asset)
      let output = AVAssetReaderVideoCompositionOutput(
        videoTracks: [track],
        videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
      output.videoComposition = composition
      output.alwaysCopiesSampleData = false
      reader.add(output)
      guard reader.startReading() else {
        throw OfflineError.readerFailed(reader.error?.localizedDescription ?? "unknown")
      }

      let pipeline = SwingPipeline()
      let catcher = ResultCatcher()
      let started = CACurrentMediaTime()
      var frames = 0
      var inferenceTotal = 0.0
      var lastProgress = 0.0

      while let sampleBuffer = output.copyNextSampleBuffer() {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        catcher.result = nil
        predictor.predict(sampleBuffer: sampleBuffer, onResultsListener: catcher, onInferenceTime: catcher)
        guard let result = catcher.result else { continue }
        _ = pipeline.process(result: result, time: time) { FrameImage.thumbnail(from: pixelBuffer) }
        frames += 1
        inferenceTotal += result.inferenceMs
        if duration > 0, time - lastProgress > 0.5 {
          lastProgress = time
          progress(time / duration)
        }
      }
      if reader.status == .failed {
        throw OfflineError.readerFailed(reader.error?.localizedDescription ?? "unknown")
      }
      let summary = Summary(
        frames: frames, elapsed: CACurrentMediaTime() - started,
        averageInferenceMs: frames > 0 ? inferenceTotal / Double(frames) : 0)
      return (pipeline, summary)
    }.value
  }
}
