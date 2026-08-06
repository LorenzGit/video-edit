import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var vm: EditorViewModel
    @State private var isDropTarget = false
    @State private var toastToken = UUID()

    var body: some View {
        ZStack {
            Theme.backgroundGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                if vm.sourceURL == nil {
                    EmptyStateView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PreviewSection()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    TransportBar()
                    ControlBar()
                    TimelineView()
                }
            }

            if isDropTarget {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .background(Theme.accentSoft.cornerRadius(16))
                    .padding(10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 720, minHeight: 600)
        .preferredColorScheme(.dark)
        .overlay(alignment: .bottom) {
            if let message = vm.statusMessage, vm.sourceURL != nil, !vm.isExporting {
                StatusToast(message: message)
                    .padding(.bottom, 26)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay { if vm.isExporting { ExportOverlay() } }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
        .onChange(of: vm.statusMessage) { _, newValue in
            guard newValue != nil else { return }
            let token = UUID()
            toastToken = token
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if toastToken == token { vm.statusMessage = nil }
            }
        }
        .animation(.easeOut(duration: 0.15), value: isDropTarget)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: vm.statusMessage)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                if isVideoFile(url) {
                    // Append to an open project, otherwise start a new one.
                    if vm.hasContent { vm.importVideo(url: url) } else { vm.openVideo(url: url) }
                } else if vm.hasContent, isAudioFile(url) {
                    vm.importAudio(url: url)
                }
            }
        }
        return true
    }

    private func isVideoFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    private func isAudioFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio)
    }
}
