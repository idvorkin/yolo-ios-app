// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//  VideoPoseSession orchestrates the app: two frame sources (file playback, live camera), one shared pose
//  predictor, a SwingPipeline per analysis, the recorder, the offline pass, trimming, saving, rep navigation,
//  and the session log.
//
//  Live camera: every frame is recorded and analyzed live (frames drop if inference falls behind). Done trims the
//  recording to the rep span and runs the offline pass on the clip. Imported files get the offline pass on load.
//  Playback then replays the stored pose track; inference only runs for frames the track doesn't cover.

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

  enum Activity: Equatable {
    case idle
    case working(String, progress: Double?)
  }

  let player = AVPlayer()
  let log = SessionLog()

  @Published private(set) var source: Source = .none
  @Published private(set) var activity: Activity = .idle
  @Published private(set) var modelStatus = "Loading model…"
  @Published private(set) var statusMessage: String?
  @Published private(set) var latestFrame: FrameRecord?
  @Published private(set) var reps: [RepRecord] = []
  @Published private(set) var lastQuality: RepQuality?
  @Published private(set) var fps = 0.0
  @Published private(set) var isPlaying = false
  @Published private(set) var currentTime = 0.0
  @Published private(set) var duration = 0.0
  @Published private(set) var cameraPreviewLayer: AVCaptureVideoPreviewLayer?
  @Published private(set) var cameraPosition: AVCaptureDevice.Position = .back
  @Published private(set) var canSave = false
  @Published var rate: Float = 1.0 {
    didSet { if isPlaying { player.rate = rate } }
  }

  private var predictor: BasePredictor?
  private var pipeline = SwingPipeline()
  private var videoOutput: AVPlayerItemVideoOutput?
  private var displayLink: CADisplayLink?
  private let inferenceQueue = DispatchQueue(label: "swing.inference")
  private var inferenceBusy = false
  private var liveInferenceEnabled = true
  private var pendingFrame: (time: Double, pixelBuffer: CVPixelBuffer)?
  private var frameDuration = 1.0 / 30
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?

  private var camera: CameraSource?
  private var recorder: FrameRecorder?
  private var cameraFirstTime: Double?
  private var cameraFramesDelivered = 0
  private var cameraFramesAnalyzed = 0

  private var currentFileURL: URL?
  private var trimmedURL: URL?
  private var pendingLoadURL: URL?
  private var debugFramesToLog = 0
  private var lastLoggedPhase: SwingPhase?

  var currentRep: RepRecord? {
    reps.first { currentTime >= $0.startTime - 0.05 && currentTime <= $0.endTime + 0.05 }
  }

  /// The checkpoint the playhead is sitting on, if any (within ~3 frames).
  var currentCheckpoint: RepPosition? {
    reps.flatMap(\.checkpoints).min { abs($0.time - currentTime) < abs($1.time - currentTime) }
      .flatMap { abs($0.time - currentTime) <= 0.1 ? $0 : nil }
  }

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
          self.log.event("model_loaded", ["model": "yolo26n-pose"])
          if let url = self.pendingLoadURL {
            self.pendingLoadURL = nil
            self.load(url: url)
          }
        case .failure(let error):
          self.modelStatus = "Model failed: \(error.localizedDescription)"
          self.log.event("error", ["where": "model", "message": "\(error)"])
        }
      }
    }
  }

  // MARK: - Files

  /// Imports a video: shows it paused, runs the offline pass, then plays with the stored track.
  func load(url: URL) {
    stopCamera()
    guard predictor != nil else {
      pendingLoadURL = url  // model still loading; retried from loadModel's completion
      statusMessage = "Waiting for model…"
      return
    }
    currentFileURL = url
    trimmedURL = nil
    canSave = true
    log.event("load", ["url": url.lastPathComponent, "source": "file"])
    Task { await analyzeAndPlay(url: url) }
  }

  private func analyzeAndPlay(url: URL) async {
    guard let predictor else {
      statusMessage = "Model not ready"
      return
    }
    installPlayerItem(url: url, pipeline: SwingPipeline())
    liveInferenceEnabled = false
    activity = .working("Analyzing", progress: 0)
    do {
      let (result, summary) = try await OfflineAnalyzer.run(url: url, predictor: predictor) {
        [weak self] fraction in
        Task { @MainActor in self?.activity = .working("Analyzing", progress: fraction) }
      }
      adopt(pipeline: result)
      for frame in result.track.frames {
        log.frame(frame, source: "offline", inferenceMs: summary.averageInferenceMs, fps: 0, personConf: nil)
      }
      for rep in result.reps { log.rep(rep, source: "offline") }
      log.event(
        "offline_pass",
        [
          "frames": summary.frames, "elapsed_s": summary.elapsed,
          "avg_infer_ms": summary.averageInferenceMs, "reps": result.reps.count,
          "fps": summary.elapsed > 0 ? Double(summary.frames) / summary.elapsed : 0,
        ])
      statusMessage = String(
        format: "Analyzed %d frames in %.1fs · %d reps", summary.frames, summary.elapsed,
        result.reps.count)
    } catch {
      statusMessage = "Analysis failed: \(error.localizedDescription)"
      log.event("error", ["where": "offline_pass", "message": "\(error)"])
    }
    activity = .idle
    liveInferenceEnabled = true
    play()
    // Test hook: SWING_AUTO_TRIM=1 trims right after the first analysis (simulator runs can't tap the UI).
    if trimmedURL == nil, ProcessInfo.processInfo.environment["SWING_AUTO_TRIM"] == "1" {
      trimToReps()
    }
  }

  private func installPlayerItem(url: URL, pipeline: SwingPipeline) {
    pause()
    let asset = AVURLAsset(url: url)
    let item = AVPlayerItem(asset: asset)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    item.add(output)
    videoOutput = output
    adopt(pipeline: pipeline)
    player.replaceCurrentItem(with: item)
    source = .file
    debugFramesToLog = 5
    log.event("install_item", ["url": url.lastPathComponent, "track_frames": pipeline.track.frames.count])
    Task {
      duration = (try? await asset.load(.duration).seconds) ?? 0
      if let track = try? await asset.loadTracks(withMediaType: .video).first,
        let rate = try? await track.load(.nominalFrameRate), rate > 0
      {
        frameDuration = 1 / Double(rate)
      }
    }
    startDisplayLink()
  }

  private func adopt(pipeline: SwingPipeline) {
    self.pipeline = pipeline
    reps = pipeline.reps
    lastQuality = pipeline.reps.last?.quality
    latestFrame = pipeline.track.frames.first
    lastLoggedPhase = nil
  }

  func play() {
    guard player.currentItem != nil else { return }
    if let item = player.currentItem, item.currentTime() >= item.duration {
      player.seek(to: .zero)
    }
    player.rate = rate
    isPlaying = true
    log.event(
      "play",
      [
        "player_time": player.currentTime().seconds,
        "item_duration": player.currentItem?.duration.seconds ?? -1,
      ])
  }

  func pause() {
    player.pause()
    isPlaying = false
  }

  func togglePlayback() { isPlaying ? pause() : play() }

  func seek(to seconds: Double) {
    pause()
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    currentTime = seconds
    if let frame = pipeline.track.nearest(to: seconds, tolerance: frameDuration) {
      show(frame)
    }
  }

  func stepFrame(_ delta: Int) {
    pause()
    player.currentItem?.step(byCount: delta)
  }

  func seekToRep(offset: Int) {
    guard !reps.isEmpty else { return }
    let index: Int
    if let current = currentRep, let i = reps.firstIndex(where: { $0.number == current.number }) {
      index = i + offset
    } else {
      // Between reps: the next rep after the playhead, or the last one before it.
      index =
        offset > 0
        ? (reps.firstIndex { $0.startTime > currentTime } ?? reps.count - 1)
        : (reps.lastIndex { $0.startTime < currentTime } ?? 0)
    }
    let clamped = max(0, min(reps.count - 1, index))
    seek(to: reps[clamped].startTime)
  }

  func seekToCheckpoint(offset: Int) {
    let times = reps.flatMap { $0.checkpoints.map(\.time) }.sorted()
    let target =
      offset > 0
      ? times.first { $0 > currentTime + 0.05 }
      : times.last { $0 < currentTime - 0.05 }
    if let target { seek(to: target) }
  }

  func resetAnalysis() {
    pipeline.reset()
    reps = []
    lastQuality = nil
    latestFrame = nil
    statusMessage = nil
    log.event("reset")
  }

  private func startDisplayLink() {
    guard displayLink == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  @objc private func displayLinkFired(_ link: CADisplayLink) {
    guard source == .file, let output = videoOutput else { return }
    let itemTime = output.itemTime(forHostTime: link.targetTimestamp)
    guard output.hasNewPixelBuffer(forItemTime: itemTime),
      let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
    else { return }
    if debugFramesToLog > 0 {
      debugFramesToLog -= 1
      log.event(
        "display_frame",
        [
          "item_time": itemTime.seconds, "player_time": player.currentTime().seconds,
          "rate": player.rate,
        ])
    }
    ingest(pixelBuffer: pixelBuffer, time: itemTime.seconds, replay: true)
  }

  // MARK: - Shared frame ingest

  private func ingest(pixelBuffer: CVPixelBuffer, time: Double, replay: Bool) {
    if replay, let frame = pipeline.track.nearest(to: time, tolerance: frameDuration * 0.6) {
      show(frame)
      return
    }
    guard liveInferenceEnabled, let predictor, !inferenceBusy,
      let sampleBuffer = Self.makeSampleBuffer(pixelBuffer, time: time)
    else { return }
    inferenceBusy = true
    pendingFrame = (time, pixelBuffer)
    cameraFramesAnalyzed += source == .camera ? 1 : 0
    inferenceQueue.async { [weak self] in
      guard let self else { return }
      // `predict` runs Vision synchronously and calls the listeners before returning, so the busy flag can be
      // cleared here whether or not a result was delivered.
      predictor.predict(sampleBuffer: sampleBuffer, onResultsListener: self, onInferenceTime: self)
      Task { @MainActor in self.inferenceBusy = false }
    }
  }

  private nonisolated static func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer, time: Double)
    -> CMSampleBuffer?
  {
    var format: CMVideoFormatDescription?
    guard
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        == noErr, let format
    else { return nil }
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 600),
      decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format,
      sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
    return sampleBuffer
  }

  private func handle(result: YOLOResult) {
    guard let pending = pendingFrame else { return }
    pendingFrame = nil
    let frame = pipeline.process(result: result, time: pending.time) {
      FrameImage.thumbnail(from: pending.pixelBuffer)
    }
    show(frame)
    let personConf = result.boxes.map(\.conf).max()
    log.frame(
      frame, source: source == .camera ? "live" : "file", inferenceMs: result.inferenceMs, fps: fps,
      personConf: personConf)
    if let rep = frame.swing?.completedRep {
      reps = pipeline.reps
      lastQuality = rep.quality
      log.rep(rep, source: source == .camera ? "live" : "file")
    }
  }

  private func show(_ frame: FrameRecord) {
    latestFrame = frame
    if let phase = frame.swing?.phase, phase != lastLoggedPhase {
      lastLoggedPhase = phase
      log.event("phase", ["time": frame.time, "phase": phase.rawValue, "rep": frame.swing?.repCount ?? 0])
    }
  }

  // MARK: - Live camera

  func startCamera(position: AVCaptureDevice.Position = .back) {
    pause()
    player.replaceCurrentItem(with: nil)
    videoOutput = nil
    duration = 0
    stopCamera()
    pipeline = SwingPipeline()
    reps = []
    lastQuality = nil
    latestFrame = nil
    statusMessage = nil
    canSave = false
    trimmedURL = nil
    cameraPosition = position
    cameraFirstTime = nil
    cameraFramesDelivered = 0
    cameraFramesAnalyzed = 0

    AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
      Task { @MainActor in
        guard let self else { return }
        guard granted else {
          self.statusMessage = "Camera access denied"
          return
        }
        do {
          let camera = try CameraSource(position: position, orientation: self.currentVideoOrientation())
          let recorder = FrameRecorder()
          camera.onFrame = { [weak self] sampleBuffer in
            recorder.append(sampleBuffer)
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            Task { @MainActor in self?.cameraFrame(pixelBuffer: pixelBuffer, pts: pts) }
          }
          self.camera = camera
          self.recorder = recorder
          self.cameraPreviewLayer = camera.previewLayer
          self.source = .camera
          self.activity = .working("Recording", progress: nil)
          self.log.event("camera_start", ["position": position == .front ? "front" : "back"])
          camera.start()
        } catch {
          self.statusMessage = "Camera failed: \(error.localizedDescription)"
          self.log.event("error", ["where": "camera", "message": "\(error)"])
        }
      }
    }
  }

  private func cameraFrame(pixelBuffer: CVPixelBuffer, pts: Double) {
    guard source == .camera else { return }
    if cameraFirstTime == nil { cameraFirstTime = pts }
    cameraFramesDelivered += 1
    let time = pts - (cameraFirstTime ?? pts)
    duration = time
    currentTime = time
    ingest(pixelBuffer: pixelBuffer, time: time, replay: false)
  }

  func flipCamera() {
    startCamera(position: cameraPosition == .back ? .front : .back)
  }

  /// Stops the camera without keeping the recording.
  func cancelCamera() {
    stopCamera()
    recorder = nil
    activity = .idle
    log.event("camera_cancel")
  }

  private func stopCamera() {
    camera?.stop()
    camera = nil
    cameraPreviewLayer = nil
    if source == .camera { source = .none }
  }

  /// Done: stop, trim the recording to the rep span, run the offline pass on the clip, and show it.
  func finishCamera() {
    let livePipeline = pipeline
    let recordedDuration = duration
    let delivered = cameraFramesDelivered
    let analyzed = cameraFramesAnalyzed
    stopCamera()
    guard let recorder else { return }
    self.recorder = nil
    activity = .working("Finishing recording", progress: nil)
    log.event(
      "camera_done",
      [
        "duration_s": recordedDuration, "frames_delivered": delivered, "frames_analyzed": analyzed,
        "live_reps": livePipeline.reps.count,
      ])
    Task {
      guard let url = await recorder.finish() else {
        statusMessage = "Nothing recorded"
        activity = .idle
        return
      }
      currentFileURL = url
      canSave = true
      await trim(url: url, using: livePipeline, thenAnalyze: true)
    }
  }

  /// Trim the current file to the detected rep span (file mode button).
  func trimToReps() {
    guard let url = trimmedURL ?? currentFileURL, source == .file else { return }
    let current = pipeline
    Task { await trim(url: url, using: current, thenAnalyze: false) }
  }

  private func trim(url: URL, using analyzed: SwingPipeline, thenAnalyze: Bool) async {
    let asset = AVURLAsset(url: url)
    let clipDuration = (try? await asset.load(.duration).seconds) ?? duration
    guard let span = analyzed.repSpan(padding: 1.0, duration: clipDuration) else {
      statusMessage = "No reps detected, keeping the whole clip"
      log.event("trim_skipped", ["reason": "no reps", "duration_s": clipDuration])
      if thenAnalyze { await analyzeAndPlay(url: url) } else { activity = .idle }
      return
    }
    activity = .working("Trimming", progress: nil)
    do {
      let clip = try await VideoFile.trim(url, start: span.start, end: span.end)
      trimmedURL = clip
      canSave = true
      log.event(
        "trim",
        [
          "start_s": span.start, "end_s": span.end, "reps": analyzed.reps.count,
          "source_duration_s": clipDuration, "clip": clip.lastPathComponent,
        ])
      if thenAnalyze {
        await analyzeAndPlay(url: clip)
      } else {
        installPlayerItem(
          url: clip, pipeline: analyzed.shifted(toStartAt: span.start, end: span.end))
        statusMessage = String(format: "Trimmed to %.1fs", span.end - span.start)
        activity = .idle
        play()
      }
    } catch {
      statusMessage = "Trim failed: \(error.localizedDescription)"
      log.event("error", ["where": "trim", "message": "\(error)"])
      activity = .idle
    }
  }

  func saveToPhotos() {
    guard let url = trimmedURL ?? currentFileURL else { return }
    activity = .working("Saving", progress: nil)
    Task {
      do {
        try await VideoFile.saveToPhotos(url)
        statusMessage = "Saved to Photos"
        log.event("saved", ["clip": url.lastPathComponent])
      } catch {
        statusMessage = "Save failed: \(error.localizedDescription)"
        log.event("error", ["where": "save", "message": "\(error)"])
      }
      activity = .idle
    }
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
}

extension VideoPoseSession: ResultsListener, InferenceTimeListener {
  nonisolated func on(result: YOLOResult) {
    Task { @MainActor in self.handle(result: result) }
  }

  nonisolated func on(inferenceTime: Double, fpsRate: Double) {
    Task { @MainActor in self.fps = fpsRate }
  }
}
