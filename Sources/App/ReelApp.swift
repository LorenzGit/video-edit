import SwiftUI

@main
struct ReelApp: App {
    @StateObject private var vm = EditorViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1320, height: 820)
        .commands { AppCommands(vm: vm) }
    }
}
