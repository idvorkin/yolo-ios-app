// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//  Kettlebell swing phase state machine, ported from swing-analyzer's KettlebellSwingFormAnalyzer.ts.
//  Phases: TOP → CONNECT → BOTTOM → RELEASE → TOP (rep complete).
//
//  - TOP: arms at peak height, standing upright (lockout)
//  - CONNECT: arms vertical, connecting to the body before the hinge
//  - BOTTOM: deepest hinge, arms behind the body
//  - RELEASE: arms leaving the body after the hip snap

import Foundation

enum SwingPhase: String, CaseIterable {
  case top, connect, bottom, release
}

/// Phase-transition thresholds in degrees. Defaults come from analysis of real swing videos.
struct SwingThresholds {
  var topSpineMax = 25.0  // spine must be more upright than this at the top
  var topHipMin = 150.0  // hip must be extended past this at the top
  var topArmMin = 55.0  // arm must be above this (near horizontal) at the top
  var bottomArmMax = 40.0  // CONNECT→BOTTOM uses |arm| < bottomArmMax + 15
  var bottomSpineMin = 35.0  // spine must be hinged past this at the bottom
  var bottomHipMax = 140.0  // hip must be flexed below this at the bottom
  var connectArmMax = 25.0  // arms near vertical while spine still upright
  var connectSpineMax = 25.0
  var releaseArmMax = 25.0  // arms crossing vertical on the way up
  var releaseSpineMax = 25.0
}

struct SwingAngles {
  var arm = 0.0
  var spine = 0.0
  var hip = 0.0
  var knee = 0.0
  var wristHeight = 0.0
}

struct RepQuality {
  let score: Int
  let hingeDepth: Double
  let lockoutAngle: Double
  let kneeFlexion: Double
  let feedback: [String]
}

struct SwingFrameResult {
  let phase: SwingPhase
  let repCompleted: Bool
  let repCount: Int
  let angles: SwingAngles
  let repQuality: RepQuality?
}

final class KettlebellSwingAnalyzer {
  private(set) var phase: SwingPhase = .top
  private(set) var repCount = 0
  private(set) var lastRepQuality: RepQuality?

  private let thresholds: SwingThresholds
  private var framesInPhase = 0
  private let minFramesInPhase = 2

  private var wristHeightHistory: [Double] = []
  private let wristHeightWindowSize = 5

  private struct RepMetrics {
    var maxSpineAngle = 0.0
    var minHipAngle = 180.0
    var maxArmAngle = 0.0
    var minArmAngle = 90.0
    var maxKneeFlexion = 0.0
  }
  private var metrics = RepMetrics()

  init(thresholds: SwingThresholds = SwingThresholds()) {
    self.thresholds = thresholds
  }

  func reset() {
    phase = .top
    repCount = 0
    lastRepQuality = nil
    framesInPhase = 0
    wristHeightHistory = []
    metrics = RepMetrics()
  }

  /// Advances the state machine by one frame. Always uses the right arm, matching the web analyzer;
  /// mirror the skeleton for left-handed swings.
  func process(_ skeleton: SwingSkeleton) -> SwingFrameResult {
    let angles = SwingAngles(
      arm: skeleton.armToVerticalAngle(preferred: .right),
      spine: skeleton.spineAngle,
      hip: skeleton.hipAngle,
      knee: skeleton.kneeAngle,
      wristHeight: skeleton.wristHeight(preferred: .right))

    wristHeightHistory.append(angles.wristHeight)
    if wristHeightHistory.count > wristHeightWindowSize * 2 {
      wristHeightHistory.removeFirst(wristHeightHistory.count - wristHeightWindowSize * 2)
    }

    updateMetrics(angles)
    framesInPhase += 1

    var repCompleted = false
    var repQuality: RepQuality?

    switch phase {
    case .top:
      if shouldTransitionToConnect(angles) { transition(to: .connect) }
    case .connect:
      if shouldTransitionToBottom(angles) { transition(to: .bottom) }
    case .bottom:
      if shouldTransitionToRelease(angles) { transition(to: .release) }
    case .release:
      if shouldTransitionToTop(angles) {
        repCount += 1
        lastRepQuality = calculateRepQuality()
        repQuality = lastRepQuality
        repCompleted = true
        transition(to: .top)
        metrics = RepMetrics()
      }
    }

    return SwingFrameResult(
      phase: phase, repCompleted: repCompleted, repCount: repCount, angles: angles,
      repQuality: repQuality)
  }

