// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//  Recents: clips analyzed before, with their analysis kept in the app so reopening is instant.
//  Clips that live in Photos (imports, saved recordings) are pointed to by identifier; recordings not yet saved
//  are kept as files under Documents/recents/<id>/ until saved or removed.

import AVFoundation
import Foundation
import Photos
import UIKit

struct RecentEntry: Codable, Identifiable {
  enum Source: Codable {
    case photos(identifier: String)
    case file(name: String)

    var isPhotos: Bool {
      if case .photos = self { return true }
      return false
    }
  }

  let id: String
  var analyzedAt: Date
  var recordedAt: Date?
  var duration: Double
  var repCount: Int
  var bestScore: Int?
  var source: Source
  var thumbnail: String?

  var isInPhotos: Bool {
    if case .photos = source { return true }
    return false
  }
}

private struct AnalysisSnapshot: Codable {
  let frames: [FrameRecord]
  let reps: [RepRecord]
}

@MainActor
final class RecentsStore: ObservableObject {
  @Published private(set) var entries: [RecentEntry] = []

  private let root: URL
  private var indexURL: URL { root.appendingPathComponent("index.json") }

  init() {
    root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("recents", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if let data = try? Data(contentsOf: indexURL),
      let decoded = try? JSONDecoder().decode([RecentEntry].self, from: data)
    {
      entries = decoded.sorted { $0.analyzedAt > $1.analyzedAt }
    }
  }

  func folder(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

  func entry(id: String) -> RecentEntry? { entries.first { $0.id == id } }

  /// Adds or replaces an entry, writing its analysis, rep images, and (for file sources) the clip itself.
  func save(
    id: String, source: RecentEntry.Source, recordedAt: Date?, duration: Double, pipeline: SwingPipeline,
    clipURL: URL?, thumbnail: UIImage?
  ) throws {
    let dir = folder(for: id)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    if case .file(let name) = source, let clipURL {
      let dest = dir.appendingPathComponent(name)
      if dest != clipURL {
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: clipURL, to: dest)
      }
    }

    let snapshot = AnalysisSnapshot(frames: pipeline.track.frames, reps: pipeline.reps)
    try JSONEncoder().encode(snapshot).write(to: dir.appendingPathComponent("analysis.json"))
    for rep in pipeline.reps {
      for (phase, position) in rep.positions {
        guard let image = position.image, let data = image.jpegData(compressionQuality: 0.8) else { continue }
        try data.write(to: dir.appendingPathComponent(Self.imageName(rep: rep.number, phase: phase)))
      }
    }
    var thumbnailName: String?
    if let thumbnail, let data = thumbnail.jpegData(compressionQuality: 0.8) {
      thumbnailName = "thumbnail.jpg"
      try data.write(to: dir.appendingPathComponent(thumbnailName!))
    }

    let entry = RecentEntry(
      id: id, analyzedAt: Date(), recordedAt: recordedAt, duration: duration,
      repCount: pipeline.reps.count, bestScore: pipeline.reps.map(\.quality.score).max(),
      source: source, thumbnail: thumbnailName)
    entries.removeAll { $0.id == id }
    entries.insert(entry, at: 0)
    try persistIndex()
  }

  func remove(id: String) {
    entries.removeAll { $0.id == id }
    try? FileManager.default.removeItem(at: folder(for: id))
    try? persistIndex()
  }

  /// After a local recording is saved to Photos: point at the asset and drop the in-app copy.
  func markSavedToPhotos(id: String, identifier: String) {
    guard var entry = entry(id: id) else { return }
    if case .file(let name) = entry.source {
      try? FileManager.default.removeItem(at: folder(for: id).appendingPathComponent(name))
    }
    entry.source = .photos(identifier: identifier)
    entries = entries.map { $0.id == id ? entry : $0 }
    try? persistIndex()
  }

  func thumbnailImage(for entry: RecentEntry) -> UIImage? {
    guard let name = entry.thumbnail else { return nil }
    return UIImage(contentsOfFile: folder(for: entry.id).appendingPathComponent(name).path)
  }

  /// The stored analysis with rep images re-attached.
  func loadPipeline(for entry: RecentEntry) -> SwingPipeline? {
    let dir = folder(for: entry.id)
    guard let data = try? Data(contentsOf: dir.appendingPathComponent("analysis.json")),
      let snapshot = try? JSONDecoder().decode(AnalysisSnapshot.self, from: data)
    else { return nil }
    let reps = snapshot.reps.map { rep in
      RepRecord(
        number: rep.number,
        positions: rep.positions.mapValues { position in
          var restored = position
          restored.image = UIImage(
            contentsOfFile: dir.appendingPathComponent(Self.imageName(rep: rep.number, phase: position.phase)).path)
          return restored
        },
        quality: rep.quality)
    }
    return SwingPipeline.restored(frames: snapshot.frames, reps: reps)
  }

  /// A playable URL for the entry's clip: the in-app file, or the Photos asset (nil if it was deleted).
  func clipURL(for entry: RecentEntry) async -> URL? {
    switch entry.source {
    case .file(let name):
      let url = folder(for: entry.id).appendingPathComponent(name)
      return FileManager.default.fileExists(atPath: url.path) ? url : nil
    case .photos(let identifier):
      return await Self.photosClipURL(identifier: identifier)
    }
  }

  static func photosClipURL(identifier: String) async -> URL? {
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    else { return nil }
    let options = PHVideoRequestOptions()
    options.isNetworkAccessAllowed = true
    options.deliveryMode = .highQualityFormat
    return await withCheckedContinuation { continuation in
      var resumed = false
      PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: (avAsset as? AVURLAsset)?.url)
      }
    }
  }

  static func photosAssetDate(identifier: String) -> Date? {
    PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject?.creationDate
  }

  private static func imageName(rep: Int, phase: SwingPhase) -> String { "rep-\(rep)-\(phase.rawValue).jpg" }

  private func persistIndex() throws {
    try JSONEncoder().encode(entries).write(to: indexURL)
  }
}
