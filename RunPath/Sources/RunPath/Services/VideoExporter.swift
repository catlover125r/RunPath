import Foundation
import AVFoundation
import MapKit
import UIKit

struct FrameParams {
    let index: Int
    let visibleCount: Int
    let altitude: Double
    let pitch: Double
    let lineWidth: CGFloat
    let lineHue: Double
    let smoothness: Double
    let showFull: Bool
    let isLandscape: Bool
    let showStats: Bool
    let heading: CLLocationDirection
}

@MainActor
class VideoExporter {

    struct ExportConfig {
        var resolution: CGSize = CGSize(width: 1080, height: 1920)
        var orientation: ExportOrientation = .portrait
        var frameRate: Int32 = 30
        var videoBitrate: Int = 8_000_000
        var mapType: MKMapType = .standard
        var showStats: Bool = false
    }

    enum ExportError: LocalizedError {
        case assetWriterFailed, cancelled

        var errorDescription: String? {
            switch self {
            case .assetWriterFailed: return "Failed to create video writer."
            case .cancelled: return "Export cancelled."
            }
        }
    }

    private var cancelled = false

    func cancel() { cancelled = true }

    func export(
        route: GPXRoute,
        settings: AnimationSettings,
        config: ExportConfig = ExportConfig(),
        progress: @escaping @Sendable (Double) -> Void,
        completion: @escaping @Sendable (Result<URL, Error>) -> Void
    ) {
        cancelled = false
        Task {
            do {
                let url = try await render(route: route, settings: settings, config: config, progress: progress)
                completion(.success(url))
            } catch {
                completion(.failure(error))
            }
        }
    }

    // MARK: - Render pipeline

