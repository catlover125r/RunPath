import Foundation
import CoreLocation
import MapKit

struct GPXCoordinate: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let elevation: Double
    let timestamp: Date?
    let speed: Double?
}

struct GPXRoute: Identifiable, Codable {
    let id: UUID
    let name: String
    let importedAt: Date
    let activityDate: Date?
    let coordinatesData: [CoordinateData]
    let totalDistance: Double
    let totalElevationGain: Double
    let duration: TimeInterval

    struct CoordinateData: Codable {
        let latitude: Double
        let longitude: Double
        let elevation: Double
        let timestamp: TimeInterval?
        let speed: Double?
    }

    var coordinates: [GPXCoordinate] {
        coordinatesData.map {
            GPXCoordinate(
                coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                elevation: $0.elevation,
                timestamp: $0.timestamp.map { Date(timeIntervalSince1970: $0) },
                speed: $0.speed
            )
        }
    }

    var clCoordinates: [CLLocationCoordinate2D] {
        coordinatesData.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var region: MKCoordinateRegion {
        let coords = clCoordinates
        guard !coords.isEmpty else { return MKCoordinateRegion() }
        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: (maxLat - minLat) * 1.4, longitudeDelta: (maxLon - minLon) * 1.4)
        return MKCoordinateRegion(center: center, span: span)
    }

    var centerCoordinate: CLLocationCoordinate2D {
        region.center
    }

    init(id: UUID = UUID(), name: String, importedAt: Date = Date(), activityDate: Date?,
         coordinatesData: [CoordinateData], totalDistance: Double, totalElevationGain: Double, duration: TimeInterval) {
        self.id = id
        self.name = name
        self.importedAt = importedAt
        self.activityDate = activityDate
        self.coordinatesData = coordinatesData
        self.totalDistance = totalDistance
        self.totalElevationGain = totalElevationGain
        self.duration = duration
    }
}

extension GPXRoute {
    static func formatDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.2f km", meters / 1000)
        }
        return String(format: "%.0f m", meters)
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
