import Foundation
import Combine
import MapKit
import SwiftUI

enum PlaybackState {
    case idle, playing, paused, finished
}

@MainActor
class AnimationViewModel: ObservableObject {

    @Published var route: GPXRoute?
    @Published var animationSettings = AnimationSettings()
    @Published var playbackState: PlaybackState = .idle
    @Published var progress: Double = 0.0          // 0..1
    @Published var timelinePosition: Double = 0.0  // 0..1 playhead for editing
    @Published var selectedKeyframeID: UUID?
    @Published var visibleCoordinateCount: Int = 0
    @Published var showFullRoute = false

    // Map state driven by animation
    @Published var cameraAltitude: Double = 1200
    @Published var cameraPitch: Double = 55
    @Published var lineWidth: Double = 5
    @Published var lineHue: Double = 0.58
    @Published var smoothedCoordinates: [CLLocationCoordinate2D] = []

    // Scratchpad: slider value preview when no keyframe is selected (not persisted)
    @Published var scratchpadValue: Double? = nil

    private var displayLink: CADisplayLink?
    private var animationStartTime: CFTimeInterval = 0
    private var pausedProgress: Double = 0
    private var totalAnimationDuration: Double = 12.0  // base seconds for full route at 1x speed

    var currentTrack: EffectTrack {
        animationSettings.track(for: animationSettings.selectedEffect)
    }

    func loadRoute(_ route: GPXRoute) {
        self.route = route
        progress = 0
        timelinePosition = 0
        playbackState = .idle
        showFullRoute = false
        selectedKeyframeID = nil
        animationSettings = AnimationSettings()
        updateSmoothedCoords(smoothness: animationSettings.value(for: .smoothness, at: 0))
        syncCameraToProgress(0)
        visibleCoordinateCount = 0
    }

    private func updateSmoothedCoords(smoothness: Double) {
        guard let route = route else { return }
        let raw = route.clCoordinates
        smoothedCoordinates = applySmoothing(raw, factor: smoothness)
    }

    private func applySmoothing(_ coords: [CLLocationCoordinate2D], factor: Double) -> [CLLocationCoordinate2D] {
        guard coords.count > 5, factor > 0.01 else { return coords }
        // Box filter with a large sliding window — up to 40 points on each side (81-pt window at max)
        let radius = max(1, Int(factor * 40))
        let n = coords.count
        var result = coords
        // Two passes for a smoother bell-curve-like response
        for _ in 0..<2 {
            var pass = result
            for i in 1..<(n - 1) {
                let lo = max(0, i - radius)
                let hi = min(n - 1, i + radius)
                let count = Double(hi - lo + 1)
                var lat = 0.0, lon = 0.0
                for j in lo...hi { lat += result[j].latitude; lon += result[j].longitude }
                pass[i] = CLLocationCoordinate2D(latitude: lat / count, longitude: lon / count)
            }
            result = pass
        }
        return result
    }

    func play() {
        guard route != nil else { return }
        if playbackState == .finished { progress = 0; showFullRoute = false }
        playbackState = .playing
        pausedProgress = progress
        animationStartTime = CACurrentMediaTime()
        startDisplayLink()
    }

    func pause() {
        guard playbackState == .playing else { return }
        pausedProgress = progress
        playbackState = .paused
        stopDisplayLink()
    }

    func seek(to value: Double) {
        progress = max(0, min(1, value))
        timelinePosition = progress
        if playbackState == .playing {
            pausedProgress = progress
            animationStartTime = CACurrentMediaTime()
        }
        syncVisuals(to: progress)
        if playbackState != .playing { showFullRoute = progress >= 1 }
    }

    private func startDisplayLink() {
        stopDisplayLink()
        let dl = CADisplayLink(target: self, selector: #selector(tick))
        dl.add(to: .main, forMode: .common)
        displayLink = dl
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc nonisolated private func tick() {
        MainActor.assumeIsolated {
            guard playbackState == .playing else { return }
            let elapsed = CACurrentMediaTime() - animationStartTime
            let speed = animationSettings.value(for: .speed, at: progress)
            let clamped = max(0.1, speed)
            let fraction = (elapsed * clamped) / totalAnimationDuration
            let newProgress = min(1.0, pausedProgress + fraction)
            progress = newProgress
            timelinePosition = newProgress
            syncVisuals(to: newProgress)

            if newProgress >= 1.0 {
                playbackState = .finished
                stopDisplayLink()
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    withAnimation(.easeInOut(duration: 1.2)) {
                        self?.showFullRoute = true
                    }
                }
            }
        }
    }

    private func syncVisuals(to p: Double) {
        let smoothness = animationSettings.value(for: .smoothness, at: p)
        updateSmoothedCoords(smoothness: smoothness)

        let count = Int(Double(smoothedCoordinates.count) * p)
        visibleCoordinateCount = max(0, min(count, smoothedCoordinates.count))

        syncCameraToProgress(p)
        lineWidth = animationSettings.value(for: .lineThickness, at: p)
        lineHue = animationSettings.value(for: .lineColor, at: p)
    }

    private func syncCameraToProgress(_ p: Double) {
        cameraAltitude = animationSettings.value(for: .cameraAltitude, at: p)
        cameraPitch = animationSettings.value(for: .cameraTilt, at: p)
    }

    // MARK: Keyframe editing

    func addKeyframeAtPlayhead() {
        // Use scratchpad value if the user has dragged the slider, else use interpolated value
        let val = scratchpadValue ?? currentTrack.value(at: timelinePosition)
        currentTrack.addKeyframe(at: timelinePosition, value: val)
        scratchpadValue = nil
        // Select the newly created keyframe
        if let newKF = currentTrack.keyframes.min(by: {
            abs($0.position - timelinePosition) < abs($1.position - timelinePosition)
        }) { selectedKeyframeID = newKF.id }
        animationSettings.objectWillChange.send()
    }

    func deleteSelectedKeyframe() {
        guard let kfID = selectedKeyframeID else { return }
        currentTrack.removeKeyframe(id: kfID)
        selectedKeyframeID = nil
        scratchpadValue = nil
        animationSettings.objectWillChange.send()
    }

    func selectKeyframe(_ id: UUID?) {
        selectedKeyframeID = id
        scratchpadValue = nil
    }

    func sliderValueForPlayhead() -> Double {
        // Selected keyframe wins, then scratchpad preview, then interpolated
        if let kfID = selectedKeyframeID,
           let kf = currentTrack.keyframes.first(where: { $0.id == kfID }) {
            return kf.value
        }
        return scratchpadValue ?? currentTrack.value(at: timelinePosition)
    }

    func setSliderValue(_ v: Double) {
        if let kfID = selectedKeyframeID,
           let idx = currentTrack.keyframes.firstIndex(where: { $0.id == kfID }) {
            // Update the selected keyframe in place
            currentTrack.keyframes[idx].value = v
            animationSettings.objectWillChange.send()
        } else {
            // Just preview — store in scratchpad, do NOT create a keyframe
            scratchpadValue = v
        }
        // Always apply visually so the user sees the change immediately
        applyEffectPreview(animationSettings.selectedEffect, value: v)
    }

    private func applyEffectPreview(_ effect: EffectType, value: Double) {
        switch effect {
        case .cameraAltitude: cameraAltitude = value
        case .cameraTilt: cameraPitch = value
        case .lineThickness: lineWidth = value
        case .lineColor: lineHue = value
        default: break
        }
    }

    func resetScratchpadOnEffectChange() {
        scratchpadValue = nil
        selectedKeyframeID = nil
    }

    nonisolated deinit {}
}
