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

enum BodySide {
  case left, right
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

  /// Right-side keypoint when visible, otherwise the left one. The web app always has 33 BlazePose points and
  /// reads the right side unconditionally; YOLO leaves occluded joints at low confidence, so fall back.
  private func rightOrLeft(_ right: CocoKeypoint, _ left: CocoKeypoint) -> CGPoint? {
    point(right) ?? point(left)
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
  /// Uses the preferred side when reliable, otherwise the more vertical reliable arm, otherwise any visible arm.
  func armToVerticalAngle(preferred: BodySide) -> Double {
    func angle(_ shoulder: CGPoint, _ elbow: CGPoint) -> Double {
      let dx = elbow.x - shoulder.x
      let dy = elbow.y - shoulder.y
      let magnitude = (dx * dx + dy * dy).squareRoot()
      guard magnitude > 0 else { return 90 }
      let cosine = Double(min(max(dy / magnitude, -1), 1))
      return acos(cosine) * 180 / .pi
    }

    let reliable = Self.reliableThreshold
    let rightPair = point(.rightShoulder, minConf: reliable).flatMap { s in
      point(.rightElbow, minConf: reliable).map { (s, $0) }
    }
    let leftPair = point(.leftShoulder, minConf: reliable).flatMap { s in
      point(.leftElbow, minConf: reliable).map { (s, $0) }
    }

    switch (preferred, rightPair, leftPair) {
    case (.right, let pair?, _), (.left, _, let pair?):
      return angle(pair.0, pair.1)
    case (_, let r?, let l?):
      let ra = angle(r.0, r.1)
      let la = angle(l.0, l.1)
      return min(ra, la)
    default:
      if let s = point(.rightShoulder), let e = point(.rightElbow) { return angle(s, e) }
      if let s = point(.leftShoulder), let e = point(.leftElbow) { return angle(s, e) }
      return 0  // web default when no arm is available

    }
  }

  /// Knee–hip–shoulder angle: ~180 standing, ~90 deep hinge. 0 when keypoints are missing.
  var hipAngle: Double {
    guard let knee = rightOrLeft(.rightKnee, .leftKnee),
      let hip = rightOrLeft(.rightHip, .leftHip),
      let shoulder = rightOrLeft(.rightShoulder, .leftShoulder)
    else { return 0 }
    return Self.angle(knee, vertex: hip, shoulder)
  }

  /// Hip–knee–ankle angle: ~180 straight leg, ~90 deep squat. 0 when keypoints are missing.
  var kneeAngle: Double {
    guard let hip = rightOrLeft(.rightHip, .leftHip),
      let knee = rightOrLeft(.rightKnee, .leftKnee),
      let ankle = rightOrLeft(.rightAnkle, .leftAnkle)
    else { return 0 }
    return Self.angle(hip, vertex: knee, ankle)
  }

  /// Wrist height above the shoulder midpoint in pixels (positive = wrist above shoulders).
  /// Prefers the requested wrist; with both wrists reliable it averages them (two-handed swing).
  func wristHeight(preferred: BodySide) -> Double {
    guard let ls = point(.leftShoulder), let rs = point(.rightShoulder) else { return 0 }
    let shoulderMidY = (ls.y + rs.y) / 2
    let reliable = Self.reliableThreshold
    let left = point(.leftWrist, minConf: reliable)
    let right = point(.rightWrist, minConf: reliable)

    let wristY: CGFloat
    switch (preferred, right, left) {
    case (.right, let r?, _): wristY = r.y
    case (.left, _, let l?): wristY = l.y
    case (_, let r?, let l?): wristY = (r.y + l.y) / 2
    case (_, let r?, nil): wristY = r.y
    case (_, nil, let l?): wristY = l.y
    default: return 0
    }
    return Double(shoulderMidY - wristY)
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
