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

    private var displayLink: CADisplayLink?
    private var lastTickTime: CFTimeInterval = 0        // incremental dt timing
    private let totalAnimationDuration: Double = 12.0  // base seconds at 1x speed

    // Smoothed-coordinate cache keyed by smoothness bucket (steps of 0.05 → 21 slots max)
    private var smoothCache: [Int: [CLLocationCoordinate2D]] = [:]

    var currentTrack: EffectTrack {
        animationSettings.track(for: animationSettings.selectedEffect)
    }

    func loadRoute(_ route: GPXRoute) {
        self.route = route
        smoothCache = [:]
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
        let key = Int((smoothness * 20).rounded())
        if let cached = smoothCache[key] {
            if smoothedCoordinates.count != cached.count || smoothedCoordinates.first?.latitude != cached.first?.latitude {
                smoothedCoordinates = cached
            }
            return
        }
        let result = applySmoothing(route.clCoordinates, factor: Double(key) / 20.0)
        smoothCache[key] = result
        smoothedCoordinates = result
    }

    private func applySmoothing(_ coords: [CLLocationCoordinate2D], factor: Double) -> [CLLocationCoordinate2D] {
        guard coords.count > 5, factor > 0.01 else { return coords }
        let radius = max(1, Int(factor * 40))
        let n = coords.count
        var result = coords
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
        lastTickTime = 0  // reset so first tick uses nominal dt, not a stale delta
        startDisplayLink()
    }

    func pause() {
        guard playbackState == .playing else { return }
        playbackState = .paused
        stopDisplayLink()
    }

    func seek(to value: Double) {
        progress = max(0, min(1, value))
        timelinePosition = progress
        if playbackState == .playing {
            lastTickTime = 0  // reset so the next tick doesn't jump from stale delta
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

    // Incremental integration: each tick advances by (realDt * speed) / baseDuration.
    // This means speed changes take effect immediately with no jump, and seeking during
    // playback also doesn't cause overshooting.
    @objc nonisolated private func tick() {
        MainActor.assumeIsolated {
            guard playbackState == .playing else { return }

            let now = CACurrentMediaTime()
            let dt: Double
            if lastTickTime > 0 {
                dt = min(now - lastTickTime, 0.1)  // cap at 100ms to survive backgrounding
            } else {
                dt = 1.0 / 60.0  // nominal first-frame delta
            }
            lastTickTime = now

            let speed = animationSettings.value(for: .speed, at: progress)
            let dp = (dt * max(0.1, speed)) / totalAnimationDuration
            let newProgress = min(1.0, progress + dp)

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
        let val = currentTrack.value(at: timelinePosition)
        currentTrack.addKeyframe(at: timelinePosition, value: val)
        if let newKF = currentTrack.keyframes.min(by: {
            abs($0.position - timelinePosition) < abs($1.position - timelinePosition)
        }) { selectedKeyframeID = newKF.id }
        objectWillChange.send()
    }

    func deleteSelectedKeyframe() {
        guard let kfID = selectedKeyframeID else { return }
        currentTrack.removeKeyframe(id: kfID)
        selectedKeyframeID = nil
        objectWillChange.send()
    }

    func selectKeyframe(_ id: UUID?) {
        selectedKeyframeID = id
    }

    func sliderValueForPlayhead() -> Double {
        if let kfID = selectedKeyframeID,
           let kf = currentTrack.keyframes.first(where: { $0.id == kfID }) {
            return kf.value
        }
        return currentTrack.value(at: timelinePosition)
    }

    func setSliderValue(_ v: Double) {
        let effect = animationSettings.selectedEffect
        let clamped = max(effect.range.lowerBound, min(effect.range.upperBound, v))

        if let kfID = selectedKeyframeID,
           let idx = currentTrack.keyframes.firstIndex(where: { $0.id == kfID }) {
            currentTrack.keyframes[idx].value = clamped
        } else {
            for i in currentTrack.keyframes.indices
            where currentTrack.keyframes[i].position <= 0.001
               || currentTrack.keyframes[i].position >= 0.999 {
                currentTrack.keyframes[i].value = clamped
            }
        }
        // Invalidate smoothness cache when smoothness changes
        if effect == .smoothness { smoothCache = [:] }
        objectWillChange.send()
        applyLivePreview(effect, value: clamped)
    }

    func nudge(_ delta: Double) {
        let current = sliderValueForPlayhead()
        setSliderValue(current + delta)
    }

    private func applyLivePreview(_ effect: EffectType, value: Double) {
        switch effect {
        case .cameraAltitude: cameraAltitude = value
        case .cameraTilt:     cameraPitch    = value
        case .lineThickness:  lineWidth      = value
        case .lineColor:      lineHue        = value
        case .smoothness:
            updateSmoothedCoords(smoothness: value)
            let count = Int(Double(smoothedCoordinates.count) * timelinePosition)
            visibleCoordinateCount = max(0, min(count, smoothedCoordinates.count))
        default: break
        }
    }

    nonisolated deinit {}
}
