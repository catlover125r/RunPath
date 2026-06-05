import SwiftUI

struct ExportView: View {
    @ObservedObject var vm: AnimationViewModel
    @EnvironmentObject var storage: RouteStorage
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
            if let url = exportedURL {
                ShareSheet(url: url)
            }
        }
    }

    private var readyView: some View {
        VStack(spacing: 24) {
            Image(systemName: "film.stack")
                .font(.system(size: 52))
                .foregroundStyle(.white.opacity(0.5))

            VStack(spacing: 6) {
                Text("Export Video")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                Text("1080 × 1920 · H.264 · 30fps")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.4))
            }

            if let err = exportError {
                Text(err)
                    .font(.system(size: 13))
                    .foregroundStyle(.red.opacity(0.8))
                    .multilineTextAlignment(.center)
            }

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
        }
    }

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

            Button { exportedURL = nil; exportProgress = 0; exportError = nil } label: {
                Text("Export Again")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
    }

    private func startExport() {
        guard let route = vm.route else { return }
        isExporting = true
        exportError = nil
        exportProgress = 0
        let e = VideoExporter()
        exporter = e
        e.export(
            route: route,
            settings: vm.animationSettings,
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
