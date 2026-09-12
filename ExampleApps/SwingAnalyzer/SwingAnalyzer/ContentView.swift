// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//  Main screen: swing HUD, video with pose overlay, rep gallery, playback and rep navigation, camera flow
//  (record → Done → trim → analyze), and video pickers (Photos, Files).
//  Launch with the SWING_VIDEO environment variable set to a file path to auto-load a video (simulator testing).

import AVFoundation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @StateObject private var session = VideoPoseSession()
  @State private var pickerItem: PhotosPickerItem?
  @State private var showFileImporter = false
  @State private var showPhotosPicker = false
  @State private var showRecents = false
  @State private var showGallery = false
  @State private var showKeyframeViewer = false
  @State private var focusedPhase: SwingPhase?
  @State private var focusedRep: Int?
  @State private var scrubTime = 0.0
  @State private var isScrubbing = false
  @AppStorage("showSkeleton") private var showSkeleton = true
  @AppStorage("meView") private var meView = true
  @AppStorage("galleryHeight") private var galleryHeight = 170.0
  @State private var galleryDragStart: Double?

  private var busy: Bool { session.activity != .idle && session.source != .camera }

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        Color.black
        MeViewZoom(
          crop: meView ? session.personCrop : nil, imageSize: session.latestFrame?.imageSize
        ) { zoom in
          ZStack {
            if session.source == .camera {
              CameraPreviewView(previewLayer: session.cameraPreviewLayer, zoom: zoom)
            } else {
              PlayerView(player: session.player, zoom: zoom)
            }
            if showSkeleton {
              PoseOverlayView(frame: session.latestFrame)
                .scaleEffect(zoom.scale)
                .offset(zoom.offset)
                .animation(.easeOut(duration: 0.3), value: zoom)
            }
          }
        }
        if case .working(let label, let progress) = session.activity, session.source != .camera {
          VStack(spacing: 8) {
            ProgressView(value: progress).frame(width: 160)
            Text(progress.map { "\(label) \(Int($0 * 100))%" } ?? "\(label)…")
              .font(.footnote).foregroundStyle(.white)
          }
          .padding(16)
          .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        }
        hud
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()
      if !session.reps.isEmpty && session.source != .camera {
        galleryHandle
        if galleryHeight >= 40 {
          RepGalleryWidget(
            reps: session.reps, currentRep: session.currentRep?.number, focusedPhase: $focusedPhase,
            focusedRep: $focusedRep,
            onSeek: { session.seek(to: $0.time) },
            onOpen: { _ in showKeyframeViewer = true }
          )
          .frame(height: galleryHeight)
          .padding(.horizontal, 8)
        }
      }
      controls
    }
    .background(Color(.systemBackground))
    .onAppear(perform: loadFromEnvironment)
    .onChange(of: pickerItem) { _, item in
      guard let item else { return }
      Task {
        if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
          session.importPicked(url: movie.url, photosIdentifier: item.itemIdentifier)
        }
        pickerItem = nil
      }
    }
    .onChange(of: session.currentTime) { _, time in
      if !isScrubbing { scrubTime = time }
    }
    .photosPicker(
      isPresented: $showPhotosPicker, selection: $pickerItem, matching: .videos,
      photoLibrary: .shared())
    .sheet(isPresented: $showRecents) {
      RecentsView(store: session.recents) { session.open(recent: $0) }
    }
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

  /// Drag to give the gallery more or less of the screen; double-tap to collapse or restore it.
  private var galleryHandle: some View {
    Capsule()
      .fill(Color(.tertiaryLabel))
      .frame(width: 44, height: 5)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 2)
          .onChanged { value in
            if galleryDragStart == nil { galleryDragStart = galleryHeight }
            galleryHeight = min(max((galleryDragStart ?? galleryHeight) - value.translation.height, 0), 420)
          }
          .onEnded { _ in galleryDragStart = nil }
      )
      .onTapGesture(count: 2) {
        withAnimation(.easeInOut(duration: 0.2)) { galleryHeight = galleryHeight < 40 ? 170 : 0 }
      }
      .accessibilityLabel("Gallery size")
  }

  // MARK: - HUD

  private var hud: some View {
    VStack {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("\(session.latestFrame?.swing?.repCount ?? 0)")
          .font(.system(size: 34, weight: .bold, design: .rounded))
          .monospacedDigit()
        Text("reps").font(.subheadline)
        if session.source == .camera {
          Text("● REC").font(.caption.bold()).foregroundStyle(.red)
        }
        Spacer()
        Text(String(format: "%.0f fps", session.fps)).font(.caption2).monospacedDigit().opacity(0.7)
        Button {
          meView.toggle()
        } label: {
          Image(systemName: meView ? "person.crop.square.fill" : "person.crop.square").font(.title3)
        }
        .accessibilityLabel(meView ? "Show whole frame" : "Zoom to me")
        Button {
          showSkeleton.toggle()
        } label: {
          Image(systemName: showSkeleton ? "eye" : "eye.slash").font(.title3)
        }
        .accessibilityLabel(showSkeleton ? "Hide skeleton" : "Show skeleton")
      }
      HStack(spacing: 5) {
        ForEach(SwingPhase.allCases, id: \.self) { phase in
          let active = session.latestFrame?.swing?.phase == phase
          Text(phase.rawValue.uppercased())
            .font(.caption2.weight(.semibold))
            .fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(active ? Color.accentColor : Color.white.opacity(0.18))
            .foregroundStyle(active ? .white : Color.white.opacity(0.85))
            .clipShape(Capsule())
        }
        Spacer()
      }

      Spacer()

      HStack(spacing: 14) {
        metric("SPINE", session.latestFrame?.swing?.angles.spine)
        metric("ARM", session.latestFrame?.swing?.angles.arm)
        metric("HIP", session.latestFrame?.swing?.angles.hip)
        metric("KNEE", session.latestFrame?.swing?.angles.knee)
        Spacer()
      }
      if let message = session.statusMessage {
        Text(message).font(.caption).lineLimit(1).opacity(0.85)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else if let quality = session.lastQuality {
        Text("Last rep \(quality.score)/100 · \(quality.feedback.joined(separator: " · "))")
          .font(.caption).lineLimit(1).opacity(0.85)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .foregroundStyle(.white)
    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
    .padding(.horizontal, 12).padding(.vertical, 8)
    .background(
      VStack(spacing: 0) {
        LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
          .frame(height: 90)
        Spacer()
        LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
          .frame(height: 80)
      }
      .allowsHitTesting(false)
    )
  }

  private func metric(_ label: String, _ value: Double?) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 3) {
      Text(label).font(.caption2).opacity(0.75)
      Text(value.map { String(format: "%.0f°", $0) } ?? "–")
        .font(.callout.weight(.semibold)).monospacedDigit()
    }
  }

  // MARK: - Controls

  private var controls: some View {
    VStack(spacing: 6) {
      if session.source == .camera {
        cameraControls
      } else {
        playbackControls
      }
    }
    .padding(.horizontal).padding(.vertical, 6)
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
          Image(systemName: session.isPlaying ? "pause.fill" : "play.fill").font(.title2)
        }
        .disabled(session.duration == 0)
        navButton("chevron.right", "Next frame") { session.stepFrame(1) }
        navButton("chevron.right.2", "Next checkpoint") { session.seekToCheckpoint(offset: 1) }
        navButton("forward.end.fill", "Next rep") { session.seekToRep(offset: 1) }
      }
      .frame(maxWidth: .infinity)

      HStack(spacing: 10) {
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
        Menu {
          Picker("Speed", selection: $session.rate) {
            Text("¼×").tag(Float(0.25))
            Text("½×").tag(Float(0.5))
            Text("1×").tag(Float(1.0))
          }
        } label: {
          Text(session.rate == 1 ? "1×" : session.rate == 0.5 ? "½×" : "¼×")
            .font(.caption.weight(.semibold)).monospacedDigit()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(.secondarySystemFill), in: Capsule())
        }
      }

      HStack(spacing: 22) {
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
        Spacer()
        Button {
          session.startCamera()
        } label: {
          Label("Camera", systemImage: "camera")
        }
        Menu {
          Button {
            showRecents = true
          } label: {
            Label("Recents", systemImage: "clock.arrow.circlepath")
          }
          Button {
            // Read access lets Recents point back at the asset instead of copying it.
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
              Task { @MainActor in showPhotosPicker = true }
            }
          } label: {
            Label("Photos", systemImage: "photo.on.rectangle")
          }
          Button {
            showFileImporter = true
          } label: {
            Label("Files", systemImage: "folder")
          }
        } label: {
          Label("Open", systemImage: "folder.badge.plus")
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
    let env = ProcessInfo.processInfo.environment
    if env["SWING_OPEN_RECENT"] == "1", let newest = session.recents.entries.first {
      session.open(recent: newest)  // test hook: reopen the newest Recents entry
      return
    }
    guard let path = env["SWING_VIDEO"], !path.isEmpty else { return }
    session.load(url: URL(fileURLWithPath: path))
  }
}

