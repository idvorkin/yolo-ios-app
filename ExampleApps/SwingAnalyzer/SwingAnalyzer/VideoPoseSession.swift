// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//  VideoPoseSession feeds frames from either a video file (AVPlayer + AVPlayerItemVideoOutput) or the live camera
//  (the SDK's VideoCapture) through the YOLO pose predictor, then through the kettlebell swing analyzer. Frames that
//  arrive while inference is busy are dropped on both paths.

import AVFoundation
import Combine
import CoreMedia
import QuartzCore
import UIKit
import UltralyticsYOLO

@MainActor
final class VideoPoseSession: NSObject, ObservableObject {
  enum Source {
    case none, file, camera
  }

  let player = AVPlayer()

  @Published private(set) var source: Source = .none
  @Published private(set) var modelStatus = "Loading model…"
  @Published private(set) var latestResult: YOLOResult?
  @Published private(set) var swing: SwingFrameResult?
  @Published private(set) var lastQuality: RepQuality?
  @Published private(set) var fps = 0.0
  @Published private(set) var isPlaying = false
  @Published private(set) var currentTime = 0.0
  @Published private(set) var duration = 0.0
  @Published private(set) var cameraPreviewLayer: AVCaptureVideoPreviewLayer?
  @Published private(set) var cameraPosition: AVCaptureDevice.Position = .back
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
  private var orientationObserver: NSObjectProtocol?
  private var videoCapture: VideoCapture?
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
    orientationObserver = NotificationCenter.default.addObserver(
      forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.updateCameraOrientation() }
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
          self.videoCapture?.predictor = predictor
          self.modelStatus = "yolo26n-pose"
        case .failure(let error):
          self.modelStatus = "Model failed: \(error.localizedDescription)"
        }
      }
    }
  }

  // MARK: - File playback

  func load(url: URL) {
    stopCamera()
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
    source = .file

    Task {
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

  private func startDisplayLink() {
    guard displayLink == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  @objc private func displayLinkFired(_ link: CADisplayLink) {
    guard source == .file, let output = videoOutput, let predictor, !inferenceBusy else { return }
    let itemTime = output.itemTime(forHostTime: link.targetTimestamp)
    guard output.hasNewPixelBuffer(forItemTime: itemTime),
      let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil),
      let sampleBuffer = Self.makeSampleBuffer(pixelBuffer, time: itemTime)
    else { return }

    if !loggedBufferSize {
      loggedBufferSize = true
      print(
        "[SwingAnalyzer] frame buffer \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))"
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

  // MARK: - Live camera

  func startCamera(position: AVCaptureDevice.Position = .back) {
    pause()
    player.replaceCurrentItem(with: nil)
    videoOutput = nil
    duration = 0
    stopCamera()
    resetAnalysis()
    cameraPosition = position

    AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
      Task { @MainActor in
        guard let self else { return }
        guard granted else {
          self.modelStatus = "Camera access denied"
          return
        }
        let capture = VideoCapture()
        capture.predictor = self.predictor
        capture.delegate = self
        self.videoCapture = capture
        capture.setUp(position: position, videoOrientation: self.currentVideoOrientation()) {
          success in
          Task { @MainActor in
            guard success, self.videoCapture === capture else { return }
            // Aspect-fit so the overlay's AVMakeRect math matches the preview placement.
            capture.previewLayer?.videoGravity = .resizeAspect
            self.cameraPreviewLayer = capture.previewLayer
            self.source = .camera
            capture.start()
          }
        }
      }
    }
  }

  func stopCamera() {
    videoCapture?.stop()
    videoCapture = nil
    cameraPreviewLayer = nil
    if source == .camera { source = .none }
  }

  func flipCamera() {
    startCamera(position: cameraPosition == .back ? .front : .back)
  }

  private func currentVideoOrientation() -> AVCaptureVideoOrientation {
    let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
    switch scene?.interfaceOrientation {
    case .landscapeLeft: return .landscapeLeft
    case .landscapeRight: return .landscapeRight
    case .portraitUpsideDown: return .portraitUpsideDown
    default: return .portrait
    }
  }

  private func updateCameraOrientation() {
    guard source == .camera, let videoCapture else { return }
    videoCapture.updateVideoOrientation(orientation: currentVideoOrientation())
  }

  // MARK: - Results

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

extension VideoPoseSession: VideoCaptureDelegate {
  func onPredict(result: YOLOResult) {
    handle(result: result)
  }

  func onInferenceTime(speed: Double, fps: Double) {
    self.fps = fps
  }
}
