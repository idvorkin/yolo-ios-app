// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//  SwingPipeline turns pose results into analyzed frames: it picks the tracked person, runs the swing state
//  machine, records the frame in a PoseTrack, and collects completed reps. The live session and the offline pass
//  each own one, so their state never mixes.

import CoreImage
import CoreVideo
import UIKit
import UltralyticsYOLO

final class SwingPipeline: @unchecked Sendable {
  let analyzer = KettlebellSwingAnalyzer()
  let track = PoseTrack()
  private(set) var reps: [RepRecord] = []

  func reset() {
    analyzer.reset()
    track.removeAll()
    reps = []
  }

  /// Analyzes one inference result at `time`. `image` renders the source frame and is called only when the
  /// analyzer keeps it as a phase peak.
  func process(result: YOLOResult, time: Double, image: () -> UIImage?) -> FrameRecord {
    // The analyzer expects a single subject: take the most confident person.
    let personIndex = result.boxes.indices.max { result.boxes[$0].conf < result.boxes[$1].conf }
    let pose = personIndex.flatMap {
      $0 < result.keypointsList.count ? Pose(keypoints: result.keypointsList[$0]) : nil
    }
    let swing = pose.map { analyzer.process(pose: $0, time: time, image: image) }
    let frame = FrameRecord(
      time: time, imageSize: result.orig_shape, pose: pose,
      box: personIndex.map { result.boxes[$0].xywhn }, swing: swing)
    track.append(frame)
    if let rep = swing?.completedRep { reps.append(rep) }
    return frame
  }

  /// Rebuilds a pipeline from stored frames and reps (Recents). The analyzer state is not restored; it only
  /// matters if inference runs on frames the track doesn't cover.
  static func restored(frames: [FrameRecord], reps: [RepRecord]) -> SwingPipeline {
    let pipeline = SwingPipeline()
    pipeline.track.replaceAll(with: frames)
    pipeline.reps = reps
    return pipeline
  }

  /// A copy covering `start...end`, re-timed to start at zero (used after trimming a clip).
  func shifted(toStartAt start: Double, end: Double) -> SwingPipeline {
    let pipeline = SwingPipeline()
    let track = self.track.shifted(toStartAt: start, end: end)
    for frame in track.frames { pipeline.track.append(frame) }
    pipeline.reps = reps.filter { $0.startTime >= start && $0.endTime <= end }.map {
      $0.shifted(by: -start)
    }
    return pipeline
  }

  /// One crop covering the person through the set, so playback stays zoomed without following frame by frame.
  /// Only frames inside the rep span count (walking in and out of frame would otherwise widen it to the whole
  /// picture), and the edges are 5th/95th percentiles so a single mis-detection can't blow it up.
  var stableCrop: CGRect? {
    var frames = track.frames
    if let first = reps.first, let last = reps.last {
      let inSet = frames.filter { $0.time >= first.startTime - 0.5 && $0.time <= last.endTime + 0.5 }
      if !inSet.isEmpty { frames = inSet }
    }
    return PersonCrop.padded(robustUnion: frames.compactMap(\.box))
  }

  /// The span where reps happened, padded, clipped to `duration`. Nil when no rep was detected.
  func repSpan(padding: Double, duration: Double) -> (start: Double, end: Double)? {
    guard let first = reps.first, let last = reps.last else { return nil }
    return (max(0, first.startTime - padding), min(duration, last.endTime + padding))
  }
}

enum PersonCrop {
  /// Pads a union box 1.4× wide and 1.3× tall about its center (web app defaults) and clamps it to the image.
  static func padded(union boxes: [CGRect]) -> CGRect? {
    guard let first = boxes.first else { return nil }
    return padded(box: boxes.dropFirst().reduce(first) { $0.union($1) })
  }

  /// Like `padded(union:)` but the box edges are the 5th/95th percentiles across frames, not the extremes.
  static func padded(robustUnion boxes: [CGRect]) -> CGRect? {
    guard boxes.count >= 10 else { return padded(union: boxes) }
    func percentile(_ values: [CGFloat], _ p: Double) -> CGFloat {
      let sorted = values.sorted()
      return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }
    let minX = percentile(boxes.map(\.minX), 0.05)
    let maxX = percentile(boxes.map(\.maxX), 0.95)
    let minY = percentile(boxes.map(\.minY), 0.05)
    let maxY = percentile(boxes.map(\.maxY), 0.95)
    return padded(box: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
  }

  private static func padded(box: CGRect) -> CGRect {
    let padded = CGRect(
      x: box.midX - box.width * 0.7, y: box.midY - box.height * 0.65,
      width: box.width * 1.4, height: box.height * 1.3)
    return padded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
  }
}

enum FrameImage {
  private static let context = CIContext()

  /// A small UIImage of the frame for gallery thumbnails (long side ~360 px).
  static func thumbnail(from pixelBuffer: CVPixelBuffer) -> UIImage? {
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    let scale = 360 / max(image.extent.width, image.extent.height)
    let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
    return UIImage(cgImage: cgImage)
  }
}
