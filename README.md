# RunPath

A native iOS app that turns GPX activity files into cinematic 3D flyover videos.

## What it does

Import a GPX file from COROS, Garmin, Strava, or any app that exports GPX. RunPath animates a 3D MapKit camera flying along your route and exports it as a polished MP4 video ready to share.

## Features

**Keyframe timeline editor** — Seven animatable tracks, each with independent keyframes and smooth cubic interpolation between them:

| Track | Range | Notes |
|---|---|---|
| Speed | 0.1× – 1.9× | 1.0 is center of slider |
| Smoothness | 0 – 100% | Controls how much camera path is smoothed; drawn path always stays raw |
| Camera Altitude | 100 – 25 000 m | — |
| Camera Tilt | 0 – 85° | — |
| Line Thickness | 1 – 24 pt | Screen-space, zoom-independent |
| Line Color | Hue 0–360° | — |

**Smooth camera heading** — Camera heading is rate-limited to 90°/sec so out-and-back turnarounds pan cinematically instead of snapping 180°.

**Stats overlay** — Optional run stats burnt into the exported video. Portrait: distance (center, large) + time (left) + pace (right) above a bottom gradient. Landscape: stats stack vertically on the left side with a left-edge gradient.

**Export options**
- Portrait (9:16) or Landscape (16:9)
- 1080p or 4K
- Standard or Satellite/Hybrid Flyover map style
- H.264, 30 fps, 8 Mbps
- Auto-saves to Photos library

**Route library** — Swipe left to delete, three-dot menu to rename. Routes persist across launches.

## Requirements

- iOS 17+
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Setup

```bash
git clone https://github.com/catlover125r/RunPath.git
cd RunPath
xcodegen generate
open RunPath.xcodeproj
```

Select your device and run. The app requires a real device for MapKit 3D flyover and photo library access — the simulator does not support flyover map types.

## Importing a GPX file

From any app that can share files (COROS, Garmin Connect, Strava, Files):

1. Share / export the activity as a `.gpx` file
2. Tap **Share** → **RunPath** in the share sheet
3. The route loads automatically and the editor opens

## Architecture

```
Sources/RunPath/
├── Models/
│   ├── GPXRoute.swift          — Parsed route data + formatting helpers
│   └── AnimationEffect.swift   — EffectType, Keyframe, EffectTrack, AnimationSettings
├── ViewModels/
│   └── AnimationViewModel.swift — CADisplayLink playback, keyframe editing, smoothness cache
├── Services/
│   ├── GPXParser.swift         — XMLParser-based GPX reader
│   ├── RouteStorage.swift      — JSON persistence in Documents directory
│   └── VideoExporter.swift     — AVAssetWriter pipeline + MKMapSnapshotter renderer
└── Views/
    ├── ContentView.swift        — Root layout, map/controls composition
    ├── AnimatedMapView.swift    — UIViewRepresentable wrapping MKMapView + CAShapeLayer path overlay
    ├── TimelineView.swift       — Keyframe diamond editor
    ├── EffectControlsView.swift — Per-effect slider with ± nudge buttons
    ├── ExportView.swift         — Export options sheet with live stats preview
    └── SidebarView.swift        — Route library drawer
```

**Key implementation notes:**

- Path rendering uses a `CAShapeLayer` in screen-space (`PathOverlayView`) rather than `MKOverlayRenderer`, so line width is zoom-invariant and stays crisp during camera motion.
- The camera follows `smoothedCoordinates` (sliding-box filter, cached per smoothness bucket) for heading and position, while the drawn path always uses raw GPS coordinates.
- Camera heading is rate-limited in both live preview (via `CACurrentMediaTime()` delta) and export (sequential pre-computation pass before the parallel snapshot phase).
- Export headings are pre-computed sequentially before `withTaskGroup` snapshot rendering to avoid shared mutable state across concurrent tasks.
- `AnimatedMapView.Coordinator` subscribes to `vm.objectWillChange` via Combine (`.delay(.zero)`) rather than relying on SwiftUI's `updateUIView`, ensuring camera altitude/tilt respond immediately to slider input.
