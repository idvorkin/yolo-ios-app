// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

//  Swing Analyzer: kettlebell-swing form analysis on top of the UltralyticsYOLO pose model.
//  Plays a video file, runs pose estimation on each frame, and drives a swing phase state machine
//  ported from https://github.com/idvorkin/swing-analyzer.

import SwiftUI

@main
struct SwingAnalyzerApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}
