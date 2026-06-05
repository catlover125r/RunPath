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
    @Published var lineWidth: Double = 4
    @Published var lineHue: Double = 0.0
    @Published var smoothedCoordinates: [CLLocationCoordinate2D] = []

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
        guard coords.count > 3, factor > 0 else { return coords }
        let passes = Int(factor * 8)
        var result = coords
        for _ in 0..<passes {
            var pass: [CLLocationCoordinate2D] = [result[0]]
            for i in 1..<result.count - 1 {
                let lat = (result[i-1].latitude + result[i].latitude * 2 + result[i+1].latitude) / 4
                let lon = (result[i-1].longitude + result[i].longitude * 2 + result[i+1].longitude) / 4
                pass.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
            pass.append(result[result.count - 1])
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
        let val = currentTrack.value(at: timelinePosition)
        currentTrack.addKeyframe(at: timelinePosition, value: val)
        animationSettings.objectWillChange.send()
    }

    func deleteSelectedKeyframe() {
        guard let kfID = selectedKeyframeID else { return }
        currentTrack.removeKeyframe(id: kfID)
        selectedKeyframeID = nil
        animationSettings.objectWillChange.send()
    }

    func selectKeyframe(_ id: UUID?) {
        selectedKeyframeID = id
    }

    func updateSelectedKeyframeValue(_ value: Double) {
        guard let kfID = selectedKeyframeID,
              let idx = currentTrack.keyframes.firstIndex(where: { $0.id == kfID }) else { return }
        currentTrack.keyframes[idx].value = value
        animationSettings.objectWillChange.send()
    }

    func sliderValueForPlayhead() -> Double {
        currentTrack.value(at: timelinePosition)
    }

    func setSliderValue(_ v: Double) {
        if let kfID = selectedKeyframeID,
           let idx = currentTrack.keyframes.firstIndex(where: { $0.id == kfID }) {
            currentTrack.keyframes[idx].value = v
        } else {
            currentTrack.addKeyframe(at: timelinePosition, value: v)
            if let newKF = currentTrack.keyframes.last { selectedKeyframeID = newKF.id }
        }
        animationSettings.objectWillChange.send()
    }

    nonisolated deinit {}
}
