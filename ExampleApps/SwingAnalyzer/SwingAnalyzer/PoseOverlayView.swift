// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//  Draws COCO-17 keypoints and bones over the aspect-fit video rect, highlighting the spine and right arm
//  that drive the swing analysis.

import AVFoundation
import SwiftUI
import UltralyticsYOLO

struct PoseOverlayView: View {
  let result: YOLOResult?
  let videoSize: CGSize

  private static let bones: [(CocoKeypoint, CocoKeypoint)] = [
    (.leftAnkle, .leftKnee), (.leftKnee, .leftHip), (.rightAnkle, .rightKnee),
    (.rightKnee, .rightHip), (.leftHip, .rightHip), (.leftShoulder, .leftHip),
    (.rightShoulder, .rightHip), (.leftShoulder, .rightShoulder), (.leftShoulder, .leftElbow),
    (.rightShoulder, .rightElbow), (.leftElbow, .leftWrist), (.rightElbow, .rightWrist),
    (.leftEye, .rightEye), (.nose, .leftEye), (.nose, .rightEye), (.leftEye, .leftEar),
    (.rightEye, .rightEar), (.leftEar, .leftShoulder), (.rightEar, .rightShoulder),
  ]

  var body: some View {
    Canvas { context, size in
      guard let result, videoSize.width > 0, result.orig_shape.width > 0 else { return }
      let videoRect = AVMakeRect(
        aspectRatio: videoSize, insideRect: CGRect(origin: .zero, size: size))
      let scale = videoRect.width / result.orig_shape.width

      for keypoints in result.keypointsList {
        let skeleton = SwingSkeleton(keypoints: keypoints)
        func mapped(_ k: CocoKeypoint) -> CGPoint? {
          skeleton.point(k).map {
            CGPoint(x: videoRect.minX + $0.x * scale, y: videoRect.minY + $0.y * scale)
          }
        }

        for (a, b) in Self.bones {
          guard let pa = mapped(a), let pb = mapped(b) else { continue }
          var path = Path()
          path.move(to: pa)
          path.addLine(to: pb)
          let isRightArm =
            (a == .rightShoulder && b == .rightElbow) || (a == .rightElbow && b == .rightWrist)
          context.stroke(
            path, with: .color(isRightArm ? .orange : .cyan.opacity(0.8)), lineWidth: 3)
        }

        if let ls = mapped(.leftShoulder), let rs = mapped(.rightShoulder),
          let lh = mapped(.leftHip), let rh = mapped(.rightHip)
        {
          var spine = Path()
          spine.move(to: CGPoint(x: (ls.x + rs.x) / 2, y: (ls.y + rs.y) / 2))
          spine.addLine(to: CGPoint(x: (lh.x + rh.x) / 2, y: (lh.y + rh.y) / 2))
          context.stroke(spine, with: .color(.yellow), lineWidth: 4)
        }

        for k in CocoKeypoint.allCases {
          guard let p = mapped(k) else { continue }
          let r: CGFloat = 4
          context.fill(
            Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
            with: .color(.white))
        }
      }
    }
    .allowsHitTesting(false)
  }
}
