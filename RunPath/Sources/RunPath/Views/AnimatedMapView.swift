import SwiftUI
import MapKit

// MARK: - Screen-space path overlay

// Draws the route as a CAShapeLayer in the view's own coordinate system.
// Screen-space drawing means line width never changes with camera zoom/tilt,
// and updates are immediate — no MapKit tile-pipeline lag.
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

    // Return a plain container so PathOverlayView is guaranteed above the map
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
        // Keep subview frames in sync (SwiftUI may resize the container)
        map.frame = container.bounds
        context.coordinator.pathOverlayView?.frame = container.bounds
        if map.mapType != mapType { map.mapType = mapType }
        context.coordinator.update(mapView: map, vm: vm)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: Coordinator

    class Coordinator: NSObject, MKMapViewDelegate {
        weak var mapView: MKMapView?
        var pathOverlayView: PathOverlayView?

        func update(mapView: MKMapView, vm: AnimationViewModel) {
            let rawCoords     = vm.route?.clCoordinates ?? []
            let smoothedCoords = vm.smoothedCoordinates
            let count    = vm.visibleCoordinateCount
            let showFull = vm.showFullRoute
            let hue      = CGFloat(vm.lineHue)
            let width    = CGFloat(vm.lineWidth)
            guard !rawCoords.isEmpty else { return }

            let visibleCount = showFull ? rawCoords.count : max(0, count)

            // Update camera first — coordinate conversion uses the updated projection
            updateCamera(mapView: mapView, vm: vm,
                         rawCoords: rawCoords, smoothedCoords: smoothedCoords,
                         visibleCount: visibleCount, showFull: showFull)

            // Draw raw GPS path in screen space
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
                let camera    = MKMapCamera(
                    lookingAtCenter: visible.last ?? camCoords[0],
                    fromDistance: vm.cameraAltitude,
                    pitch: CGFloat(vm.cameraPitch),
                    heading: bearing(of: visible)
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
            return atan2(y, x) * 180 / .pi
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
