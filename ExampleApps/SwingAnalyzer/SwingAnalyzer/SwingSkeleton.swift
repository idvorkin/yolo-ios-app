// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//  Pixel-space pose with the angle queries the swing analyzer needs. Ported from swing-analyzer's
//  Skeleton.ts and PoseSkeletonTransformer.ts, remapped from BlazePose-33 to the COCO-17 layout that YOLO pose
//  models emit. Angles use pixel coordinates (not normalized) so non-square frames don't distort them.

import CoreGraphics
import UltralyticsYOLO

/// COCO-17 keypoint order produced by YOLO pose models.
enum CocoKeypoint: Int, CaseIterable {
  case nose = 0, leftEye, rightEye, leftEar, rightEar
  case leftShoulder, rightShoulder, leftElbow, rightElbow
  case leftWrist, rightWrist, leftHip, rightHip
  case leftKnee, rightKnee, leftAnkle, rightAnkle
}

struct SwingSkeleton {
  /// Confidence below which a keypoint is treated as absent (web: `isPointVisible`).
  static let visibleThreshold: Float = 0.2
  /// Stricter confidence used for arm and wrist selection (web: `minConf` in arm/wrist queries).
  static let reliableThreshold: Float = 0.3

  private let points: [CGPoint]
  private let conf: [Float]

  init(keypoints: Keypoints) {
    points = keypoints.xy.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
    conf = keypoints.conf
  }

  func point(_ k: CocoKeypoint, minConf: Float = SwingSkeleton.visibleThreshold) -> CGPoint? {
    let i = k.rawValue
    guard i < points.count, i < conf.count, conf[i] > minConf else { return nil }
    return points[i]
  }

  /// The keypoint set of the side whose joints are all visible and, on average, more confident. Picking a whole
  /// side at once keeps hip/knee angles from mixing a near-side hip with a far-side knee when the pose model's
  /// left/right labels are unreliable (side views, people facing left).
  private func bestSide(_ right: [CocoKeypoint], _ left: [CocoKeypoint]) -> [CGPoint]? {
    func resolve(_ joints: [CocoKeypoint]) -> (points: [CGPoint], confidence: Float)? {
      var points: [CGPoint] = []
      var total: Float = 0
      for joint in joints {
        guard let p = point(joint) else { return nil }
        points.append(p)
        total += conf[joint.rawValue]
      }
      return (points, total / Float(joints.count))
    }
    switch (resolve(right), resolve(left)) {
    case (let r?, let l?): return r.confidence >= l.confidence ? r.points : l.points
    case (let r?, nil): return r.points
    case (nil, let l?): return l.points
    default: return nil
    }
  }

  // MARK: - Angles

  /// Torso lean from vertical in degrees (0 = upright), from the visible shoulders' midpoint to the visible hips'
  /// midpoint. Returns 0 when either end is missing.
  var spineAngle: Double {
    let shoulders = [point(.leftShoulder), point(.rightShoulder)].compactMap { $0 }
    let hips = [point(.leftHip), point(.rightHip)].compactMap { $0 }
    guard let top = Self.centroid(shoulders), let bottom = Self.centroid(hips) else { return 0 }
    let dx = top.x - bottom.x
    let dy = bottom.y - top.y  // y grows downward on screen
    return abs(Double(atan2(dx, dy)) * 180 / .pi)
  }

  /// Upper-arm angle from vertical: 0 = hanging straight down, 90 = horizontal, 180 = overhead.
  /// Uses the more raised of the reliable arms: in a two-hand swing both agree, and in a one-hand swing the
  /// working arm is the raised one while the free arm hangs. Falls back to any visible arm, then 0.
  var armToVerticalAngle: Double {
    func angle(_ shoulder: CGPoint, _ elbow: CGPoint) -> Double {
      let dx = elbow.x - shoulder.x
      let dy = elbow.y - shoulder.y
      let magnitude = (dx * dx + dy * dy).squareRoot()
      guard magnitude > 0 else { return 90 }
      let cosine = Double(min(max(dy / magnitude, -1), 1))
      return acos(cosine) * 180 / .pi
    }
    let reliable = Self.reliableThreshold
    let arms = [(CocoKeypoint.rightShoulder, CocoKeypoint.rightElbow), (.leftShoulder, .leftElbow)]
    let reliableAngles = arms.compactMap { s, e -> Double? in
      guard let sp = point(s, minConf: reliable), let ep = point(e, minConf: reliable) else { return nil }
      return angle(sp, ep)
    }
    if let best = reliableAngles.max() { return best }
    for (s, e) in arms {
      if let sp = point(s), let ep = point(e) { return angle(sp, ep) }
    }
    return 0  // web default when no arm is available
  }

  /// Knee–hip–shoulder angle: ~180 standing, ~90 deep hinge. 0 when no side has all three joints.
  var hipAngle: Double {
    guard let p = bestSide([.rightKnee, .rightHip, .rightShoulder], [.leftKnee, .leftHip, .leftShoulder])
    else { return 0 }
    return Self.angle(p[0], vertex: p[1], p[2])
  }

  /// Hip–knee–ankle angle: ~180 straight leg, ~90 deep squat. 0 when no side has all three joints.
  var kneeAngle: Double {
    guard let p = bestSide([.rightHip, .rightKnee, .rightAnkle], [.leftHip, .leftKnee, .leftAnkle])
    else { return 0 }
    return Self.angle(p[0], vertex: p[1], p[2])
  }

  /// Height of the higher reliable wrist above the shoulder midpoint, in pixels (positive = above shoulders).
  var wristHeight: Double {
    guard let ls = point(.leftShoulder), let rs = point(.rightShoulder) else { return 0 }
    let shoulderMidY = (ls.y + rs.y) / 2
    let wrists = [point(.leftWrist, minConf: Self.reliableThreshold), point(.rightWrist, minConf: Self.reliableThreshold)]
      .compactMap { $0 }
    guard let highest = wrists.map(\.y).min() else { return 0 }
    return Double(shoulderMidY - highest)
  }

  // MARK: - Helpers

  private static func centroid(_ points: [CGPoint]) -> CGPoint? {
    guard !points.isEmpty else { return nil }
    let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
    return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
  }

  /// Angle in degrees at `vertex` between the rays to `a` and `b`.
  private static func angle(_ a: CGPoint, vertex: CGPoint, _ b: CGPoint) -> Double {
    let v1 = CGPoint(x: a.x - vertex.x, y: a.y - vertex.y)
    let v2 = CGPoint(x: b.x - vertex.x, y: b.y - vertex.y)
    let mag1 = (v1.x * v1.x + v1.y * v1.y).squareRoot()
    let mag2 = (v2.x * v2.x + v2.y * v2.y).squareRoot()
    guard mag1 > 0, mag2 > 0 else { return 0 }
    let cosine = Double(min(max((v1.x * v2.x + v1.y * v2.y) / (mag1 * mag2), -1), 1))
    return acos(cosine) * 180 / .pi
  }
}
