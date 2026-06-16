# Reel

A small, focused macOS video editor built with SwiftUI + AVFoundation:

1. **Load** a MOV / MP4 file (open dialog or drag-and-drop).
2. **Import & append** more videos at the end of the timeline — clips of different
   sizes/orientations are aspect-fit into a common frame.
3. **Split & trim** — move the playhead and press **Split** to cut the video into
   chunks; **Delete** a selected chunk, or **Delete Before / After** the playhead
   to trim away the start or end of the current clip.
4. **Reorder** — select a clip and move it earlier/later with the ← / → buttons.
5. **Re-time** — change the playback **speed** of selected chunks (or all of them),
   using presets or any custom value you type in.
6. **Remove audio** with a one-click toggle.
7. **Undo / Redo** every edit.
8. **Preview** with the play button and by scrubbing the slider / dragging the
   timeline playhead. **Zoom** the timeline in/out or **Fit** it to the window.
9. **Export** the result as an **MP4**.

## Requirements

- macOS 14.0 or later
- Xcode 16+ (built and tested with Xcode 26.5)

## Open & run

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
from `project.yml`, and is already generated for you:

```sh
open Reel.xcodeproj
```

Then press **⌘R** in Xcode to build and run. (The first run signs the app to run
locally with your developer identity.)

If you change `project.yml` or add/remove source files, regenerate the project:

```sh
xcodegen generate
```

The bundle identifier is a neutral placeholder (`com.example.reel`); change
`bundleIdPrefix` / `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` to your own before
distributing.

## Keyboard shortcuts

| Action                   | Shortcut    |
|--------------------------|-------------|
| Open video               | ⌘O          |
| Import video at end      | ⌘I          |
| Export as MP4            | ⌘E          |
| Play / Pause             | Space       |
| Split at playhead        | ⌘B          |
| Move clip earlier / later| ⌥⌘← / ⌥⌘→   |
| Delete before playhead   | ⌘[          |
| Delete after playhead    | ⌘]          |
| Delete selected clip     | ⌫           |
| Remove / restore audio   | ⌘M          |
| Zoom in / out / fit      | ⌘+ / ⌘- / ⌘0|
| Undo / Redo              | ⌘Z / ⇧⌘Z    |

## How it works

The whole timeline is just an ordered list of `Chunk`s (`Sources/Models/Chunk.swift`),
each holding a `sourceID`, a source time range, and a speed multiplier. Every edit
takes a snapshot of that list for undo/redo, then rebuilds an `AVMutableComposition`
(`Sources/ViewModels/EditorViewModel.swift`): each chunk's range is appended in
order from its source video and `scaleTimeRange` applies its speed. A matching
`AVVideoComposition` places every source — whatever its size or orientation — into a
common frame (the first clip's), aspect-fit and centred. That composition feeds both
the live `AVPlayer` preview and the `AVAssetExportSession` MP4 export, so what you
preview is exactly what you export.

## Project layout

```
Sources/
  App/         ReelApp.swift, AppCommands.swift   (entry point + menu shortcuts)
  Models/      Chunk.swift                          (timeline data model)
  ViewModels/  EditorViewModel.swift                (player, edits, undo, export)
  Views/       ContentView, HeaderBar, PreviewSection, TransportBar, ControlBar,
               SpeedControl, TimelineView, EmptyStateView, ExportOverlay, StatusToast
  Support/     Theme.swift, Formatting.swift        (styling + helpers)
```

The timeline is horizontally scrollable and zoomable; removing audio drops the
audio track from the composition entirely (affecting both preview and export).
