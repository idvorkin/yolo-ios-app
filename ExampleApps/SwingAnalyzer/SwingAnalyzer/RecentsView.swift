// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//  Recents sheet: clips analyzed before, newest first. Tap to reopen instantly; swipe to remove from Recents
//  (never touches Photos).

import SwiftUI

struct RecentsView: View {
  @ObservedObject var store: RecentsStore
  let onOpen: (RecentEntry) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Group {
        if store.entries.isEmpty {
          ContentUnavailableView(
            "No recent sets", systemImage: "clock.arrow.circlepath",
            description: Text("Record a set or import a video and it will show up here."))
        } else {
          List {
            ForEach(store.entries) { entry in
              Button {
                dismiss()
                onOpen(entry)
              } label: {
                RecentRow(entry: entry, thumbnail: store.thumbnailImage(for: entry))
              }
              .buttonStyle(.plain)
            }
            .onDelete { offsets in
              offsets.map { store.entries[$0].id }.forEach { store.remove(id: $0) }
            }
          }
          .listStyle(.plain)
        }
      }
      .navigationTitle("Recents")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
      }
    }
  }
}

struct RecentRow: View {
  let entry: RecentEntry
  let thumbnail: UIImage?

  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
  }()

  var body: some View {
    HStack(spacing: 12) {
      Group {
        if let thumbnail {
          Image(uiImage: thumbnail).resizable().scaledToFill()
        } else {
          Color(.tertiarySystemFill)
        }
      }
      .frame(width: 72, height: 54)
      .clipShape(RoundedRectangle(cornerRadius: 6))

      VStack(alignment: .leading, spacing: 3) {
        Text(Self.dateFormatter.string(from: entry.recordedAt ?? entry.analyzedAt))
          .font(.headline)
        HStack(spacing: 6) {
          Text("\(entry.repCount) reps")
          if let best = entry.bestScore { Text("· best \(best)") }
          Text("· " + Self.duration(entry.duration))
        }
        .font(.subheadline).foregroundStyle(.secondary)
      }
      Spacer()
      Image(systemName: entry.isInPhotos ? "photo.on.rectangle" : "iphone")
        .foregroundStyle(.secondary)
        .accessibilityLabel(entry.isInPhotos ? "In Photos" : "Kept in app")
    }
    .padding(.vertical, 4)
  }

  private static func duration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}