  // MARK: - Transitions

  private var canTransition: Bool { framesInPhase >= minFramesInPhase }

  private func transition(to newPhase: SwingPhase) {
    phase = newPhase
    framesInPhase = 0
  }

  /// TOP → CONNECT: arms near vertical while the spine is still upright.
  private func shouldTransitionToConnect(_ a: SwingAngles) -> Bool {
    canTransition && abs(a.arm) < thresholds.connectArmMax && a.spine < thresholds.connectSpineMax
  }

  /// CONNECT → BOTTOM: arms behind the body, spine hinged, hips flexed.
  private func shouldTransitionToBottom(_ a: SwingAngles) -> Bool {
    canTransition && abs(a.arm) < abs(thresholds.bottomArmMax) + 15
      && a.spine > thresholds.bottomSpineMin && a.hip < thresholds.bottomHipMax
  }

  /// BOTTOM → RELEASE: arms crossing vertical on the way up, spine returning upright.
  private func shouldTransitionToRelease(_ a: SwingAngles) -> Bool {
    canTransition && abs(a.arm) < thresholds.releaseArmMax && a.spine < thresholds.releaseSpineMax
  }

  /// RELEASE → TOP (rep complete): standing upright with the arm near horizontal, confirmed either by
  /// the wrist height peaking or by the arm staying horizontal for a few frames.
  private func shouldTransitionToTop(_ a: SwingAngles) -> Bool {
    guard canTransition else { return false }
    guard a.spine <= thresholds.topSpineMax, a.hip >= thresholds.topHipMin else { return false }
    guard abs(a.arm) > thresholds.topArmMin else { return false }

    if wristHeightHistory.count >= 3 {
      let len = wristHeightHistory.count
      let prev2 = smoothedWristHeight(center: len - 3, radius: 2)
      let prev1 = smoothedWristHeight(center: len - 2, radius: 2)
      let curr = smoothedWristHeight(center: len - 1, radius: 2)
      let isPeakOrDescending = prev1 >= prev2 && curr < prev1
      let wristHighEnough = prev1 > -80
      if isPeakOrDescending && wristHighEnough { return true }
    }

    // Fast swings can miss the exact peak; after a few horizontal frames call it the top anyway.
    return framesInPhase >= minFramesInPhase + 2
  }

  private func smoothedWristHeight(center: Int, radius: Int) -> Double {
    let h = wristHeightHistory
    let start = max(0, center - radius)
    let end = min(h.count - 1, center + radius)
    guard start <= end else { return h[max(0, min(h.count - 1, center))] }
    return h[start...end].reduce(0, +) / Double(end - start + 1)
  }

  // MARK: - Quality

  private func updateMetrics(_ a: SwingAngles) {
    metrics.maxSpineAngle = max(metrics.maxSpineAngle, a.spine)
    metrics.minHipAngle = min(metrics.minHipAngle, a.hip)
    metrics.maxArmAngle = max(metrics.maxArmAngle, a.arm)
    metrics.minArmAngle = min(metrics.minArmAngle, a.arm)
    metrics.maxKneeFlexion = max(metrics.maxKneeFlexion, 175 - a.knee)
  }

  private func calculateRepQuality() -> RepQuality {
    var feedback: [String] = []
    var score = 100

    if metrics.maxSpineAngle < 40 {
      feedback.append("Go deeper - hinge more at the hips")
      score -= 20
    } else if metrics.maxSpineAngle < 55 {
      feedback.append("Good depth, try to hinge a bit deeper")
      score -= 10
    }

    if metrics.maxArmAngle < 60 {
      feedback.append("Drive hips harder - get arms to horizontal")
      score -= 15
    } else if metrics.maxArmAngle < 75 {
      feedback.append("Almost there - squeeze glutes at the top")
      score -= 5
    }

    if metrics.maxKneeFlexion > 30 {
      feedback.append("Hinge, don't squat - keep knees softer")
      score -= 15
    }

    if feedback.isEmpty { feedback.append("Great rep!") }

    return RepQuality(
      score: max(0, score), hingeDepth: metrics.maxSpineAngle, lockoutAngle: metrics.maxArmAngle,
      kneeFlexion: metrics.maxKneeFlexion, feedback: feedback)
  }
}
