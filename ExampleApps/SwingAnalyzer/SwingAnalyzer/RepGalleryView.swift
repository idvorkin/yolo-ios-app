// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//  Rep gallery, ported from swing-analyzer's RepGalleryWidget / RepGalleryModal: rows of reps × phase thumbnails.
//  Tap a thumbnail to seek, tap a phase header to zoom that column, select reps in the sheet to compare.

import SwiftUI

/// Inline gallery shown under the video.
struct RepGalleryWidget: View {
  let reps: [RepRecord]
  let currentRep: Int?
  @Binding var focusedPhase: SwingPhase?
  @Binding var focusedRep: Int?
  let onSeek: (RepPosition) -> Void
  let onOpen: (RepPosition) -> Void

  var body: some View {
    GeometryReader { geo in
      ScrollViewReader { proxy in
        ScrollView(.vertical) {
          LazyVStack(spacing: 4, pinnedViews: [.sectionHeaders]) {
            Section {
              ForEach(reps) { rep in
                RepRow(
                  rep: rep, isCurrent: rep.number == currentRep, focusedPhase: focusedPhase,
                  width: geo.size.width, height: rep.number == focusedRep ? 150 : 72,
                  onSeek: onSeek,
                  onFocus: { phase in
                    withAnimation(.easeInOut(duration: 0.2)) {
                      if focusedRep == rep.number && focusedPhase == phase {
                        focusedRep = nil
                        focusedPhase = nil
                      } else {
                        focusedRep = rep.number
                        focusedPhase = phase
                      }
                    }
                  },
                  onOpen: onOpen
                )
                .id(rep.number)
              }
            } header: {
              PhaseHeader(focusedPhase: $focusedPhase, width: geo.size.width)
            }
          }
        }
        .onChange(of: currentRep) { _, rep in
          if let rep { withAnimation { proxy.scrollTo(rep, anchor: .center) } }
        }
        .onChange(of: reps.count) { _, _ in
          if let last = reps.last { withAnimation { proxy.scrollTo(last.number, anchor: .bottom) } }
        }
      }
    }
  }
}

/// Column layout shared by the widget and the sheet: rep-number gutter plus four phase columns, with the focused
/// phase taking most of the width.
enum GalleryLayout {
  static let gutter: CGFloat = 28
  static let spacing: CGFloat = 4

  static func columnWidth(for phase: SwingPhase, focused: SwingPhase?, totalWidth: CGFloat) -> CGFloat {
    let available = totalWidth - gutter - spacing * CGFloat(SwingPhase.displayOrder.count)
    guard let focused else { return available / CGFloat(SwingPhase.displayOrder.count) }
    return phase == focused ? available * 0.55 : available * 0.45 / 3
  }
}

struct PhaseHeader: View {
  @Binding var focusedPhase: SwingPhase?
  let width: CGFloat

  var body: some View {
    HStack(spacing: GalleryLayout.spacing) {
      Text("Rep").frame(width: GalleryLayout.gutter)
      ForEach(SwingPhase.displayOrder, id: \.self) { phase in
        Button {
          withAnimation(.easeInOut(duration: 0.2)) {
            focusedPhase = focusedPhase == phase ? nil : phase
          }
        } label: {
          Text(phase.rawValue.capitalized)
            .frame(
              width: GalleryLayout.columnWidth(for: phase, focused: focusedPhase, totalWidth: width))
        }
        .buttonStyle(.plain)
        .fontWeight(focusedPhase == phase ? .bold : .regular)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.vertical, 4)
    .background(Color(.systemBackground))
  }
}

struct RepRow: View {
  let rep: RepRecord
  let isCurrent: Bool
  let focusedPhase: SwingPhase?
  let width: CGFloat
  let height: CGFloat
  let onSeek: (RepPosition) -> Void
  var onFocus: ((SwingPhase) -> Void)? = nil
  var onOpen: ((RepPosition) -> Void)? = nil

