import SwiftUI
import MapKit

struct AnimatedMapView: UIViewRepresentable {

    @ObservedObject var vm: AnimationViewModel

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.mapType = .standard
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
        context.coordinator.update(mapView: mapView, vm: vm)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(vm: vm)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        let vm: AnimationViewModel
        weak var mapView: MKMapView?
        private var lastVisibleCount = 0
        private var lastShowFull = false
        private var polylineOverlay: MKPolyline?

        init(vm: AnimationViewModel) {
            self.vm = vm
        }

        func update(mapView: MKMapView, vm: AnimationViewModel) {
            let coords = vm.smoothedCoordinates
            let count = vm.visibleCoordinateCount
            let showFull = vm.showFullRoute

            guard !coords.isEmpty else { return }

            let visibleCount = showFull ? coords.count : max(1, count)
            if visibleCount == lastVisibleCount && showFull == lastShowFull { return }
            lastVisibleCount = visibleCount
            lastShowFull = showFull

            // Update polyline
            if let existing = polylineOverlay { mapView.removeOverlay(existing) }
            let visible = Array(coords.prefix(visibleCount))
            let poly = MKPolyline(coordinates: visible, count: visible.count)
            mapView.addOverlay(poly, level: .aboveRoads)
            polylineOverlay = poly

            // Update camera
            let center: CLLocationCoordinate2D
            if showFull {
                center = vm.route?.centerCoordinate ?? coords[coords.count / 2]
                let region = vm.route?.region ?? MKCoordinateRegion()
                let dist = max(
                    regionDistance(region) * 600,
                    vm.cameraAltitude * 2.5
                )
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
                center = visible.last ?? coords[0]
                let heading = bearing(of: visible)
                let camera = MKMapCamera(
                    lookingAtCenter: center,
                    fromDistance: vm.cameraAltitude,
                    pitch: CGFloat(vm.cameraPitch),
                    heading: heading
                )
                mapView.setCamera(camera, animated: false)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let poly = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: poly)
                let hue = CGFloat(vm.lineHue)
                r.strokeColor = UIColor(hue: hue, saturation: 0.85, brightness: 1.0, alpha: 1.0)
                r.lineWidth = CGFloat(vm.lineWidth)
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        private func bearing(of coords: [CLLocationCoordinate2D]) -> CLLocationDirection {
            guard coords.count >= 2 else { return 0 }
            let n = min(8, coords.count)
            let a = coords[coords.count - n]
            let b = coords[coords.count - 1]
            let dLon = (b.longitude - a.longitude) * .pi / 180
            let lat1 = a.latitude * .pi / 180
            let lat2 = b.latitude * .pi / 180
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
