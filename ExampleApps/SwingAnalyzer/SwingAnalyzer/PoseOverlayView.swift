// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//  Skeleton drawing shared by the live overlay and the rep-gallery thumbnails: COCO-17 bones, with the spine and
//  right arm that drive the swing analysis highlighted.

import AVFoundation
import SwiftUI
import UltralyticsYOLO

enum PoseDrawing {
  private static let bones: [(CocoKeypoint, CocoKeypoint)] = [
    (.leftAnkle, .leftKnee), (.leftKnee, .leftHip), (.rightAnkle, .rightKnee),
    (.rightKnee, .rightHip), (.leftHip, .rightHip), (.leftShoulder, .leftHip),
    (.rightShoulder, .rightHip), (.leftShoulder, .rightShoulder), (.leftShoulder, .leftElbow),
    (.rightShoulder, .rightElbow), (.leftElbow, .leftWrist), (.rightElbow, .rightWrist),
    (.leftEye, .rightEye), (.nose, .leftEye), (.nose, .rightEye), (.leftEye, .leftEar),
    (.rightEye, .rightEar), (.leftEar, .leftShoulder), (.rightEar, .rightShoulder),
  ]

  /// Draws `keypoints` (normalized coordinates) into `rect`, the on-screen rect of the source image.
  static func draw(
    _ context: GraphicsContext, keypoints: Keypoints, in rect: CGRect, lineWidth: CGFloat = 3
  ) {
    func mapped(_ k: CocoKeypoint) -> CGPoint? {
      let i = k.rawValue
      guard i < keypoints.xyn.count, i < keypoints.conf.count,
        keypoints.conf[i] > SwingSkeleton.visibleThreshold
      else { return nil }
      return CGPoint(
        x: rect.minX + CGFloat(keypoints.xyn[i].x) * rect.width,
        y: rect.minY + CGFloat(keypoints.xyn[i].y) * rect.height)
    }

    for (a, b) in bones {
      guard let pa = mapped(a), let pb = mapped(b) else { continue }
      var path = Path()
      path.move(to: pa)
      path.addLine(to: pb)
      let isRightArm =
        (a == .rightShoulder && b == .rightElbow) || (a == .rightElbow && b == .rightWrist)
      context.stroke(
        path, with: .color(isRightArm ? .orange : .cyan.opacity(0.8)), lineWidth: lineWidth)
    }

    if let ls = mapped(.leftShoulder), let rs = mapped(.rightShoulder),
      let lh = mapped(.leftHip), let rh = mapped(.rightHip)
    {
      var spine = Path()
      spine.move(to: CGPoint(x: (ls.x + rs.x) / 2, y: (ls.y + rs.y) / 2))
      spine.addLine(to: CGPoint(x: (lh.x + rh.x) / 2, y: (lh.y + rh.y) / 2))
      context.stroke(spine, with: .color(.yellow), lineWidth: lineWidth + 1)
    }

    let r = lineWidth * 1.3
    for k in CocoKeypoint.allCases {
      guard let p = mapped(k) else { continue }
      context.fill(
        Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
        with: .color(.white))
    }
  }
}

/// Draws the analyzed frame's skeleton over an aspect-fit video of the same size.
struct PoseOverlayView: View {
  let frame: FrameRecord?

  var body: some View {
    Canvas { context, size in
      guard let frame, let keypoints = frame.keypoints, frame.imageSize.width > 0 else { return }
      let rect = AVMakeRect(
        aspectRatio: frame.imageSize, insideRect: CGRect(origin: .zero, size: size))
      PoseDrawing.draw(context, keypoints: keypoints, in: rect)
    }
    .allowsHitTesting(false)
  }
}

/// A rep-position thumbnail: the captured frame with its skeleton drawn on.
struct PoseThumbnail: View {
  let position: RepPosition?

  var body: some View {
    GeometryReader { geo in
      ZStack {
        Color(.tertiarySystemFill)
        if let position, let image = position.image {
          Image(uiImage: image).resizable().scaledToFit()
          Canvas { context, size in
            let rect = AVMakeRect(
              aspectRatio: image.size, insideRect: CGRect(origin: .zero, size: size))
            PoseDrawing.draw(context, keypoints: position.keypoints, in: rect, lineWidth: 1.5)
          }
        } else {
          Image(systemName: "figure.strengthtraining.traditional")
            .foregroundStyle(.tertiary)
        }
      }
      .frame(width: geo.size.width, height: geo.size.height)
    }
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }
}