/// How much to enlarge the preview and where to shift it so the person fills the container.
struct ZoomTransform: Equatable {
  var scale: CGFloat = 1
  var offset: CGSize = .zero

  /// The frame a full-container layer should take to show this zoom (aspect-fit content inside it).
  func layerFrame(in container: CGSize) -> CGRect {
    CGRect(
      x: container.width / 2 - container.width * scale / 2 + offset.width,
      y: container.height / 2 - container.height * scale / 2 + offset.height,
      width: container.width * scale, height: container.height * scale)
  }
}

/// Computes the zoom that makes `crop` (a normalized rect in image space) fill the container and hands it to the
/// content. Video layers apply it by resizing their frame (a transform on the view tree would strip HDR from
/// AVPlayerLayer and wash the picture out); the vector overlay applies it as a scale/offset.
struct MeViewZoom<Content: View>: View {
  let crop: CGRect?
  let imageSize: CGSize?
  @ViewBuilder let content: (ZoomTransform) -> Content

  var body: some View {
    GeometryReader { geo in
      content(transform(container: geo.size))
        .frame(width: geo.size.width, height: geo.size.height)
    }
  }

  private func transform(container: CGSize) -> ZoomTransform {
    guard let crop, let imageSize, imageSize.width > 0, container.width > 0 else {
      return ZoomTransform()
    }
    let video = AVMakeRect(aspectRatio: imageSize, insideRect: CGRect(origin: .zero, size: container))
    let region = CGRect(
      x: video.minX + crop.minX * video.width, y: video.minY + crop.minY * video.height,
      width: crop.width * video.width, height: crop.height * video.height)
    guard region.width > 0, region.height > 0 else { return ZoomTransform() }
    let scale = min(max(min(container.width / region.width, container.height / region.height), 1), 4)
    let center = CGPoint(x: container.width / 2, y: container.height / 2)
    var offset = CGSize(
      width: (center.x - region.midX) * scale, height: (center.y - region.midY) * scale)
    // Keep the scaled video covering the container where it can, so we don't pan into black.
    let scaledLeft = center.x + (video.minX - center.x) * scale
    let scaledRight = center.x + (video.maxX - center.x) * scale
    if scaledRight - scaledLeft >= container.width {
      offset.width = min(max(offset.width, container.width - scaledRight), -scaledLeft)
    } else {
      offset.width = 0
    }
    let scaledTop = center.y + (video.minY - center.y) * scale
    let scaledBottom = center.y + (video.maxY - center.y) * scale
    if scaledBottom - scaledTop >= container.height {
      offset.height = min(max(offset.height, container.height - scaledBottom), -scaledTop)
    } else {
      offset.height = 0
    }
    return ZoomTransform(scale: scale, offset: offset)
  }
}

