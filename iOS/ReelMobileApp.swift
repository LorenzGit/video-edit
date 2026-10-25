import SwiftUI
import AVFoundation

@main
struct ReelMobileApp: App {
    @StateObject private var editor = EditorViewModel()

    var body: some Scene {
        WindowGroup {
            MobileEditorView()
                .environmentObject(editor)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task {
                    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-reel-ui-testing") || ProcessInfo.processInfo.arguments.contains("-reel-photo-testing") {
                        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Reel-UI-Tests")
                        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                        editor.mobileStorageRoot = root
                    }
                    #endif
                    await editor.restoreMobileDraft()
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-reel-photo-testing") {
                        editor.newMobileProject()
                    }
                    if ProcessInfo.processInfo.arguments.contains("-reel-ui-testing") {
                        editor.newMobileProject()
                        do {
                            let url = try await MobileTestVideo.make(withAudio: true)
                            await editor.importMobileFiles([url])
                        } catch { editor.statusMessage = error.localizedDescription }
                    }
                    #endif
                }
                .onOpenURL { url in
                    Task { await editor.importMobileFiles([url]) }
                }
        }
    }
}
