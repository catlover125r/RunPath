# RunPath

A native iOS app that turns GPX routes from COROS (or any fitness app) into cinematic animated route videos.

Import a GPX file, customize the animation with a keyframe timeline, preview it on a live 3D map, and export a 1080×1920 MP4 you can share anywhere.

---

## Features

### Animated Route Replay
- Tilted 3D birds-eye camera follows the path as it draws itself
- Camera heading tracks the direction of travel in real time
- At the end of the replay, the camera smoothly pulls back to show the full route

### Keyframe Timeline Editor
- Six animatable effects, each with its own independent keyframe track
- Diamond-shaped keyframes on a scrubable timeline
- Tap a keyframe to select it, adjust its value with the slider, delete it with the trash button
- Add a keyframe at the playhead position with the + button
- Smooth cubic easing between keyframes

| Effect | Range |
|--------|-------|
| Speed | 0.1× – 4× |
| Path Smoothness | 0% – 100% |
| Camera Altitude | 200 m – 8,000 m |
| Camera Tilt | 0° – 80° |
| Line Thickness | 1 pt – 12 pt |
| Line Color | Full hue wheel |

### Route Library
- Hamburger menu slides in a left drawer with all imported routes sorted by date
- Three-dot menu on each route for deletion
- Routes persist across app launches

### Import
- Share a GPX file from COROS (or any app) directly to RunPath via the iOS share sheet
- No account or internet connection required

### Export
- Renders a 1080×1920 H.264 MP4 at 30fps
- Progress ring during render
- Share sheet on completion

---

## Requirements

- iOS 17.0+
- Xcode 16+
- Apple Developer account (for device deployment)

---

## Getting Started

```bash
# Clone the repo
git clone https://github.com/catlover125r/RunPath.git
cd RunPath/RunPath

# Generate the Xcode project (if needed)
brew install xcodegen
xcodegen generate

# Open in Xcode
open RunPath.xcodeproj
```

In Xcode:
1. Select your development team under **Signing & Capabilities**
2. Choose your connected iPhone as the run destination
3. Press **Run**

---

## Importing from COROS

1. Open the COROS app and go to an activity
2. Tap the share icon → **Export GPX**
3. In the share sheet, tap **RunPath**
4. The route appears in your library immediately

Any app that can share a `.gpx` file works the same way.

---

## Project Structure

```
RunPath/
├── Sources/RunPath/
│   ├── Models/
│   │   ├── GPXRoute.swift          # Route data model
│   │   └── AnimationEffect.swift   # Effect types, keyframes, interpolation
│   ├── Services/
│   │   ├── GPXParser.swift         # XML GPX parser
│   │   ├── RouteStorage.swift      # JSON persistence
│   │   └── VideoExporter.swift     # MP4 rendering via MKMapSnapshotter + AVFoundation
│   ├── ViewModels/
│   │   └── AnimationViewModel.swift # Playback engine (CADisplayLink), keyframe editing
│   └── Views/
│       ├── AnimatedMapView.swift    # MKMapView with 3D camera and path overlay
│       ├── ContentView.swift        # Root layout, GPX import handler
│       ├── SidebarView.swift        # Route library drawer
│       ├── TimelineView.swift       # Scrubable timeline with diamond keyframes
│       ├── EffectControlsView.swift # Effect tabs, slider, +/trash buttons
│       └── ExportView.swift         # Export progress and share sheet
└── project.yml                     # XcodeGen spec
```

---

## Tech Stack

- **SwiftUI** — UI
- **MapKit** — 3D map rendering and MKMapCamera
- **AVFoundation** — MP4 encoding via AVAssetWriter
- **XMLParser** — GPX parsing
- **CADisplayLink** — 60fps animation loop
- **Swift 6** — strict concurrency throughout

---

## Design

Minimalist dark UI. The map is the hero — controls overlay as a translucent bottom panel. No clutter.
