// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//  VideoPoseSession plays a video file with AVPlayer and pumps each displayed frame through the YOLO pose
//  predictor, then through the kettlebell swing analyzer. Frames that arrive while inference is busy are
//  dropped, mirroring the SDK's live-camera path.

import AVFoundation
import Combine
import CoreMedia
import QuartzCore
import UltralyticsYOLO

@MainActor
final class VideoPoseSession: NSObject, ObservableObject {
  let player = AVPlayer()

  @Published private(set) var modelStatus = "Loading model…"
  @Published private(set) var videoSize: CGSize = .zero
  @Published private(set) var latestResult: YOLOResult?
  @Published private(set) var swing: SwingFrameResult?
  @Published private(set) var lastQuality: RepQuality?
  @Published private(set) var fps = 0.0
  @Published private(set) var isPlaying = false
  @Published private(set) var currentTime = 0.0
  @Published private(set) var duration = 0.0
  @Published var rate: Float = 1.0 {
    didSet { if isPlaying { player.rate = rate } }
  }

  private var predictor: BasePredictor?
  private var videoOutput: AVPlayerItemVideoOutput?
  private var displayLink: CADisplayLink?
  private let inferenceQueue = DispatchQueue(label: "swing.inference")
  private var inferenceBusy = false
  private let analyzer = KettlebellSwingAnalyzer()
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var loggedBufferSize = false

  override init() {
    super.init()
    player.actionAtItemEnd = .pause
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(value: 1, timescale: 30), queue: .main
    ) { [weak self] time in
      Task { @MainActor in self?.currentTime = time.seconds }
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.isPlaying = false }
    }
    loadModel()
  }

  private func loadModel() {
    guard let url = Bundle.main.url(forResource: "yolo26n-pose", withExtension: "mlmodelc") else {
      modelStatus = "yolo26n-pose.mlpackage missing from bundle"
      return
    }
    BasePredictor.create(for: .pose, modelURL: url, isRealTime: true) { [weak self] result in
      Task { @MainActor in
        guard let self else { return }
        switch result {
        case .success(let predictor):
          self.predictor = predictor
          self.modelStatus = "yolo26n-pose"
        case .failure(let error):
          self.modelStatus = "Model failed: \(error.localizedDescription)"
        }
      }
    }
  }

  // MARK: - Loading and playback

  func load(url: URL) {
    let asset = AVURLAsset(url: url)
    let item = AVPlayerItem(asset: asset)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    item.add(output)
    videoOutput = output
    loggedBufferSize = false
    resetAnalysis()
    player.replaceCurrentItem(with: item)

    Task {
      guard let track = try? await asset.loadTracks(withMediaType: .video).first,
        let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform)
      else { return }
      let oriented = natural.applying(transform)
      videoSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
      duration = (try? await asset.load(.duration).seconds) ?? 0
    }
    startDisplayLink()
    play()
  }

  func play() {
    guard player.currentItem != nil else { return }
    if let item = player.currentItem, item.currentTime() >= item.duration {
      player.seek(to: .zero)
    }
    player.rate = rate
    isPlaying = true
  }

  func pause() {
    player.pause()
    isPlaying = false
  }

  func togglePlayback() { isPlaying ? pause() : play() }

  func seek(to seconds: Double) {
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
  }

  func resetAnalysis() {
    analyzer.reset()
    swing = nil
    lastQuality = nil
    latestResult = nil
  }

  // MARK: - Frame pump

  private func startDisplayLink() {
    guard displayLink == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  @objc private func displayLinkFired(_ link: CADisplayLink) {
    guard let output = videoOutput, let predictor, !inferenceBusy else { return }
    let itemTime = output.itemTime(forHostTime: link.targetTimestamp)
    guard output.hasNewPixelBuffer(forItemTime: itemTime),
      let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil),
      let sampleBuffer = Self.makeSampleBuffer(pixelBuffer, time: itemTime)
    else { return }

    if !loggedBufferSize {
      loggedBufferSize = true
      print(
        "[SwingAnalyzer] frame buffer \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)), display size \(videoSize)"
      )
    }

    inferenceBusy = true
    inferenceQueue.async { [weak self] in
      guard let self else { return }
      // `predict` runs Vision synchronously and calls the listeners before returning, so the busy flag can be
      // cleared here whether or not a result was delivered.
      predictor.predict(sampleBuffer: sampleBuffer, onResultsListener: self, onInferenceTime: self)
      Task { @MainActor in self.inferenceBusy = false }
    }
  }

  private nonisolated static func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer, time: CMTime)
    -> CMSampleBuffer?
  {
    var format: CMVideoFormatDescription?
    guard
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        == noErr, let format
    else { return nil }
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format,
      sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
    return sampleBuffer
  }

  private func handle(result: YOLOResult) {
    latestResult = result
    // Track the most confident person; the analyzer expects a single subject.
    guard let index = result.boxes.indices.max(by: { result.boxes[$0].conf < result.boxes[$1].conf }),
      index < result.keypointsList.count
    else { return }
    let frame = analyzer.process(SwingSkeleton(keypoints: result.keypointsList[index]))
    swing = frame
    if let quality = frame.repQuality { lastQuality = quality }
  }
}

extension VideoPoseSession: ResultsListener, InferenceTimeListener {
  nonisolated func on(result: YOLOResult) {
    Task { @MainActor in self.handle(result: result) }
  }

  nonisolated func on(inferenceTime: Double, fpsRate: Double) {
    Task { @MainActor in self.fps = fpsRate }
  }
}
