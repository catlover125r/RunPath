import SwiftUI
import MapKit
import Combine

// MARK: - Screen-space path overlay

final class PathOverlayView: UIView {
    private let shapeLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        shapeLayer.fillColor = UIColor.clear.cgColor
        shapeLayer.lineCap = .round
        shapeLayer.lineJoin = .round
        layer.addSublayer(shapeLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(coordinates: [CLLocationCoordinate2D],
                visibleCount: Int,
                lineHue: CGFloat,
                lineWidth: CGFloat,
                in mapView: MKMapView) {
        let count = min(visibleCount, coordinates.count)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeLayer.frame = bounds

        guard count > 1 else {
            shapeLayer.path = nil
            CATransaction.commit()
            return
        }

        let path = CGMutablePath()
        path.move(to: mapView.convert(coordinates[0], toPointTo: self))
        for i in 1..<count {
            path.addLine(to: mapView.convert(coordinates[i], toPointTo: self))
        }

        shapeLayer.path = path
        shapeLayer.strokeColor = UIColor(hue: lineHue, saturation: 0.85,
                                         brightness: 1.0, alpha: 1.0).cgColor
        shapeLayer.lineWidth = lineWidth
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shapeLayer.frame = bounds
    }
}

// MARK: - SwiftUI wrapper

struct AnimatedMapView: UIViewRepresentable {
    @ObservedObject var vm: AnimationViewModel
    var mapType: MKMapType

    func makeUIView(context: Context) -> UIView {
        let container = UIView()

        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = mapType
        map.showsUserLocation = false
        map.isRotateEnabled = false
        map.isZoomEnabled = false
        map.isScrollEnabled = false
        map.isPitchEnabled = false
        map.showsCompass = false
        map.showsScale = false
        map.pointOfInterestFilter = .excludingAll
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(map)

        let pathView = PathOverlayView()
        pathView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(pathView)

        context.coordinator.mapView = map
        context.coordinator.pathOverlayView = pathView
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard let map = context.coordinator.mapView else { return }
        map.frame = container.bounds
        context.coordinator.pathOverlayView?.frame = container.bounds
        if map.mapType != mapType { map.mapType = mapType }
        context.coordinator.bind(to: vm)
        context.coordinator.update(mapView: map, vm: vm)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: Coordinator

    class Coordinator: NSObject, MKMapViewDelegate {
        weak var mapView: MKMapView?
        var pathOverlayView: PathOverlayView?

        private var cancellables = Set<AnyCancellable>()
        private weak var observedVM: AnimationViewModel?

        // Heading rate limiter — caps camera rotation at 90°/sec so turnarounds
        // pan smoothly instead of snapping.
        private var smoothedHeading: CLLocationDirection = 0
        private var headingInitialized = false
        private var lastHeadingTime: CFTimeInterval = 0
        private let maxHeadingRate: Double = 90.0  // °/sec

        func bind(to vm: AnimationViewModel) {
            guard observedVM !== vm else { return }
            observedVM = vm
            cancellables.removeAll()

            vm.objectWillChange
                .delay(for: .zero, scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self,
                          let map = self.mapView,
                          let vm = self.observedVM else { return }
                    self.update(mapView: map, vm: vm)
                }
                .store(in: &cancellables)
        }

        func update(mapView: MKMapView, vm: AnimationViewModel) {
            let rawCoords      = vm.route?.clCoordinates ?? []
            let smoothedCoords = vm.smoothedCoordinates
            let count    = vm.visibleCoordinateCount
            let showFull = vm.showFullRoute
            let hue      = CGFloat(vm.lineHue)
            let width    = CGFloat(vm.lineWidth)
            guard !rawCoords.isEmpty else { return }

            let visibleCount = showFull ? rawCoords.count : max(0, count)

            updateCamera(mapView: mapView, vm: vm,
                         rawCoords: rawCoords, smoothedCoords: smoothedCoords,
                         visibleCount: visibleCount, showFull: showFull)

            pathOverlayView?.update(coordinates: rawCoords,
                                    visibleCount: visibleCount,
                                    lineHue: hue, lineWidth: width,
                                    in: mapView)
        }

        private func updateCamera(mapView: MKMapView, vm: AnimationViewModel,
                                  rawCoords: [CLLocationCoordinate2D],
                                  smoothedCoords: [CLLocationCoordinate2D],
                                  visibleCount: Int, showFull: Bool) {
            if showFull {
                // Reset so the next playback snaps to the initial heading.
                headingInitialized = false

                let center = vm.route?.centerCoordinate ?? rawCoords[rawCoords.count / 2]
                let region = vm.route?.region ?? MKCoordinateRegion()
                let dist   = max(regionDistance(region) * 600, vm.cameraAltitude * 2.5)
                let camera = MKMapCamera(
                    lookingAtCenter: center,
                    fromDistance: dist,
                    pitch: max(0, CGFloat(vm.cameraPitch - 25)),
                    heading: 0
                )
                UIView.animate(withDuration: 1.2, delay: 0, options: .curveEaseInOut) {
                    mapView.setCamera(camera, animated: false)
                }
            } else {
                let camCoords = smoothedCoords.isEmpty ? rawCoords : smoothedCoords
                let visible   = Array(camCoords.prefix(max(1, visibleCount)))
                let targetHeading = bearing(of: visible)

                let heading: CLLocationDirection
                if visibleCount <= 1 || !headingInitialized {
                    // First meaningful frame: snap directly to avoid wind-up.
                    smoothedHeading = targetHeading
                    headingInitialized = visibleCount > 1
                    lastHeadingTime = CACurrentMediaTime()
                    heading = targetHeading
                } else {
                    let now = CACurrentMediaTime()
                    let dt = min(now - lastHeadingTime, 0.5)
                    lastHeadingTime = now
                    var diff = targetHeading - smoothedHeading
                    // Shortest angular path
                    while diff >  180 { diff -= 360 }
                    while diff < -180 { diff += 360 }
                    let maxDelta = maxHeadingRate * dt
                    smoothedHeading += max(-maxDelta, min(maxDelta, diff))
                    smoothedHeading = smoothedHeading.truncatingRemainder(dividingBy: 360)
                    if smoothedHeading < 0 { smoothedHeading += 360 }
                    heading = smoothedHeading
                }

                let camera = MKMapCamera(
                    lookingAtCenter: visible.last ?? camCoords[0],
                    fromDistance: vm.cameraAltitude,
                    pitch: CGFloat(vm.cameraPitch),
                    heading: heading
                )
                mapView.setCamera(camera, animated: false)
            }
        }

        // MARK: Helpers

        private func bearing(of coords: [CLLocationCoordinate2D]) -> CLLocationDirection {
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

        private func regionDistance(_ region: MKCoordinateRegion) -> Double {
            let a = CLLocation(latitude: region.center.latitude - region.span.latitudeDelta / 2,
                               longitude: region.center.longitude)
            let b = CLLocation(latitude: region.center.latitude + region.span.latitudeDelta / 2,
                               longitude: region.center.longitude)
            return a.distance(from: b)
        }
    }
}