/// Hosts one video layer (player or camera preview) and applies the zoom by resizing that layer's frame.
final class VideoLayerHostView: UIView {
  var zoom = ZoomTransform() {
    didSet { if zoom != oldValue { setNeedsLayout() } }
  }
  var videoLayer: CALayer? {
    didSet {
      guard videoLayer !== oldValue else { return }
      oldValue?.removeFromSuperlayer()
      if let videoLayer {
        videoLayer.frame = zoom.layerFrame(in: bounds.size)
        layer.addSublayer(videoLayer)
      }
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let videoLayer else { return }
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.3)
    videoLayer.frame = zoom.layerFrame(in: bounds.size)
    CATransaction.commit()
  }
}

/// AVPlayerLayer host so the overlay can be laid out on top of the aspect-fit video.
struct PlayerView: UIViewRepresentable {
  let player: AVPlayer
  var zoom = ZoomTransform()

  func makeUIView(context: Context) -> VideoLayerHostView {
    let view = VideoLayerHostView()
    let playerLayer = AVPlayerLayer(player: player)
    playerLayer.videoGravity = .resizeAspect
    view.videoLayer = playerLayer
    view.zoom = zoom
    return view
  }

  func updateUIView(_ uiView: VideoLayerHostView, context: Context) {
    uiView.zoom = zoom
  }
}

/// Hosts the camera preview layer, resized with the view.
struct CameraPreviewView: UIViewRepresentable {
  let previewLayer: AVCaptureVideoPreviewLayer?
  var zoom = ZoomTransform()

  func makeUIView(context: Context) -> VideoLayerHostView {
    let view = VideoLayerHostView()
    view.videoLayer = previewLayer
    view.zoom = zoom
    return view
  }

  func updateUIView(_ uiView: VideoLayerHostView, context: Context) {
    uiView.videoLayer = previewLayer
    uiView.zoom = zoom
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
