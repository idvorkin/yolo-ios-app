# Swing Analyzer (iOS) — User Stories

The native counterpart of the web app's [USER_JOURNEY.md](https://github.com/idvorkin/swing-analyzer/blob/main/docs/USER_JOURNEY.md).
Each story has success criteria; the status column records what has been exercised where.

| Status | Meaning |
| --- | --- |
| ✅ sim | Verified in the iOS simulator (file playback, offline pass, trim, gallery, replay) |
| ✅ phone | Verified on Igor's iPhone |
| ⏳ | Built, not yet exercised (camera paths need the phone) |
| 💡 | Not built; candidate for later |

---

## 1. Record a set

**As a lifter, I prop my phone up, tap one button, do my swings, and tap Done. The app keeps only the part where I swung.**

1. Tap the camera icon. The preview appears with a red REC badge. Recording starts immediately; no separate record button.
2. Swing. The HUD shows the live rep count, current phase (TOP / CONNECT / BOTTOM / RELEASE), and spine / arm / hip / knee angles.
3. Tap **Done**. The app stops, trims the recording to the span where reps happened (one second of padding each side), and re-analyzes every frame of the clip.
4. The trimmed clip loads in the player with the gallery underneath.

Success criteria:

- [ ] ⏳ Camera preview appears within a second and the overlay lines up with my body.
- [ ] ⏳ Live rep count keeps up at 30 fps on the phone (log `fps` in `frame` events).
- [ ] ⏳ Done produces a clip that starts one second before the first rep and ends one second after the last.
- [ ] ⏳ Front camera works (flip button) so I can watch the HUD while swinging.
- [ ] ⏳ Cancel (x) throws the recording away and returns to the empty state.
- [ ] 💡 Lead-in countdown so I can walk from the phone to the bell before recording starts.
- [ ] 💡 Landscape camera. Orientation is fixed at whatever it was when the camera opened.

## 2. Review a set

**As a lifter, I want the analysis to be right, not just fast, so I trust the rep count and quality scores.**

1. After Done (or after importing a video) the offline pass runs over every frame with a progress bar.
2. The rep count, gallery, and quality scores come from the offline pass, which replaces the live results.
3. The HUD line reports frames analyzed, elapsed time, and reps found.

Success criteria:

- [x] ✅ sim Every frame is analyzed in order, none dropped (165 / 165 and 593 / 593 frames on the samples).
- [x] ✅ sim The 4-rep sample yields 4 reps; the 9-rep one-hand sample yields 9.
- [x] ✅ sim A horizontally mirrored copy of a video yields the same reps and near-identical angles (joints are chosen by confidence, not by left/right label).
- [ ] ⏳ Offline pass speed on the phone (target: at least 2× real time; log `offline_pass.fps`).
- [ ] 💡 Show live-vs-offline rep count disagreement when they differ.

## 3. Scrub and replay

**As a lifter, I want to scrub through the clip and see the skeleton and angles at that exact frame without waiting.**

1. Play, pause, scrub, and step frame by frame. The overlay and HUD update from the stored pose track; no inference runs.
2. Speed control: ¼×, ½×, 1×.
3. The eye button hides or shows the skeleton over the video. The choice persists.

Success criteria:

- [x] ✅ sim Overlay follows the video during playback and after seeks (phase events in the log line up with position times).
- [x] ✅ sim After a trim, the replayed track is shifted so it still lines up (fixed: passthrough export left a 7 s timeline offset; the trim now re-encodes).
- [ ] ⏳ Frame stepping lands on distinct frames on the phone.
- [ ] ⏳ Skeleton toggle hides the overlay in both the main view and the full-screen viewer.

## 4. Navigate by rep and checkpoint

**As a lifter, I want to jump straight to the bottom of rep 3 or the top of rep 7, not hunt with the scrubber.**

1. Previous / next rep buttons seek to the start of the neighboring rep.
2. Previous / next checkpoint buttons seek to the nearest phase peak (top, connect, bottom, release).
3. The current rep's row is highlighted in the gallery and scrolls into view.

Success criteria:

- [x] ✅ sim Current rep highlight tracks the playhead.
- [ ] ⏳ Rep and checkpoint buttons land on the right frames on the phone.

## 5. Rep gallery