    private func render(
        route: GPXRoute,
        settings: AnimationSettings,
        config: ExportConfig,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runpath_\(UUID().uuidString).mp4")

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            throw ExportError.assetWriterFailed
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.resolution.width,
            AVVideoHeightKey: config.resolution.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: config.videoBitrate]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: config.resolution.width,
                kCVPixelBufferHeightKey as String: config.resolution.height
            ]
        )

        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let allCoords = route.clCoordinates
        let isLandscape = config.orientation == .landscape
        let dt = 1.0 / Double(config.frameRate)
        let baseDuration = 24.0

        // Simulate animation progress using the speed track — matches live playback exactly
        var animProgress: [Double] = []
        var p = 0.0
        while p < 1.0 {
            animProgress.append(p)
            let speed = max(0.1, settings.value(for: .speed, at: p))
            p += (dt * speed) / baseDuration
        }
        animProgress.append(1.0)

        let animationFrames = animProgress.count
        let pullbackCount = max(30, Int(Double(animationFrames) * 0.15))
        let allProgressValues = animProgress + Array(repeating: 1.0, count: pullbackCount)
        let totalFrames = allProgressValues.count

        // Pre-compute rate-limited camera headings sequentially.
        // Must be sequential: each frame's heading depends on the previous frame.
        // Doing this before the parallel snapshot phase avoids shared mutable state.
        let headings = buildHeadings(
            totalFrames: totalFrames,
            animationFrames: animationFrames,
            allProgressValues: allProgressValues,
            allCoords: allCoords,
            isLandscape: isLandscape,
            frameRate: config.frameRate,
            settings: settings
        )

        // Build per-frame parameters (sequential loop so heading array aligns by index)
        var allParams = [FrameParams]()
        allParams.reserveCapacity(totalFrames)
        for frame in 0..<totalFrames {
            let showFull = frame >= animationFrames
            let fp = allProgressValues[frame]
            var altitude = settings.value(for: .cameraAltitude, at: fp)
            var tilt     = settings.value(for: .cameraTilt,     at: fp)
            let count    = showFull ? allCoords.count : max(1, Int(Double(allCoords.count) * fp))
            if isLandscape { altitude *= 1.6; tilt = max(0, tilt - 15) }
            allParams.append(FrameParams(
                index:        frame,
                visibleCount: count,
                altitude:     showFull ? altitude * 3 : altitude,
                pitch:        showFull ? max(0, tilt - 20) : tilt,
                lineWidth:    CGFloat(settings.value(for: .lineThickness, at: fp)),
                lineHue:      settings.value(for: .lineColor, at: fp),
                smoothness:   settings.value(for: .smoothness, at: fp),
                showFull:     showFull,
                isLandscape:  isLandscape,
                showStats:    config.showStats,
                heading:      headings[frame]
            ))
        }

        let renderer = SnapshotRenderer(route: route, outputSize: config.resolution, mapType: config.mapType)
        let encodeQueue = DispatchQueue(label: "com.runpath.encode", qos: .userInitiated)

        let batchSize = 2
        var lastBuffer: CVPixelBuffer?

        for batchStart in stride(from: 0, to: totalFrames, by: batchSize) {
            if cancelled {
                writer.cancelWriting()
                throw ExportError.cancelled
            }

            let batchEnd = min(batchStart + batchSize, totalFrames)
            let batch = Array(allParams[batchStart..<batchEnd])

            let images: [UIImage?] = await withTaskGroup(of: (Int, UIImage?).self) { group in
                for (i, params) in batch.enumerated() {
                    group.addTask {
                        let img = try? await renderer.render(params: params)
                        return (i, img)
                    }
                }
                var results = [UIImage?](repeating: nil, count: batch.count)
                for await (i, img) in group { results[i] = img }
                return results
            }

            for (i, img) in images.enumerated() {
                let frameIdx = batchStart + i

                let buffer: CVPixelBuffer?
                if let img {
                    buffer = pixelBuffer(from: img, size: config.resolution)
                } else {
                    buffer = lastBuffer
                }
                guard let buffer else { continue }
                lastBuffer = buffer

                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    encodeQueue.async {
                        while !input.isReadyForMoreMediaData {
                            Thread.sleep(forTimeInterval: 0.002)
                        }
                        let time = CMTime(value: CMTimeValue(frameIdx), timescale: config.frameRate)
                        adaptor.append(buffer, withPresentationTime: time)
                        cont.resume()
                    }
                }

                progress(Double(frameIdx + 1) / Double(totalFrames))
            }
        }

        input.markAsFinished()
        await writer.finishWriting()

        if writer.status == .completed { return outputURL }
        throw writer.error ?? ExportError.assetWriterFailed
    }

    // MARK: - Heading pre-computation

    private func buildHeadings(
        totalFrames: Int,
        animationFrames: Int,
        allProgressValues: [Double],
        allCoords: [CLLocationCoordinate2D],
        isLandscape: Bool,
        frameRate: Int32,
        settings: AnimationSettings
    ) -> [CLLocationDirection] {
        let maxDeltaPerFrame = 90.0 / Double(frameRate)  // 90°/sec rate limit
        var headings = [CLLocationDirection](repeating: 0, count: totalFrames)
        var cur: CLLocationDirection = 0
        var initialized = false

        for frame in 0..<totalFrames {
            let showFull = frame >= animationFrames
            if showFull {
                // Pullback: look straight down, reset for next run
                headings[frame] = 0
                initialized = false
                cur = 0
                continue
            }

            let fp = allProgressValues[frame]
            let count = max(2, Int(Double(allCoords.count) * fp))
            let visible = Array(allCoords.prefix(count))
            let raw = rawBearing(of: visible)
            let target = isLandscape ? fmod(raw + 90 + 360, 360) : raw

            if !initialized {
                cur = target
                initialized = count > 1
            } else {
                var diff = target - cur
                while diff >  180 { diff -= 360 }
                while diff < -180 { diff += 360 }
                cur += max(-maxDeltaPerFrame, min(maxDeltaPerFrame, diff))
                cur = fmod(cur + 360, 360)
            }
            headings[frame] = cur
        }
        return headings
    }

    private func rawBearing(of coords: [CLLocationCoordinate2D]) -> CLLocationDirection {
        guard coords.count >= 2 else { return 0 }
        let n = min(8, coords.count)
        let a = coords[coords.count - n], b = coords[coords.count - 1]
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var angle = atan2(y, x) * 180 / .pi
        if angle < 0 { angle += 360 }
        return angle
    }

    // MARK: - Pixel buffer

    private func pixelBuffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true,
             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &buffer
        )
        guard let buf = buffer else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buf),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        if let cg = image.cgImage { ctx?.draw(cg, in: CGRect(origin: .zero, size: size)) }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }
}

