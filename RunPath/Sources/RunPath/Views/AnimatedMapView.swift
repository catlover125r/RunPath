import SwiftUI
import MapKit

// MARK: - Custom overlay (lives for the lifetime of the route, never replaced)

final class AnimatedPathOverlay: NSObject, MKOverlay {
    var coordinate: CLLocationCoordinate2D
    var boundingMapRect: MKMapRect
    var coordinates: [CLLocationCoordinate2D] = []
    var visibleCount: Int = 0
    var lineHue: CGFloat = 0.58
    var lineWidth: CGFloat = 5

    override init() {
        coordinate = CLLocationCoordinate2D()
        boundingMapRect = .world
        super.init()
    }

    func update(coordinates: [CLLocationCoordinate2D], visibleCount: Int,
                lineHue: CGFloat, lineWidth: CGFloat) {
        self.coordinates = coordinates
        self.visibleCount = visibleCount
        self.lineHue = lineHue
        self.lineWidth = lineWidth
        // Recompute bounding rect so MapKit knows where to ask for redraws
        if !coordinates.isEmpty {
            let mapPoints = coordinates.map { MKMapPoint($0) }
            let xs = mapPoints.map(\.x), ys = mapPoints.map(\.y)
            boundingMapRect = MKMapRect(
                x: xs.min()!, y: ys.min()!,
                width: xs.max()! - xs.min()!,
                height: ys.max()! - ys.min()!
            ).insetBy(dx: -5000, dy: -5000)
            coordinate = coordinates[coordinates.count / 2]
        }
    }
}

// MARK: - Custom renderer (persistent, just redraws with latest data)

final class AnimatedPathRenderer: MKOverlayRenderer {
    var pathOverlay: AnimatedPathOverlay { overlay as! AnimatedPathOverlay }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let overlay = pathOverlay
        let count = min(overlay.visibleCount, overlay.coordinates.count)
        guard count > 1 else { return }

        let pts = overlay.coordinates.prefix(count).map { point(for: MKMapPoint($0)) }

        // Line width is in screen points; convert to map-renderer points via zoomScale
        let width = max(1, overlay.lineWidth / zoomScale)

        context.setStrokeColor(
            UIColor(hue: overlay.lineHue, saturation: 0.85, brightness: 1.0, alpha: 1.0).cgColor
        )
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setShouldAntialias(true)

        context.move(to: pts[0])
        for pt in pts.dropFirst() { context.addLine(to: pt) }
        context.strokePath()
    }
}

// MARK: - SwiftUI wrapper

struct AnimatedMapView: UIViewRepresentable {

    @ObservedObject var vm: AnimationViewModel
    var mapType: MKMapType

    func makeUIView(context: Context) -> MKMapView {
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

        // Add the permanent overlay once
        map.addOverlay(context.coordinator.pathOverlay, level: .aboveRoads)
        context.coordinator.mapView = map
        return map
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        if mapView.mapType != mapType { mapView.mapType = mapType }
        context.coordinator.update(mapView: mapView, vm: vm)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: Coordinator

    class Coordinator: NSObject, MKMapViewDelegate {
        weak var mapView: MKMapView?
        let pathOverlay = AnimatedPathOverlay()
        private weak var pathRenderer: AnimatedPathRenderer?

        private var lastVisibleCount = -1
        private var lastShowFull = false
        private var lastLineHue: CGFloat = -1
        private var lastLineWidth: CGFloat = -1
        private var lastCoordCount = 0

        func update(mapView: MKMapView, vm: AnimationViewModel) {
            let coords   = vm.smoothedCoordinates
            let count    = vm.visibleCoordinateCount
            let showFull = vm.showFullRoute
            let hue      = CGFloat(vm.lineHue)
            let width    = CGFloat(vm.lineWidth)
            guard !coords.isEmpty else { return }

            let visibleCount = showFull ? coords.count : max(0, count)
            let coordsChanged = coords.count != lastCoordCount
            let visibleChanged = visibleCount != lastVisibleCount || showFull != lastShowFull
            let styleChanged   = hue != lastLineHue || width != lastLineWidth

            guard coordsChanged || visibleChanged || styleChanged else { return }

            lastVisibleCount = visibleCount
            lastShowFull     = showFull
            lastLineHue      = hue
            lastLineWidth    = width
            lastCoordCount   = coords.count

            // Push new data into overlay and ask the renderer to redraw — no overlay swap
            pathOverlay.update(coordinates: coords, visibleCount: visibleCount,
                               lineHue: hue, lineWidth: width)
            pathRenderer?.setNeedsDisplay()

            // Camera
            updateCamera(mapView: mapView, vm: vm, coords: coords,
                         visibleCount: visibleCount, showFull: showFull)
        }

        private func updateCamera(mapView: MKMapView, vm: AnimationViewModel,
                                  coords: [CLLocationCoordinate2D],
                                  visibleCount: Int, showFull: Bool) {
            if showFull {
                let center = vm.route?.centerCoordinate ?? coords[coords.count / 2]
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
                let visible = Array(coords.prefix(max(1, visibleCount)))
                let camera  = MKMapCamera(
                    lookingAtCenter: visible.last ?? coords[0],
                    fromDistance: vm.cameraAltitude,
                    pitch: CGFloat(vm.cameraPitch),
                    heading: bearing(of: visible)
                )
                mapView.setCamera(camera, animated: false)
            }
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let animated = overlay as? AnimatedPathOverlay else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = AnimatedPathRenderer(overlay: animated)
            pathRenderer = renderer
            return renderer
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
