import Foundation
import CoreLocation

class GPXParser: NSObject, XMLParserDelegate {

    private var coordinates: [GPXRoute.CoordinateData] = []
    private var currentLat: Double?
    private var currentLon: Double?
    private var currentEle: Double = 0
    private var currentTime: Date?
    private var currentElement = ""
    private var trackName = ""
    private var routeName = ""
    private var parseError: Error?

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private let dateFormatterAlt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    func parse(data: Data) throws -> GPXRoute {
        coordinates = []
        currentLat = nil
        currentLon = nil
        currentEle = 0
        currentTime = nil
        trackName = ""
        routeName = ""
        parseError = nil

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()

        if let err = parseError { throw err }
        guard !coordinates.isEmpty else {
            throw GPXError.noCoordinates
        }

        let name = trackName.isEmpty ? (routeName.isEmpty ? "Route" : routeName) : trackName
        let smoothedCoords = smoothCoordinates(coordinates)
        let distance = computeDistance(smoothedCoords)
        let gain = computeElevationGain(smoothedCoords)
        let duration = computeDuration(smoothedCoords)
        let activityDate = smoothedCoords.first?.timestamp.map { Date(timeIntervalSince1970: $0) }

        return GPXRoute(
            name: name,
            activityDate: activityDate,
            coordinatesData: smoothedCoords,
            totalDistance: distance,
            totalElevationGain: gain,
            duration: duration
        )
    }

    private func smoothCoordinates(_ coords: [GPXRoute.CoordinateData]) -> [GPXRoute.CoordinateData] {
        guard coords.count > 10 else { return coords }
        var result: [GPXRoute.CoordinateData] = []
        for (i, c) in coords.enumerated() {
            if i == 0 || i == coords.count - 1 {
                result.append(c)
                continue
            }
            let prev = coords[i - 1]
            let next = coords[i + 1]
            let lat = (prev.latitude + c.latitude + next.latitude) / 3
            let lon = (prev.longitude + c.longitude + next.longitude) / 3
            result.append(GPXRoute.CoordinateData(
                latitude: lat, longitude: lon,
                elevation: c.elevation, timestamp: c.timestamp, speed: c.speed
            ))
        }
        return result
    }

    private func computeDistance(_ coords: [GPXRoute.CoordinateData]) -> Double {
        var total = 0.0
        for i in 1..<coords.count {
            let a = CLLocation(latitude: coords[i-1].latitude, longitude: coords[i-1].longitude)
            let b = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
            total += a.distance(from: b)
        }
        return total
    }

    private func computeElevationGain(_ coords: [GPXRoute.CoordinateData]) -> Double {
        var gain = 0.0
        for i in 1..<coords.count {
            let diff = coords[i].elevation - coords[i-1].elevation
            if diff > 0 { gain += diff }
        }
        return gain
    }

    private func computeDuration(_ coords: [GPXRoute.CoordinateData]) -> TimeInterval {
        guard let first = coords.first?.timestamp, let last = coords.last?.timestamp else { return 0 }
        return (last ?? 0) - (first ?? 0)
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = element
        if element == "trkpt" || element == "wpt" || element == "rtept" {
            currentLat = Double(attributes["lat"] ?? "")
            currentLon = Double(attributes["lon"] ?? "")
            currentEle = 0
            currentTime = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        switch currentElement {
        case "ele": currentEle = Double(s) ?? 0
        case "time":
            currentTime = dateFormatter.date(from: s) ?? dateFormatterAlt.date(from: s)
        case "name":
            if trackName.isEmpty { trackName = s }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                qualifiedName: String?) {
        if element == "trkpt" || element == "wpt" || element == "rtept" {
            if let lat = currentLat, let lon = currentLon {
                coordinates.append(GPXRoute.CoordinateData(
                    latitude: lat, longitude: lon,
                    elevation: currentEle,
                    timestamp: currentTime?.timeIntervalSince1970,
                    speed: nil
                ))
            }
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}

enum GPXError: LocalizedError {
    case noCoordinates
    case invalidFile

    var errorDescription: String? {
        switch self {
        case .noCoordinates: return "No track coordinates found in GPX file."
        case .invalidFile: return "Could not read GPX file."
        }
    }
}
