import Foundation
import AVFoundation
import MapKit
import UIKit

@MainActor
class VideoExporter {

    struct ExportConfig {
        var resolution: CGSize = CGSize(width: 1080, height: 1920)
        var orientation: ExportOrientation = .portrait
        var frameRate: Int32 = 30
        var videoBitrate: Int = 8_000_000
    }

    enum ExportError: LocalizedError {
        case assetWriterFailed, snapshotFailed, cancelled

        var errorDescription: String? {
            switch self {
            case .assetWriterFailed: return "Failed to create video writer."
            case .snapshotFailed: return "Failed to render frame."
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
        let renderer = await MainActor.run { SnapshotRenderer(route: route, size: config.resolution) }

        for frame in 0..<totalFrames {
            if cancelled {
                writer.cancelWriting()
                throw ExportError.cancelled
            }

            let frameProgress: Double
            let showFull: Bool
            if frame < animationFrames {
                frameProgress = Double(frame) / Double(animationFrames)
                showFull = false
            } else {
                frameProgress = 1.0
                showFull = true
            }

            let smoothness = settings.value(for: .smoothness, at: frameProgress)
            var altitude = settings.value(for: .cameraAltitude, at: frameProgress)
            var tilt = settings.value(for: .cameraTilt, at: frameProgress)
            let thickness = settings.value(for: .lineThickness, at: frameProgress)
            let hue = settings.value(for: .lineColor, at: frameProgress)
            let coordCount = showFull ? allCoords.count : max(1, Int(Double(allCoords.count) * frameProgress))

            // Landscape needs a higher/wider vantage point to fill the wider frame well
            if isLandscape { altitude *= 1.6; tilt = max(0, tilt - 15) }

            let img = try await renderer.render(
                visibleCount: coordCount,
                altitude: showFull ? altitude * 3 : altitude,
                pitch: showFull ? max(0, tilt - 20) : tilt,
                lineWidth: CGFloat(thickness),
                lineHue: hue,
                smoothnessFactor: smoothness,
                showFull: showFull,
                isLandscape: isLandscape
            )

            guard let buffer = pixelBuffer(from: img, size: config.resolution) else { continue }

            // Wait for input to be ready on a background thread
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let q = DispatchQueue(label: "com.runpath.encode")
                q.async {
                    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
                    let time = CMTime(value: CMTimeValue(frame), timescale: config.frameRate)
                    adaptor.append(buffer, withPresentationTime: time)
                    cont.resume()
                }
            }

            progress(Double(frame + 1) / Double(totalFrames))
        }

        input.markAsFinished()
        await writer.finishWriting()

        if writer.status == .completed {
            return outputURL
        } else {
            throw writer.error ?? ExportError.assetWriterFailed
        }
    }

    private func pixelBuffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
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
        if let cgImage = image.cgImage { ctx?.draw(cgImage, in: CGRect(origin: .zero, size: size)) }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }
}

@MainActor
class SnapshotRenderer {
    private let route: GPXRoute
    private let size: CGSize
    private let allCoords: [CLLocationCoordinate2D]

    init(route: GPXRoute, size: CGSize) {
        self.route = route
        self.size = size
        self.allCoords = route.clCoordinates
    }

    func render(
        visibleCount: Int,
        altitude: Double,
        pitch: Double,
        lineWidth: CGFloat,
        lineHue: Double,
        smoothnessFactor: Double,
        showFull: Bool,
        isLandscape: Bool = false
    ) async throws -> UIImage {
        let visibleCoords = Array(allCoords.prefix(max(1, visibleCount)))
        let center = showFull ? route.centerCoordinate : (visibleCoords.last ?? allCoords[0])

        // In landscape the wide axis is horizontal, so rotating heading 90° puts the
        // direction of travel across the wide dimension — the route fills the frame naturally.
        let travelHeading = bearing(of: visibleCoords)
        let cameraHeading = isLandscape ? (travelHeading + 90).truncatingRemainder(dividingBy: 360) : travelHeading

        let options = MKMapSnapshotter.Options()
        options.size = size
        options.scale = 1
        options.mapType = .standard
        options.camera = MKMapCamera(
            lookingAtCenter: center,
            fromDistance: altitude,
            pitch: CGFloat(pitch),
            heading: cameraHeading
        )

        let snapshotter = MKMapSnapshotter(options: options)
        let snapshot = try await snapshotter.start()

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            snapshot.image.draw(at: .zero)
            guard visibleCoords.count > 1 else { return }
            let path = UIBezierPath()
            path.move(to: snapshot.point(for: visibleCoords[0]))
            for coord in visibleCoords.dropFirst() {
                path.addLine(to: snapshot.point(for: coord))
            }
            UIColor(hue: CGFloat(lineHue), saturation: 0.85, brightness: 1.0, alpha: 1.0).setStroke()
            path.lineWidth = lineWidth
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
