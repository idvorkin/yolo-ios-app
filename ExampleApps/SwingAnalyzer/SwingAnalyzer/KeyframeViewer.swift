// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//  Full-screen keyframe viewer: the paused video at a rep checkpoint with the skeleton overlay, pinch-zoomable and
//  pannable, with buttons to step between checkpoints and reps. Uses the player itself, so it is full resolution.

import SwiftUI

struct KeyframeViewer: View {
  @ObservedObject var session: VideoPoseSession
  @Environment(\.dismiss) private var dismiss
  @AppStorage("showSkeleton") private var showSkeleton = true

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      ZoomableContainer {
        ZStack {
          PlayerView(player: session.player)
          if showSkeleton { PoseOverlayView(frame: session.latestFrame) }
        }
      }
      .ignoresSafeArea()

      VStack {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            if let rep = session.currentRep {
              Text("Rep \(rep.number) · \(rep.quality.score)/100").font(.headline)
            }
            if let checkpoint = session.currentCheckpoint {
              Text(checkpoint.phase.rawValue.uppercased()).font(.caption.bold())
            }
            if let angles = session.latestFrame?.swing?.angles {
              Text(
                String(
                  format: "spine %.0f° · arm %.0f° · hip %.0f° · knee %.0f°", angles.spine,
                  angles.arm, angles.hip, angles.knee)
              )
              .font(.caption)
            }
          }
          Spacer()
          Button {
            showSkeleton.toggle()
          } label: {
            Image(systemName: showSkeleton ? "eye" : "eye.slash")
              .font(.title2)
              .opacity(showSkeleton ? 1 : 0.5)
          }
          .padding(.trailing, 12)
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark.circle.fill").font(.title)
          }
        }
        .foregroundStyle(.white)
        .padding()
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))

        Spacer()

        HStack(spacing: 28) {
          Button { session.seekToRep(offset: -1) } label: { Image(systemName: "backward.end.fill") }
          Button { session.seekToCheckpoint(offset: -1) } label: { Image(systemName: "chevron.left.2") }
          Button { session.stepFrame(-1) } label: { Image(systemName: "chevron.left") }
          Button { session.stepFrame(1) } label: { Image(systemName: "chevron.right") }
          Button { session.seekToCheckpoint(offset: 1) } label: { Image(systemName: "chevron.right.2") }
          Button { session.seekToRep(offset: 1) } label: { Image(systemName: "forward.end.fill") }
        }
        .font(.title2)
        .foregroundStyle(.white)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
      }
    }
  }
}

/// Pinch to zoom (1×–6×), drag to pan, double-tap to toggle 2.5× / reset.
struct ZoomableContainer<Content: View>: View {
  @ViewBuilder let content: () -> Content

  @State private var scale: CGFloat = 1
  @State private var baseScale: CGFloat = 1
  @State private var offset: CGSize = .zero
  @State private var baseOffset: CGSize = .zero

  var body: some View {
    content()
      .scaleEffect(scale)
      .offset(offset)
      .gesture(
        MagnifyGesture()
          .onChanged { value in
            scale = min(max(baseScale * value.magnification, 1), 6)
          }
          .onEnded { _ in
            baseScale = scale
            if scale == 1 { withAnimation { offset = .zero } ; baseOffset = .zero }
          }
          .simultaneously(
            with: DragGesture()
              .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                  width: baseOffset.width + value.translation.width,
                  height: baseOffset.height + value.translation.height)
              }
              .onEnded { _ in baseOffset = offset }
          )
      )
      .onTapGesture(count: 2) {
        withAnimation(.easeInOut(duration: 0.2)) {
          if scale > 1 {
            scale = 1
            offset = .zero
          } else {
            scale = 2.5
          }
          baseScale = scale
          baseOffset = offset
        }
      }
  }
}