**As a lifter, I want to see all my reps side by side at the same phase so I can spot the sloppy ones.**

1. Under the video: one row per rep, four thumbnails (bottom, release, top, connect) with the skeleton drawn on, plus the rep number and quality score.
2. Tap a thumbnail to seek there. Tap a phase header to zoom that column.
3. Double-tap a thumbnail to zoom its column and enlarge that rep's row. Double-tap again to reset.
4. Grid button opens the full-screen gallery; select 2–4 reps and tap Compare to see them side by side with feedback lines.

Success criteria:

- [x] ✅ sim Thumbnails show the correct peak frame per phase.
- [x] ✅ sim Phase header zoom widens the chosen column.
- [ ] ⏳ Double-tap zoom, long-press, and the compare sheet on the phone.
- [ ] 💡 Swipe between reps in compare mode.

## 6. Look closely at a keyframe

**As a lifter, I want to blow up a single keyframe, zoom into my hips or my wrists, and step to the next checkpoint without leaving that view.**

1. Long-press a thumbnail, or tap the expand button, to open the full-screen viewer on the paused video at that frame.
2. Pinch to zoom (up to 6×), drag to pan, double-tap to toggle 2.5×.
3. Bottom bar steps by frame, checkpoint, or rep. Top bar shows rep, phase, angles, the skeleton toggle, and close.

Success criteria:

- [ ] ⏳ Viewer opens on the right frame and the overlay stays aligned while zoomed.
- [ ] ⏳ Stepping inside the viewer updates the overlay and the angle readout.

## 7. Quality feedback

**As a lifter, I want one line of coaching per rep that tells me the biggest thing to fix.**

1. Each rep gets a score out of 100 and feedback lines: hinge depth, lockout, and squat-vs-hinge (knee flexion).
2. The HUD shows the last rep's score and feedback; the gallery shows every rep's score.

Success criteria:

- [x] ✅ sim Scores and feedback match the web analyzer's rules (same thresholds, ported line for line).
- [ ] 💡 Wrist speed in m/s, calibrated by user height (web app has it; needs a settings screen).
- [ ] 💡 Per-set summary: best rep, worst rep, trend across the set.

## 8. Import a video

**As a lifter, I want to analyze a video I already recorded, from Photos or a file.**

1. Import menu: Photos picker or Files browser.
2. The clip loads, the offline pass runs with progress, playback starts with the pose track.
3. Scissors button trims the imported clip to its reps.

Success criteria:

- [x] ✅ sim `SWING_VIDEO=/path` auto-load, offline pass, and trim.
- [ ] ⏳ Photos and Files pickers on the phone, including portrait videos with rotation metadata (the offline pass applies the track transform; needs a real phone recording to confirm end to end).

## 9. Save

**As a lifter, I want the trimmed clip in Photos so I can share it or keep it.**

1. Save button writes the trimmed clip (or the imported clip if untrimmed) to the Photos library.
2. The HUD confirms "Saved to Photos".

Success criteria:

- [ ] ⏳ Add-only Photos permission prompt appears once; the clip lands in Recents.
- [ ] 💡 Save the phase stills as well (decided against for now; the gallery covers it).

## 10. Diagnose a bad session

**As the developer (human or agent), I want a log I can pull from the phone and understand without re-watching the video.**

1. Every session writes JSON Lines to `Documents/logs/`, visible in Finder and the Files app.
2. Events: session start, model load, load, install_item, play, per-frame timing and angles, phase transitions, reps with positions and quality, camera start/done/cancel with frames delivered vs analyzed, trim decisions, offline pass summary, save, errors.
3. `just pull-logs` copies the phone's logs to `~/tmp/agent/swing-logs`; `just log-summary` prints everything but per-frame rows.

Success criteria:

- [x] ✅ sim The 7 s trim offset bug was found and confirmed fixed from the log alone.
- [ ] ⏳ `just pull-logs` from the phone.
- [ ] 💡 A `just log-plot` that charts arm and spine angle over time with phase bands.

---

## Not planned (from the web app)

- Pistol squat analyzer and automatic exercise detection.
- Bug report modal, shake to report, version notifications (web deployment concerns).
- Pose-track file export: the web app's format is BlazePose-33; this app is COCO-17.
