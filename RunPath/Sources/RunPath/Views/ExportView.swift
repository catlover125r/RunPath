import SwiftUI
import Photos
import MapKit

enum ExportOrientation: String, CaseIterable {
    case portrait = "Portrait"
    case landscape = "Landscape"

    var icon: String {
        switch self {
        case .portrait: return "iphone"
        case .landscape: return "iphone.landscape"
        }
    }

    var description: String {
        switch self {
        case .portrait: return "9:16 vertical"
        case .landscape: return "16:9 horizontal"
        }
    }
}

enum ExportResolution: String, CaseIterable {
    case hd = "1080"
    case fourK = "4K"

    var label: String { rawValue }

    var description: String {
        switch self {
        case .hd: return "1920 long edge"
        case .fourK: return "3840 long edge"
        }
    }

    func size(for orientation: ExportOrientation) -> CGSize {
        switch (self, orientation) {
        case (.hd, .portrait):   return CGSize(width: 1080, height: 1920)
        case (.hd, .landscape):  return CGSize(width: 1920, height: 1080)
        case (.fourK, .portrait):  return CGSize(width: 2160, height: 3840)
        case (.fourK, .landscape): return CGSize(width: 3840, height: 2160)
        }
    }
}

struct ExportView: View {
    @ObservedObject var vm: AnimationViewModel
    let mapType: MKMapType
    @EnvironmentObject var storage: RouteStorage
    @State private var orientation: ExportOrientation = .portrait
    @State private var resolution: ExportResolution = .hd
    @State private var showStats = true
    @State private var exportProgress: Double = 0
    @State private var isExporting = false
    @State private var isSavingToPhotos = false
    @State private var savedToPhotos = false
    @State private var exportedURL: URL?
    @State private var exportError: String?
    @State private var showShareSheet = false
    @State private var exporter: VideoExporter?
    @State private var exportStartTime: Date?
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.07).ignoresSafeArea()
                VStack(spacing: 28) {
                    if isExporting {
                        exportingView
                    } else if exportedURL != nil {
                        doneView
                    } else {
                        readyView
                    }
                }
                .padding(28)
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        exporter?.cancel()
                        dismiss()
                    }
                    .foregroundStyle(.white)
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = exportedURL { ShareSheet(url: url) }
        }
    }

    // MARK: Ready

    private var readyView: some View {
        VStack(spacing: 32) {
            orientationPreview

            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Orientation")
                HStack(spacing: 10) {
                    ForEach(ExportOrientation.allCases, id: \.rawValue) { opt in
                        orientationButton(opt)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Resolution")
                HStack(spacing: 10) {
                    ForEach(ExportResolution.allCases, id: \.rawValue) { opt in
                        resolutionButton(opt)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Overlay")
                Toggle(isOn: $showStats) {
                    HStack(spacing: 10) {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 15))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Run Stats")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Distance, time & pace")
                                .font(.system(size: 11))
                                .opacity(0.55)
                        }
                    }
                }
                .toggleStyle(.switch)
                .tint(Color.white)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if let err = exportError {
                Text(err)
                    .font(.system(size: 13))
                    .foregroundStyle(.red.opacity(0.8))
                    .multilineTextAlignment(.center)
            }

            let size = resolution.size(for: orientation)
            Text("\(Int(size.width)) × \(Int(size.height))  ·  H.264  ·  30 fps")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))

            Button { startExport() } label: {
                Text("Start Export")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Orientation / stats preview

    private var orientationPreview: some View {
        let isPortrait = orientation == .portrait
        let w: CGFloat = isPortrait ? 52 : 92
        let h: CGFloat = isPortrait ? 92 : 52
        let r: CGFloat = isPortrait ? 10 : 6

        return ZStack {
            // Dark map-like fill
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(Color(white: 0.17))

            if showStats {
                statsPreview(w: w, h: h, isPortrait: isPortrait, cornerRadius: r)
            } else {
                Image(systemName: "map.fill")
                    .font(.system(size: isPortrait ? 22 : 18))
                    .foregroundStyle(.white.opacity(0.2))
            }

            RoundedRectangle(cornerRadius: r, style: .continuous)
                .stroke(Color.white.opacity(showStats ? 0.25 : 0.15), lineWidth: 1.5)
        }
        .frame(width: w, height: h)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: orientation)
        .animation(.easeInOut(duration: 0.22), value: showStats)
        .frame(height: 100)
    }

    // Computed outside @ViewBuilder so imperative string-building doesn't
    // produce Void expressions that the result builder can't handle.
    private func previewStats() -> (dist: String, time: String, pace: String) {
        guard let r = vm.route else { return ("—", "—", "—") }
        let dist = GPXRoute.formatDistance(r.totalDistance)
        let time = GPXRoute.formatDuration(r.duration)
        let pace: String = {
            guard r.totalDistance > 0, r.duration > 0 else { return "—" }
            let s = r.duration / (r.totalDistance / 1000)
            return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
        }()
        return (dist, time, pace)
    }

    @ViewBuilder
    private func statsPreview(w: CGFloat, h: CGFloat, isPortrait: Bool, cornerRadius: CGFloat) -> some View {
        let stats = previewStats()
        let distStr = stats.dist
        let timeStr = stats.time
        let paceStr = stats.pace

        if isPortrait {
            // Gradient rises from the bottom; stats in a row at the bottom edge
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.88)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: h * 0.50)
                    .frame(maxWidth: .infinity, alignment: .bottom)
                    .frame(height: h, alignment: .bottom)

                HStack(alignment: .bottom, spacing: 0) {
                    miniStatCell(label: "TIME",  value: timeStr, valSize: h * 0.105)
                        .frame(maxWidth: .infinity)
                    miniStatCell(label: "DIST",  value: distStr, valSize: h * 0.145)
                        .frame(maxWidth: .infinity)
                    miniStatCell(label: "PACE",  value: paceStr, valSize: h * 0.105)
                        .frame(maxWidth: .infinity)
                }
                .padding(.bottom, h * 0.07)
                .padding(.horizontal, 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            // Landscape: gradient from left, stats stacked vertically on the left
            ZStack {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.88), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: w * 0.55)
                    Spacer(minLength: 0)
                }

                HStack {
                    VStack(alignment: .center, spacing: max(1, h * 0.06)) {
                        miniStatCell(label: "DIST",  value: distStr, valSize: h * 0.20)
                        miniStatCell(label: "TIME",  value: timeStr, valSize: h * 0.13)
                        miniStatCell(label: "PACE",  value: paceStr, valSize: h * 0.13)
                    }
                    .frame(width: w * 0.46)
                    .frame(maxHeight: .infinity, alignment: .center)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    private func miniStatCell(label: String, value: String, valSize: CGFloat) -> some View {
        VStack(spacing: 0.5) {
            Text(label)
                .font(.system(size: max(3, valSize * 0.44), weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            Text(value)
                .font(.system(size: max(4, valSize), weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
        }
    }

    // MARK: Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.35))
            .kerning(1.2)
    }

    private func orientationButton(_ opt: ExportOrientation) -> some View {
        let isSelected = orientation == opt
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                orientation = opt
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: opt.icon)
                    .font(.system(size: 15))
                VStack(alignment: .leading, spacing: 2) {
                    Text(opt.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                    Text(opt.description)
                        .font(.system(size: 11))
                        .opacity(0.6)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundStyle(isSelected ? Color.black : Color.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.white : Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func resolutionButton(_ opt: ExportResolution) -> some View {
        let isSelected = resolution == opt
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                resolution = opt
            }
        } label: {
            VStack(spacing: 4) {
                Text(opt.label)
                    .font(.system(size: 20, weight: .bold))
                Text(opt.description)
                    .font(.system(size: 11))
                    .opacity(0.6)
            }
            .foregroundStyle(isSelected ? Color.black : Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(isSelected ? Color.white : Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Exporting

    private var exportingView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 4)
                    .frame(width: 80, height: 80)
                Circle()
                    .trim(from: 0, to: exportProgress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.1), value: exportProgress)
                Text("\(Int(exportProgress * 100))%")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            }
            Text("Rendering frames…")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.5))
            let size = resolution.size(for: orientation)
            Text("\(Int(size.width)) × \(Int(size.height))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.25))
            if let eta = estimatedTimeRemaining {
                Text(eta)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }
            Text("Keep this screen open while rendering")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.2))
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
    }

    private var estimatedTimeRemaining: String? {
        guard exportProgress > 0.04, let start = exportStartTime else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        let total = elapsed / exportProgress
        let remaining = total - elapsed
        if remaining < 60 { return "~\(Int(remaining))s remaining" }
        return "~\(Int(remaining / 60))m \(Int(remaining.truncatingRemainder(dividingBy: 60)))s remaining"
    }

    // MARK: Done

    private var doneView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 80, height: 80)
                if isSavingToPhotos {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                } else {
                    Image(systemName: savedToPhotos ? "photo.fill" : "checkmark")
                        .font(.system(size: savedToPhotos ? 28 : 32, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }

            VStack(spacing: 6) {
                Text(savedToPhotos ? "Saved to Photos" : "Export Complete")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                if savedToPhotos {
                    Text("Find it in your Photos library")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            Button { showShareSheet = true } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)

            Button {
                exportedURL = nil
                exportProgress = 0
                exportError = nil
                savedToPhotos = false
            } label: {
                Text("Export Again")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Export action

    private func startExport() {
        guard let route = vm.route else { return }
        isExporting = true
        exportError = nil
        exportProgress = 0
        exportStartTime = Date()
        let config = VideoExporter.ExportConfig(
            resolution: resolution.size(for: orientation),
            orientation: orientation,
            mapType: mapType,
            showStats: showStats
        )
        let e = VideoExporter()
        exporter = e
        e.export(
            route: route,
            settings: vm.animationSettings,
            config: config,
            progress: { @Sendable p in
                Task { @MainActor in exportProgress = p }
            },
            completion: { @Sendable result in
                Task { @MainActor in
                    isExporting = false
                    switch result {
                    case .success(let url):
                        exportedURL = url
                        saveToPhotos(url: url)
                    case .failure(let err):
                        exportError = err.localizedDescription
                    }
                }
            }
        )
    }

    private func saveToPhotos(url: URL) {
        isSavingToPhotos = true
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in isSavingToPhotos = false }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, _ in
                Task { @MainActor in
                    isSavingToPhotos = false
                    savedToPhotos = success
                }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
