// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//  Main screen: swing HUD, video with pose overlay, playback controls, and video pickers (Photos, Files).
//  Launch with the SWING_VIDEO environment variable set to a file path to auto-load a video (simulator testing).

import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @StateObject private var session = VideoPoseSession()
  @State private var pickerItem: PhotosPickerItem?
  @State private var showFileImporter = false
  @State private var scrubTime = 0.0
  @State private var isScrubbing = false

  var body: some View {
    VStack(spacing: 0) {
      hud
      ZStack {
        Color.black
        PlayerView(player: session.player)
        PoseOverlayView(result: session.latestResult, videoSize: session.videoSize)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
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
  }

  private var hud: some View {
    VStack(spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text("\(session.swing?.repCount ?? 0)")
          .font(.system(size: 44, weight: .bold, design: .rounded))
          .monospacedDigit()
        Text("reps").font(.headline).foregroundStyle(.secondary)
        Spacer()
        VStack(alignment: .trailing, spacing: 2) {
          Text(session.modelStatus).font(.caption).foregroundStyle(.secondary)
          Text(String(format: "%.0f fps", session.fps)).font(.caption).monospacedDigit()
            .foregroundStyle(.secondary)
        }
      }

      HStack(spacing: 6) {
        ForEach(SwingPhase.allCases, id: \.self) { phase in
          let active = session.swing?.phase == phase
          Text(phase.rawValue.uppercased())
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(active ? Color.accentColor : Color(.secondarySystemFill))
            .foregroundStyle(active ? .white : .secondary)
            .clipShape(Capsule())
        }
        Spacer()
      }

      HStack(spacing: 16) {
        metric("SPINE", session.swing?.angles.spine)
        metric("ARM", session.swing?.angles.arm)
        metric("HIP", session.swing?.angles.hip)
        metric("KNEE", session.swing?.angles.knee)
        Spacer()
      }

      if let quality = session.lastQuality {
        Text("Last rep \(quality.score)/100 · \(quality.feedback.joined(separator: " · "))")
          .font(.footnote).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal).padding(.vertical, 10)
  }

  private func metric(_ label: String, _ value: Double?) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(label).font(.caption2).foregroundStyle(.secondary)
      Text(value.map { String(format: "%.0f°", $0) } ?? "–")
        .font(.title3.weight(.semibold)).monospacedDigit()
    }
  }

  private var controls: some View {
    VStack(spacing: 10) {
      HStack {
        Button(action: session.togglePlayback) {
          Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
            .font(.title2).frame(width: 36)
        }
        .disabled(session.duration == 0)

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

      HStack {
        Picker("Speed", selection: $session.rate) {
          Text("¼×").tag(Float(0.25))
          Text("½×").tag(Float(0.5))
          Text("1×").tag(Float(1.0))
        }
        .pickerStyle(.segmented)
        .frame(width: 150)

        Spacer()

        Button("Reset", action: session.resetAnalysis)

        PhotosPicker(selection: $pickerItem, matching: .videos) {
          Label("Photos", systemImage: "photo.on.rectangle")
        }

        Button {
          showFileImporter = true
        } label: {
          Label("Files", systemImage: "folder")
        }
      }
      .labelStyle(.iconOnly)
      .font(.title3)
    }
    .padding(.horizontal).padding(.vertical, 10)
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
