// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//  Main screen: swing HUD, video with pose overlay, rep gallery, playback and rep navigation, camera flow
//  (record → Done → trim → analyze), and video pickers (Photos, Files).
//  Launch with the SWING_VIDEO environment variable set to a file path to auto-load a video (simulator testing).

import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @StateObject private var session = VideoPoseSession()
  @State private var pickerItem: PhotosPickerItem?
  @State private var showFileImporter = false
  @State private var showPhotosPicker = false
  @State private var showGallery = false
  @State private var showKeyframeViewer = false
  @State private var focusedPhase: SwingPhase?
  @State private var focusedRep: Int?
  @State private var scrubTime = 0.0
  @State private var isScrubbing = false
  @AppStorage("showSkeleton") private var showSkeleton = true

  private var busy: Bool { session.activity != .idle && session.source != .camera }

  var body: some View {
    VStack(spacing: 0) {
      hud
      ZStack {
        Color.black
        if session.source == .camera {
          CameraPreviewView(previewLayer: session.cameraPreviewLayer)
        } else {
          PlayerView(player: session.player)
        }
        if showSkeleton { PoseOverlayView(frame: session.latestFrame) }
        if case .working(let label, let progress) = session.activity, session.source != .camera {
          VStack(spacing: 8) {
            ProgressView(value: progress).frame(width: 160)
            Text(progress.map { "\(label) \(Int($0 * 100))%" } ?? "\(label)…")
              .font(.footnote).foregroundStyle(.white)
          }
          .padding(16)
          .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      if !session.reps.isEmpty && session.source != .camera {
        RepGalleryWidget(
          reps: session.reps, currentRep: session.currentRep?.number, focusedPhase: $focusedPhase,
          focusedRep: $focusedRep,
          onSeek: { session.seek(to: $0.time) },
          onOpen: { _ in showKeyframeViewer = true }
        )
        .frame(height: focusedRep == nil ? 170 : 240)
        .padding(.horizontal, 8)
      }
      controls
    }
    .background(Color(.systemBackground))
    .onAppear(perform: loadFromEnvironment)
    .onChange(of: pickerItem) { _, item in
      guard let item else { return }
      Task {
        if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
          session.load(url: movie.url)
        }
      }
    }
    .onChange(of: session.currentTime) { _, time in
      if !isScrubbing { scrubTime = time }
    }
    .photosPicker(isPresented: $showPhotosPicker, selection: $pickerItem, matching: .videos)
    .fileImporter(
      isPresented: $showFileImporter, allowedContentTypes: [.movie, .video, .mpeg4Movie]
    ) { result in
      guard case .success(let url) = result else { return }
      let accessed = url.startAccessingSecurityScopedResource()
      defer { if accessed { url.stopAccessingSecurityScopedResource() } }
      let dest = FileManager.default.temporaryDirectory.appendingPathComponent(
        url.lastPathComponent)
      try? FileManager.default.removeItem(at: dest)
      if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
        session.load(url: dest)
      }
    }
    .fullScreenCover(isPresented: $showKeyframeViewer) {
      KeyframeViewer(session: session)
    }
    .sheet(isPresented: $showGallery) {
      RepGallerySheet(reps: session.reps, currentRep: session.currentRep?.number) { position in
        session.seek(to: position.time)
      }
    }
  }

  // MARK: - HUD

  private var hud: some View {
    VStack(spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text("\(session.latestFrame?.swing?.repCount ?? 0)")
          .font(.system(size: 40, weight: .bold, design: .rounded))
          .monospacedDigit()
        Text("reps").font(.headline).foregroundStyle(.secondary)
        if session.source == .camera {
          Text("● REC").font(.caption.bold()).foregroundStyle(.red).padding(.leading, 8)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 2) {
          Text(session.modelStatus).font(.caption).foregroundStyle(.secondary)
          Text(String(format: "%.0f fps", session.fps)).font(.caption).monospacedDigit()
            .foregroundStyle(.secondary)
        }
      }

      HStack(spacing: 6) {
        ForEach(SwingPhase.allCases, id: \.self) { phase in
          let active = session.latestFrame?.swing?.phase == phase
          Text(phase.rawValue.uppercased())
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(active ? Color.accentColor : Color(.secondarySystemFill))
            .foregroundStyle(active ? .white : .secondary)
            .clipShape(Capsule())
        }
        Spacer()
        Button {
          showSkeleton.toggle()
        } label: {
          Image(systemName: showSkeleton ? "eye" : "eye.slash")
            .font(.title3)
            .foregroundStyle(showSkeleton ? Color.accentColor : .secondary)
        }
        .accessibilityLabel(showSkeleton ? "Hide skeleton" : "Show skeleton")
      }

      HStack(spacing: 16) {
        metric("SPINE", session.latestFrame?.swing?.angles.spine)
        metric("ARM", session.latestFrame?.swing?.angles.arm)
        metric("HIP", session.latestFrame?.swing?.angles.hip)
        metric("KNEE", session.latestFrame?.swing?.angles.knee)
        Spacer()
      }

      if let message = session.statusMessage {
        Text(message).font(.footnote).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else if let quality = session.lastQuality {
        Text("Last rep \(quality.score)/100 · \(quality.feedback.joined(separator: " · "))")
          .font(.footnote).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal).padding(.vertical, 8)
  }

  private func metric(_ label: String, _ value: Double?) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(label).font(.caption2).foregroundStyle(.secondary)
      Text(value.map { String(format: "%.0f°", $0) } ?? "–")
        .font(.title3.weight(.semibold)).monospacedDigit()
    }
  }

  // MARK: - Controls

  private var controls: some View {
    VStack(spacing: 10) {
      if session.source == .camera {
        cameraControls
      } else {
        playbackControls
      }
    }
    .padding(.horizontal).padding(.vertical, 10)
    .disabled(busy)
  }

  private var cameraControls: some View {
    HStack {
      Button {
        session.flipCamera()
      } label: {
        Label("Flip camera", systemImage: "arrow.triangle.2.circlepath.camera")
      }
      .labelStyle(.iconOnly).font(.title3)
      Spacer()
      Button {
        session.finishCamera()
      } label: {
        Text("Done").font(.headline).padding(.horizontal, 24)
      }
      .buttonStyle(.borderedProminent)
      Spacer()
      Button(role: .destructive) {
        session.cancelCamera()
      } label: {
        Label("Cancel", systemImage: "xmark.circle")
      }
      .labelStyle(.iconOnly).font(.title3)
    }
  }

  private var playbackControls: some View {
    Group {
      HStack(spacing: 18) {
        navButton("backward.end.fill", "Previous rep") { session.seekToRep(offset: -1) }
        navButton("chevron.left.2", "Previous checkpoint") { session.seekToCheckpoint(offset: -1) }
        navButton("chevron.left", "Previous frame") { session.stepFrame(-1) }
        Button(action: session.togglePlayback) {
          Image(systemName: session.isPlaying ? "pause.fill" : "play.fill").font(.title)
        }
        .disabled(session.duration == 0)
        navButton("chevron.right", "Next frame") { session.stepFrame(1) }
        navButton("chevron.right.2", "Next checkpoint") { session.seekToCheckpoint(offset: 1) }
        navButton("forward.end.fill", "Next rep") { session.seekToRep(offset: 1) }
      }
      .frame(maxWidth: .infinity)

      HStack {
        Slider(
          value: $scrubTime, in: 0...max(session.duration, 0.001),
          onEditingChanged: { editing in
            isScrubbing = editing
            if !editing { session.seek(to: scrubTime) }
          }
        )
        .disabled(session.duration == 0)
        Text(timeString(scrubTime) + " / " + timeString(session.duration))
          .font(.caption).monospacedDigit().foregroundStyle(.secondary)
      }

      HStack(spacing: 12) {
        Picker("Speed", selection: $session.rate) {
          Text("¼×").tag(Float(0.25))
          Text("½×").tag(Float(0.5))
          Text("1×").tag(Float(1.0))
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .frame(width: 110)

        Spacer()

        if session.duration > 0 {
          Button {
            session.pause()
            showKeyframeViewer = true
          } label: {
            Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right")
          }
        }
        if !session.reps.isEmpty {
          Button {
            session.trimToReps()
          } label: {
            Label("Trim to reps", systemImage: "scissors")
          }
          Button {
            showGallery = true
          } label: {
            Label("Rep gallery", systemImage: "square.grid.3x3")
          }
        }
        if session.canSave {
          Button {
            session.saveToPhotos()
          } label: {
            Label("Save to Photos", systemImage: "square.and.arrow.down")
          }
        }
        Button {
          session.startCamera()
        } label: {
          Label("Camera", systemImage: "camera")
        }
        Menu {
          Button {
            showPhotosPicker = true
          } label: {
            Label("Photos", systemImage: "photo.on.rectangle")
          }
          Button {
            showFileImporter = true
          } label: {
            Label("Files", systemImage: "folder")
          }
        } label: {
          Label("Import video", systemImage: "folder.badge.plus")
        }
      }
      .labelStyle(.iconOnly)
      .font(.title3)
    }
  }

  private func navButton(_ symbol: String, _ label: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Label(label, systemImage: symbol).labelStyle(.iconOnly).font(.title3)
    }
    .disabled(session.duration == 0)
  }

  private func timeString(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  private func loadFromEnvironment() {
    guard let path = ProcessInfo.processInfo.environment["SWING_VIDEO"], !path.isEmpty else {
      return
    }
    session.load(url: URL(fileURLWithPath: path))
  }
}

