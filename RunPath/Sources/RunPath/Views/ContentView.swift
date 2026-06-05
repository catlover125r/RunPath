import SwiftUI
import MapKit

struct ContentView: View {
    @EnvironmentObject var storage: RouteStorage
    @StateObject private var vm = AnimationViewModel()
    @State private var sidebarOpen = false
    @State private var showExport = false
    @State private var showEmptyHint = true
    @State private var useSatellite = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Full-screen map
            mapLayer

            // Overlay UI
            VStack(spacing: 0) {
                topBar
                Spacer()
                if vm.route != nil {
                    bottomControls
                }
            }

            // Sidebar overlay
            if sidebarOpen {
                SidebarView(vm: vm, isOpen: $sidebarOpen)
                    .zIndex(10)
                    .transition(.identity)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showExport) {
            ExportView(vm: vm, mapType: useSatellite ? .hybridFlyover : .standard)
        }
        .onOpenURL { url in
            handleIncomingURL(url)
        }
    }

    // MARK: Map layer

    private var mapLayer: some View {
        ZStack {
            if vm.route != nil {
                AnimatedMapView(vm: vm, mapType: useSatellite ? .hybridFlyover : .standard)
                    .ignoresSafeArea()
            } else {
                emptyMapBackground
            }
        }
    }

    private var emptyMapBackground: some View {
        ZStack {
            Color(white: 0.06).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "map")
                    .font(.system(size: 48))
                    .foregroundStyle(.white.opacity(0.15))
                Text("Open a route to begin")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.25))
                Text("Share a GPX file from COROS\nand choose RunPath")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.15))
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    sidebarOpen.toggle()
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            HStack(spacing: 10) {
                if vm.route != nil {
                    // Satellite / Standard toggle
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            useSatellite.toggle()
                        }
                    } label: {
                        Image(systemName: useSatellite ? "globe.americas.fill" : "map")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        showExport = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Export")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 60)
    }

    // MARK: Bottom controls

    private var bottomControls: some View {
        VStack(spacing: 10) {
            // Play/pause row — rewind left of centered play button
            HStack(spacing: 14) {
                Button {
                    vm.seek(to: 0)
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)

                Button {
                    switch vm.playbackState {
                    case .playing: vm.pause()
                    case .paused, .idle, .finished: vm.play()
                    }
                } label: {
                    Image(systemName: playIcon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 50, height: 50)
                        .background(Color.white, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)

            // Timeline
            TimelineView(vm: vm)
        }
        .padding(.bottom, 32)
    }

    private var playIcon: String {
        switch vm.playbackState {
        case .playing: return "pause.fill"
        default: return "play.fill"
        }
    }

    // MARK: File import

    func handleIncomingURL(_ url: URL) {
        guard url.pathExtension.lowercased() == "gpx" else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let parser = GPXParser()
        guard let route = try? parser.parse(data: data) else { return }
        storage.save(route)
        vm.loadRoute(route)
    }
}
