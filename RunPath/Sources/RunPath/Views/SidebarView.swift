import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var storage: RouteStorage
    @ObservedObject var vm: AnimationViewModel
    @Binding var isOpen: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            if isOpen {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .transition(.opacity)
            }

            HStack(spacing: 0) {
                drawer
                Spacer()
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: isOpen)
    }

    private var drawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Routes")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button { close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 60)
            .padding(.bottom, 20)

            Divider().overlay(Color.white.opacity(0.1))

            if storage.routes.isEmpty {
                emptyState
            } else {
                routeList
            }
        }
        .frame(width: 300)
        .background(
            Color(white: 0.08)
                .ignoresSafeArea()
        )
        .offset(x: isOpen ? 0 : -320)
    }

    private var routeList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(storage.routes) { route in
                    RouteRowView(route: route, isActive: vm.route?.id == route.id) {
                        vm.loadRoute(route)
                        close()
                    } onDelete: {
                        withAnimation { storage.delete(route) }
                        if vm.route?.id == route.id { vm.route = nil }
                    }
                    Divider().overlay(Color.white.opacity(0.07)).padding(.leading, 20)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "map")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.2))
            Text("No routes yet")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.3))
            Text("Share a GPX file from COROS\nand choose RunPath")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.2))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private func close() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            isOpen = false
        }
    }
}

struct RouteRowView: View {
    let route: GPXRoute
    let isActive: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var showMenu = false

    private var displayDate: String {
        let date = route.activityDate ?? route.importedAt
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(isActive ? Color.white : Color.white.opacity(0.08))
                            .frame(width: 40, height: 40)
                        Image(systemName: "figure.run")
                            .font(.system(size: 16))
                            .foregroundStyle(isActive ? .black : .white.opacity(0.5))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(route.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(displayDate)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                        HStack(spacing: 8) {
                            Label(GPXRoute.formatDistance(route.totalDistance),
                                  systemImage: "arrow.left.and.right")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            Menu {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete Route", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .padding(.trailing, 8)
        }
        .padding(.leading, 20)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(isActive ? Color.white.opacity(0.05) : .clear)
    }
}
