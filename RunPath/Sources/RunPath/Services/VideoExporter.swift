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
    let showFull: Bool
    let isLandscape: Bool
}

@MainActor
class VideoExporter {

    struct ExportConfig {
        var resolution: CGSize = CGSize(width: 1080, height: 1920)
        var orientation: ExportOrientation = .portrait
        var frameRate: Int32 = 30
        var videoBitrate: Int = 8_000_000
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

        let totalFrames = 12 * Int(config.frameRate)
        let animationFrames = Int(Double(totalFrames) * 0.85)
        let allCoords = route.clCoordinates
        let isLandscape = config.orientation == .landscape

        // Pre-compute every frame's parameters — cheap, avoids repeating work inside TaskGroup
        let allParams: [FrameParams] = (0..<totalFrames).map { frame in
            let showFull = frame >= animationFrames
            let fp = showFull ? 1.0 : Double(frame) / Double(animationFrames)
            var altitude = settings.value(for: .cameraAltitude, at: fp)
            var tilt     = settings.value(for: .cameraTilt,     at: fp)
            let count    = showFull ? allCoords.count : max(1, Int(Double(allCoords.count) * fp))
            if isLandscape { altitude *= 1.6; tilt = max(0, tilt - 15) }
            return FrameParams(
                index:       frame,
                visibleCount: count,
                altitude:    showFull ? altitude * 3 : altitude,
                pitch:       showFull ? max(0, tilt - 20) : tilt,
                lineWidth:   CGFloat(settings.value(for: .lineThickness, at: fp)),
                lineHue:     settings.value(for: .lineColor, at: fp),
                showFull:    showFull,
                isLandscape: isLandscape
            )
        }

        let renderer = SnapshotRenderer(route: route, outputSize: config.resolution)
        let encodeQueue = DispatchQueue(label: "com.runpath.encode", qos: .userInitiated)

        // Render 4 frames concurrently — MKMapSnapshotter fetches tiles on its own background
        // threads, so these 4 truly overlap even though we're on MainActor.
        let batchSize = 4

        for batchStart in stride(from: 0, to: totalFrames, by: batchSize) {
            if cancelled {
                writer.cancelWriting()
                throw ExportError.cancelled
            }

            let batchEnd = min(batchStart + batchSize, totalFrames)
            let batch = Array(allParams[batchStart..<batchEnd])

            // Concurrent render
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

            // Encode in index order
            for (i, img) in images.enumerated() {
                let frameIdx = batchStart + i
                guard let img else { continue }
                guard let buffer = pixelBuffer(from: img, size: config.resolution) else { continue }

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
    private let allCoords: [CLLocationCoordinate2D]

    // MKMapSnapshotter can't reliably handle sizes above ~1080px on device.
    // We snapshot at a capped size and composite the path at full output resolution.
    private let maxSnapshotDim: CGFloat = 1080

    init(route: GPXRoute, outputSize: CGSize) {
        self.route = route
        self.outputSize = outputSize
        self.allCoords = route.clCoordinates
    }

    func render(params: FrameParams) async throws -> UIImage {
        let visibleCoords = Array(allCoords.prefix(max(1, params.visibleCount)))
        let center = params.showFull ? route.centerCoordinate : (visibleCoords.last ?? allCoords[0])

        let travelHeading = bearing(of: visibleCoords)
        let heading = params.isLandscape
            ? (travelHeading + 90).truncatingRemainder(dividingBy: 360)
            : travelHeading

        // Cap snapshot size so MKMapSnapshotter never sees > 1080px
        let maxDim = max(outputSize.width, outputSize.height)
        let snapshotScale = maxDim > maxSnapshotDim ? maxSnapshotDim / maxDim : 1.0
        let snapshotSize = CGSize(width: outputSize.width * snapshotScale,
                                  height: outputSize.height * snapshotScale)

        let options = MKMapSnapshotter.Options()
        options.size = snapshotSize
        options.scale = 1
        options.mapType = .standard
        options.camera = MKMapCamera(
            lookingAtCenter: center,
            fromDistance: params.altitude,
            pitch: CGFloat(params.pitch),
            heading: heading
        )

        let snapshotter = MKMapSnapshotter(options: options)
        let snapshot = try await snapshotter.start()

        // Composite at full output resolution — scales the map up, draws path at full size
        let upscale = 1.0 / snapshotScale
        let renderer = UIGraphicsImageRenderer(size: outputSize)
        return renderer.image { _ in
            snapshot.image.draw(in: CGRect(origin: .zero, size: outputSize))
            guard visibleCoords.count > 1 else { return }
            let path = UIBezierPath()
            let first = snapshot.point(for: visibleCoords[0])
            path.move(to: CGPoint(x: first.x * upscale, y: first.y * upscale))
            for coord in visibleCoords.dropFirst() {
                let pt = snapshot.point(for: coord)
                path.addLine(to: CGPoint(x: pt.x * upscale, y: pt.y * upscale))
            }
            UIColor(hue: CGFloat(params.lineHue), saturation: 0.85, brightness: 1.0, alpha: 1.0).setStroke()
            path.lineWidth = params.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    private func bearing(of coords: [CLLocationCoordinate2D]) -> CLLocationDirection {
        guard coords.count >= 2 else { return 0 }
        let n = min(8, coords.count)
        let a = coords[coords.count - n], b = coords[coords.count - 1]
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return atan2(y, x) * 180 / .pi
    }
}