/// AVPlayerLayer host so the overlay can be laid out on top of the aspect-fit video.
struct PlayerView: UIViewRepresentable {
  let player: AVPlayer

  final class LayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
  }

  func makeUIView(context: Context) -> LayerView {
    let view = LayerView()
    view.playerLayer.player = player
    view.playerLayer.videoGravity = .resizeAspect
    return view
  }

  func updateUIView(_ uiView: LayerView, context: Context) {}
}

/// Hosts the camera preview layer, resized with the view.
struct CameraPreviewView: UIViewRepresentable {
  let previewLayer: AVCaptureVideoPreviewLayer?

  final class HostView: UIView {
    var previewLayer: AVCaptureVideoPreviewLayer? {
      didSet {
        guard previewLayer !== oldValue else { return }
        oldValue?.removeFromSuperlayer()
        if let previewLayer {
          previewLayer.frame = bounds
          layer.addSublayer(previewLayer)
        }
      }
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      previewLayer?.frame = bounds
    }
  }

  func makeUIView(context: Context) -> HostView {
    let view = HostView()
    view.previewLayer = previewLayer
    return view
  }

  func updateUIView(_ uiView: HostView, context: Context) {
    uiView.previewLayer = previewLayer
  }
}

/// Copies a picked movie out of the Photos sandbox into a temp file the player can open.
struct PickedMovie: Transferable {
  let url: URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(contentType: .movie) { movie in
      SentTransferredFile(movie.url)
    } importing: { received in
      let dest = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString + "." + received.file.pathExtension)
      try FileManager.default.copyItem(at: received.file, to: dest)
      return PickedMovie(url: dest)
    }
  }
}

#Preview {
  ContentView()
}
