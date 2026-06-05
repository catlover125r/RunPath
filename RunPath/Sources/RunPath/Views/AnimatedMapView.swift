import SwiftUI
import MapKit

struct AnimatedMapView: UIViewRepresentable {

    @ObservedObject var vm: AnimationViewModel
    var mapType: MKMapType

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator   // critical — without this rendererFor never fires
        map.mapType = mapType
        map.showsUserLocation = false
        map.isRotateEnabled = false
        map.isZoomEnabled = false
        map.isScrollEnabled = false
        map.isPitchEnabled = false
        map.showsCompass = false
        map.showsScale = false
        map.pointOfInterestFilter = .excludingAll
        context.coordinator.mapView = map
        return map
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        if mapView.mapType != mapType { mapView.mapType = mapType }
        context.coordinator.update(mapView: mapView, vm: vm)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(vm: vm)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        let vm: AnimationViewModel
        weak var mapView: MKMapView?
        private var lastVisibleCount = -1
        private var lastShowFull = false
        private var lastLineHue: Double = -1
        private var lastLineWidth: Double = -1
        private var polylineOverlay: MKPolyline?
        private weak var polylineRenderer: MKPolylineRenderer?

        init(vm: AnimationViewModel) {
            self.vm = vm
        }

        func update(mapView: MKMapView, vm: AnimationViewModel) {
            let coords = vm.smoothedCoordinates
            let count = vm.visibleCoordinateCount
            let showFull = vm.showFullRoute
            guard !coords.isEmpty else { return }

            let visibleCount = showFull ? coords.count : max(1, count)
            let coordsChanged = visibleCount != lastVisibleCount || showFull != lastShowFull
            let styleChanged = vm.lineHue != lastLineHue || vm.lineWidth != lastLineWidth

            // Update style on cached renderer without removing/re-adding the overlay
            if styleChanged, let renderer = polylineRenderer {
                renderer.strokeColor = UIColor(hue: CGFloat(vm.lineHue), saturation: 0.85,
                                              brightness: 1.0, alpha: 1.0)
                renderer.lineWidth = CGFloat(vm.lineWidth)
                renderer.setNeedsDisplay()
                lastLineHue = vm.lineHue
                lastLineWidth = vm.lineWidth
            }

            guard coordsChanged else { return }
            lastVisibleCount = visibleCount
            lastShowFull = showFull

            // Replace polyline
            if let existing = polylineOverlay { mapView.removeOverlay(existing) }
            let visible = Array(coords.prefix(visibleCount))
            let poly = MKPolyline(coordinates: visible, count: visible.count)
            mapView.addOverlay(poly, level: .aboveRoads)
            polylineOverlay = poly

            // Camera
            if showFull {
                let center = vm.route?.centerCoordinate ?? coords[coords.count / 2]
                let region = vm.route?.region ?? MKCoordinateRegion()
                let dist = max(regionDistance(region) * 600, vm.cameraAltitude * 2.5)
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
                let center = visible.last ?? coords[0]
                let camera = MKMapCamera(
                    lookingAtCenter: center,
                    fromDistance: vm.cameraAltitude,
                    pitch: CGFloat(vm.cameraPitch),
                    heading: bearing(of: visible)
                )
                mapView.setCamera(camera, animated: false)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let poly = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let r = MKPolylineRenderer(polyline: poly)
            r.strokeColor = UIColor(hue: CGFloat(vm.lineHue), saturation: 0.85,
                                    brightness: 1.0, alpha: 1.0)
            r.lineWidth = CGFloat(vm.lineWidth)
            r.lineCap = .round
            r.lineJoin = .round
            polylineRenderer = r
            lastLineHue = vm.lineHue
            lastLineWidth = vm.lineWidth
            return r
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

        private func regionDistance(_ region: MKCoordinateRegion) -> Double {
            let a = CLLocation(latitude: region.center.latitude - region.span.latitudeDelta / 2,
                               longitude: region.center.longitude)
            let b = CLLocation(latitude: region.center.latitude + region.span.latitudeDelta / 2,
                               longitude: region.center.longitude)
            return a.distance(from: b)
        }
    }
}
