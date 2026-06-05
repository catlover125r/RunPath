import SwiftUI

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
    @EnvironmentObject var storage: RouteStorage
    @State private var orientation: ExportOrientation = .portrait
    @State private var resolution: ExportResolution = .hd
    @State private var exportProgress: Double = 0
    @State private var isExporting = false
    @State private var exportedURL: URL?
    @State private var exportError: String?
    @State private var showShareSheet = false
    @State private var exporter: VideoExporter?
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
            // Preview thumbnail placeholder
            orientationPreview

            // Orientation picker
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Orientation")
                HStack(spacing: 10) {
                    ForEach(ExportOrientation.allCases, id: \.rawValue) { opt in
                        orientationButton(opt)
                    }
                }
            }

            // Resolution picker
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Resolution")
                HStack(spacing: 10) {
                    ForEach(ExportResolution.allCases, id: \.rawValue) { opt in
                        resolutionButton(opt)
                    }
                }
            }

            if let err = exportError {
                Text(err)
                    .font(.system(size: 13))
                    .foregroundStyle(.red.opacity(0.8))
                    .multilineTextAlignment(.center)
            }

            // Spec summary
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

    private var orientationPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: orientation == .portrait ? 10 : 6, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1.5)
                .frame(
                    width: orientation == .portrait ? 52 : 92,
                    height: orientation == .portrait ? 92 : 52
                )
            Image(systemName: "map.fill")
                .font(.system(size: orientation == .portrait ? 22 : 18))
                .foregroundStyle(.white.opacity(0.2))
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: orientation)
        .frame(height: 100)
    }

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
        }
    }

    // MARK: Done

    private var doneView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.white)

            Text("Export Complete")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)

            Button { showShareSheet = true } label: {
                Label("Share Video", systemImage: "square.and.arrow.up")
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
        let config = VideoExporter.ExportConfig(
            resolution: resolution.size(for: orientation),
            orientation: orientation
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
                    case .success(let url): exportedURL = url
                    case .failure(let err): exportError = err.localizedDescription
                    }
                }
            }
        )
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
