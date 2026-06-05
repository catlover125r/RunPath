import Foundation

@MainActor
class RouteStorage: ObservableObject {
    static let shared = RouteStorage()
    @Published var routes: [GPXRoute] = []

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var storageURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("routes.json")
    }

    private init() {
        load()
    }

    func save(_ route: GPXRoute) {
        if let idx = routes.firstIndex(where: { $0.id == route.id }) {
            routes[idx] = route
        } else {
            routes.append(route)
        }
        routes.sort { ($0.activityDate ?? $0.importedAt) > ($1.activityDate ?? $1.importedAt) }
        persist()
    }

    func delete(_ route: GPXRoute) {
        routes.removeAll { $0.id == route.id }
        persist()
    }

    private func persist() {
        do {
            let data = try encoder.encode(routes)
            try data.write(to: storageURL)
        } catch {
            print("RouteStorage persist error: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path),
              let data = try? Data(contentsOf: storageURL),
              let decoded = try? decoder.decode([GPXRoute].self, from: data) else { return }
        routes = decoded
    }
}