// MARK: - Snapshot renderer

@MainActor
class SnapshotRenderer {
    private let route: GPXRoute
    private let outputSize: CGSize
    private let rawCoords: [CLLocationCoordinate2D]
    private let mapType: MKMapType

    private let maxSnapshotDim: CGFloat = 1080
    private var smoothCache: [Int: [CLLocationCoordinate2D]] = [:]

    init(route: GPXRoute, outputSize: CGSize, mapType: MKMapType) {
        self.route = route
        self.outputSize = outputSize
        self.rawCoords = route.clCoordinates
        self.mapType = mapType
    }

    func render(params: FrameParams) async throws -> UIImage {
        let smoothed = cachedSmoothed(factor: params.smoothness)
        let visibleSmoothed = Array(smoothed.prefix(max(1, params.visibleCount)))
        let visibleRaw = Array(rawCoords.prefix(max(1, params.visibleCount)))

        let center = params.showFull ? route.centerCoordinate : (visibleSmoothed.last ?? smoothed[0])

        // Heading is pre-computed and rate-limited by VideoExporter.buildHeadings
        let heading = params.heading

        let maxDim = max(outputSize.width, outputSize.height)
        let snapshotScale = maxDim > maxSnapshotDim ? maxSnapshotDim / maxDim : 1.0
        let snapshotSize = CGSize(width: outputSize.width * snapshotScale,
                                  height: outputSize.height * snapshotScale)

        let options = MKMapSnapshotter.Options()
        options.size = snapshotSize
        options.scale = 1
        options.mapType = mapType
        options.camera = MKMapCamera(
            lookingAtCenter: center,
            fromDistance: params.altitude,
            pitch: CGFloat(params.pitch),
            heading: heading
        )

        let snapshotter = MKMapSnapshotter(options: options)
        let snapshot = try await snapshotter.start()

        let upscale = 1.0 / snapshotScale
        let renderer = UIGraphicsImageRenderer(size: outputSize)
        return renderer.image { ctx in
            snapshot.image.draw(in: CGRect(origin: .zero, size: outputSize))

            if visibleRaw.count > 1 {
                let path = UIBezierPath()
                let first = snapshot.point(for: visibleRaw[0])
                path.move(to: CGPoint(x: first.x * upscale, y: first.y * upscale))
                for coord in visibleRaw.dropFirst() {
                    let pt = snapshot.point(for: coord)
                    path.addLine(to: CGPoint(x: pt.x * upscale, y: pt.y * upscale))
                }
                UIColor(hue: CGFloat(params.lineHue), saturation: 0.85,
                        brightness: 1.0, alpha: 1.0).setStroke()
                path.lineWidth = params.lineWidth
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }

            if params.showStats {
                drawStatsOverlay(ctx: ctx, size: outputSize)
            }
        }
    }

    // MARK: - Stats overlay

