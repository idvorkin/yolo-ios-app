// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//  JSON Lines session log written to Documents/logs (visible in Finder and the Files app, pull with
//  `just pull-logs`). One event per line with a monotonic `t` in ms since the session started.

import Foundation
import UIKit

final class SessionLog: @unchecked Sendable {
  let url: URL
  private let queue = DispatchQueue(label: "swing.log")
  private var handle: FileHandle?
  private let start = Date()

  init() {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("logs", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    url = dir.appendingPathComponent("swing-\(formatter.string(from: start)).jsonl")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    handle = try? FileHandle(forWritingTo: url)
    event(
      "session_start",
      [
        "device": UIDevice.current.model, "system": UIDevice.current.systemVersion,
        "app": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "",
        "started": ISO8601DateFormatter().string(from: start),
      ])
  }

  func event(_ type: String, _ fields: [String: Any] = [:]) {
    var record: [String: Any] = ["type": type, "t": Int(Date().timeIntervalSince(start) * 1000)]
    for (key, value) in fields { record[key] = Self.sanitize(value) }
    queue.async { [self] in
      guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
      handle?.write(data)
      handle?.write(Data([0x0A]))
    }
  }

  func frame(_ frame: FrameRecord, source: String, inferenceMs: Double, fps: Double, personConf: Float?) {
    var fields: [String: Any] = [
      "time": frame.time, "src": source, "infer_ms": inferenceMs, "fps": fps,
    ]
    if let personConf { fields["conf"] = personConf }
    if let swing = frame.swing {
      fields["phase"] = swing.phase.rawValue
      fields["rep"] = swing.repCount
      fields["arm"] = swing.angles.arm
      fields["spine"] = swing.angles.spine
      fields["hip"] = swing.angles.hip
      fields["knee"] = swing.angles.knee
      fields["wrist"] = swing.angles.wristHeight
    }
    event("frame", fields)
  }

  func rep(_ rep: RepRecord, source: String) {
    event(
      "rep",
      [
        "src": source, "number": rep.number, "score": rep.quality.score,
        "feedback": rep.quality.feedback, "hinge_depth": rep.quality.hingeDepth,
        "lockout": rep.quality.lockoutAngle, "knee_flexion": rep.quality.kneeFlexion,
        "positions": rep.positions.mapValues { $0.time }.reduce(into: [String: Double]()) {
          $0[$1.key.rawValue] = $1.value
        },
      ])
  }

  /// JSONSerialization rejects non-finite doubles; round and clamp so a NaN angle can't drop a whole line.
  private static func sanitize(_ value: Any) -> Any {
    switch value {
    case let d as Double: return d.isFinite ? (d * 100).rounded() / 100 : -1
    case let f as Float: return sanitize(Double(f))
    case let dict as [String: Double]: return dict.mapValues { sanitize($0) }
    default: return value
    }
  }
}
