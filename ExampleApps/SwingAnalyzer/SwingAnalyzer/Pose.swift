// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//  App-owned, Codable copy of a detected pose. The SDK's `Keypoints` can't be constructed outside the package, so
//  everything the app stores (pose track, rep positions, Recents) uses this instead.

import CoreGraphics
import UltralyticsYOLO

struct PosePoint: Codable, Equatable {
  var x: Float
  var y: Float
}

struct Pose: Codable {
  /// Normalized (0…1) coordinates in the image.
  let xyn: [PosePoint]
  /// Pixel coordinates in the image.
  let xy: [PosePoint]
  let conf: [Float]

  init(keypoints: Keypoints) {
    xyn = keypoints.xyn.map { PosePoint(x: $0.x, y: $0.y) }
    xy = keypoints.xy.map { PosePoint(x: $0.x, y: $0.y) }
    conf = keypoints.conf
  }
}