  var body: some View {
    HStack(spacing: GalleryLayout.spacing) {
      VStack(spacing: 2) {
        Text("\(rep.number)").font(.headline.monospacedDigit())
        Text("\(rep.quality.score)").font(.caption2).foregroundStyle(.secondary)
      }
      .frame(width: GalleryLayout.gutter)
      ForEach(SwingPhase.displayOrder, id: \.self) { phase in
        PoseThumbnail(position: rep.positions[phase])
          .frame(
            width: GalleryLayout.columnWidth(for: phase, focused: focusedPhase, totalWidth: width),
            height: height
          )
          .onTapGesture(count: 2) { onFocus?(phase) }
          .onTapGesture {
            if let position = rep.positions[phase] { onSeek(position) }
          }
          .onLongPressGesture {
            if let position = rep.positions[phase] {
              onSeek(position)
              onOpen?(position)
            }
          }
      }
    }
    .padding(.vertical, 2)
    .background(isCurrent ? Color.accentColor.opacity(0.15) : Color.clear)
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }
}

/// Full-screen gallery with compare mode.
struct RepGallerySheet: View {
  let reps: [RepRecord]
  let currentRep: Int?
  let onSeek: (RepPosition) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var focusedPhase: SwingPhase?
  @State private var selected: Set<Int> = []
  @State private var comparing = false

  var body: some View {
    NavigationStack {
      GeometryReader { geo in
        if comparing {
          compareView(width: geo.size.width)
        } else {
          gridView(width: geo.size.width)
        }
      }
      .navigationTitle(comparing ? "Compare" : "Reps")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(comparing ? "Back" : "Close") {
            if comparing { comparing = false } else { dismiss() }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          if !comparing {
            Button("Compare (\(selected.count))") { comparing = true }
              .disabled(selected.count < 2)
          }
        }
      }
    }
  }

  private func gridView(width: CGFloat) -> some View {
    ScrollView(.vertical) {
      LazyVStack(spacing: 6, pinnedViews: [.sectionHeaders]) {
        Section {
          ForEach(reps) { rep in
            HStack(spacing: 4) {
              Button {
                if selected.contains(rep.number) {
                  selected.remove(rep.number)
                } else if selected.count < 4 {
                  selected.insert(rep.number)
                }
              } label: {
                Image(
                  systemName: selected.contains(rep.number) ? "checkmark.circle.fill" : "circle"
                )
                .foregroundStyle(selected.contains(rep.number) ? Color.accentColor : .secondary)
              }
              .frame(width: 24)
              RepRow(
                rep: rep, isCurrent: rep.number == currentRep, focusedPhase: focusedPhase,
                width: width - 32, height: 110, onSeek: onSeek)
            }
          }
        } header: {
          HStack(spacing: 4) {
            Color.clear.frame(width: 24)
            PhaseHeader(focusedPhase: $focusedPhase, width: width - 32)
          }
        }
      }
      .padding(.horizontal, 4)
    }
  }

  private func compareView(width: CGFloat) -> some View {
    let chosen = reps.filter { selected.contains($0.number) }
    let columnWidth = (width - 8) / CGFloat(max(chosen.count, 1)) - 6
    return ScrollView(.vertical) {
      HStack(alignment: .top, spacing: 6) {
        ForEach(chosen) { rep in
          VStack(spacing: 4) {
            Text("Rep \(rep.number) · \(rep.quality.score)").font(.caption.bold())
            ForEach(SwingPhase.displayOrder, id: \.self) { phase in
              VStack(spacing: 2) {
                PoseThumbnail(position: rep.positions[phase])
                  .frame(width: columnWidth, height: columnWidth * 1.2)
                  .onTapGesture {
                    if let position = rep.positions[phase] { onSeek(position) }
                  }
                Text(phase.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary)
              }
            }
            ForEach(rep.quality.feedback, id: \.self) { line in
              Text(line).font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
          }
          .frame(width: columnWidth)
        }
      }
      .padding(4)
    }
  }
}