    private func drawStatsOverlay(ctx: UIGraphicsRendererContext, size: CGSize) {
        let cgCtx = ctx.cgContext

        let shortSide = min(size.width, size.height)
        let gradHeight = shortSide * 0.40
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = [UIColor.black.withAlphaComponent(0).cgColor,
                      UIColor.black.withAlphaComponent(0.82).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
            cgCtx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: size.height - gradHeight),
                end:   CGPoint(x: 0, y: size.height),
                options: []
            )
        }

        let distStr = GPXRoute.formatDistance(route.totalDistance)
        let timeStr = GPXRoute.formatDuration(route.duration)
        let paceStr: String
        if route.totalDistance > 0 && route.duration > 0 {
            let secsPerKm = route.duration / (route.totalDistance / 1000)
            paceStr = String(format: "%d:%02d/km", Int(secsPerKm) / 60, Int(secsPerKm) % 60)
        } else {
            paceStr = "—"
        }

        let distValueSize = shortSide * 0.090
        let sideValueSize = shortSide * 0.054
        let labelSize     = shortSide * 0.026
        let bottomPad     = size.height * 0.058
        let labelGap      = shortSide * 0.014
        let sideOffset    = size.width * 0.28
        let centerX       = size.width * 0.50

        drawStatColumn(value: distStr, label: "DISTANCE",
                       cx: centerX,
                       valueSize: distValueSize, labelSize: labelSize * 1.1,
                       bottomPad: bottomPad, labelGap: labelGap,
                       valueAlpha: 1.0, labelAlpha: 0.60)
        drawStatColumn(value: timeStr, label: "TIME",
                       cx: centerX - sideOffset,
                       valueSize: sideValueSize, labelSize: labelSize,
                       bottomPad: bottomPad, labelGap: labelGap,
                       valueAlpha: 0.88, labelAlpha: 0.50)
        drawStatColumn(value: paceStr, label: "PACE",
                       cx: centerX + sideOffset,
                       valueSize: sideValueSize, labelSize: labelSize,
                       bottomPad: bottomPad, labelGap: labelGap,
                       valueAlpha: 0.88, labelAlpha: 0.50)
    }

    private func drawStatColumn(value: String, label: String,
                                cx: CGFloat, valueSize: CGFloat, labelSize: CGFloat,
                                bottomPad: CGFloat, labelGap: CGFloat,
                                valueAlpha: CGFloat, labelAlpha: CGFloat) {
        let size = outputSize
        let valAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: valueSize, weight: .bold),
            .foregroundColor: UIColor.white.withAlphaComponent(valueAlpha)
        ]
        let lblAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: labelSize, weight: .semibold),
            .foregroundColor: UIColor.white.withAlphaComponent(labelAlpha),
            .kern: 1.8 as NSNumber
        ]
        let valNS = value as NSString
        let lblNS = label as NSString
        let valSz = valNS.size(withAttributes: valAttrs)
        let lblSz = lblNS.size(withAttributes: lblAttrs)

        let valY = size.height - bottomPad - valSz.height
        let lblY = valY - labelGap - lblSz.height

        valNS.draw(at: CGPoint(x: cx - valSz.width / 2, y: valY), withAttributes: valAttrs)
        lblNS.draw(at: CGPoint(x: cx - lblSz.width / 2, y: lblY), withAttributes: lblAttrs)
    }

    // MARK: - Smoothing helpers

    private func cachedSmoothed(factor: Double) -> [CLLocationCoordinate2D] {
        let key = Int((factor * 20).rounded())
        if let cached = smoothCache[key] { return cached }
        let result = applySmoothing(rawCoords, factor: Double(key) / 20.0)
        smoothCache[key] = result
        return result
    }

    private func applySmoothing(_ coords: [CLLocationCoordinate2D], factor: Double) -> [CLLocationCoordinate2D] {
        guard coords.count > 5, factor > 0.01 else { return coords }
        let radius = max(1, Int(factor * 40))
        let n = coords.count
        var result = coords
        for _ in 0..<2 {
            var pass = result
            for i in 1..<(n - 1) {
                let lo = max(0, i - radius), hi = min(n - 1, i + radius)
                let count = Double(hi - lo + 1)
                var lat = 0.0, lon = 0.0
                for j in lo...hi { lat += result[j].latitude; lon += result[j].longitude }
                pass[i] = CLLocationCoordinate2D(latitude: lat / count, longitude: lon / count)
            }
            result = pass
        }
        return result
    }
}
