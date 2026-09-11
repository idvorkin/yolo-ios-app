# Swing Analyzer (iOS)

Kettlebell swing form analysis on top of the `UltralyticsYOLO` pose model. A native port of the
analysis core from [idvorkin/swing-analyzer](https://github.com/idvorkin/swing-analyzer).

- Plays a video from Photos, Files, or a path given via `SWING_VIDEO` (simulator testing).
- Runs `yolo26n-pose` on each displayed frame via `AVPlayerItemVideoOutput`, dropping frames while inference is busy.
- Feeds the most confident person into `KettlebellSwingAnalyzer` (top → connect → bottom → release state machine, rep count, rep quality).
- Overlays the skeleton, spine (yellow), and the right arm (orange) that drive the analysis.

## Keypoints

The web app uses BlazePose-33; YOLO pose models emit COCO-17. Every keypoint the swing analysis needs
(shoulders, elbows, wrists, hips, knees, ankles) exists in both, so `SwingSkeleton.swift` ports the angle math
over COCO indices. Pose-track files are not interchangeable between the two apps.

## Build

```bash
bash ../../scripts/download-models.sh   # once, from the repo root: fetches the nano models
just model                              # copies yolo26n-pose.mlpackage into the app (gitignored)
just run-sim /path/to/swing.mp4         # simulator, auto-loads the video
just run-device                         # connected iPhone (needs an Apple ID signed into Xcode)
```

Sample swing videos live in
[idvorkin-ai-tools/form-analyzer-samples](https://github.com/idvorkin-ai-tools/form-analyzer-samples) as WebM;
convert for iOS with `ffmpeg -i in.webm -c:v libx264 -pix_fmt yuv420p -an out.mp4`.
