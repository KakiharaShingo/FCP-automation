import SwiftUI

@main
struct FCP_automationApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var youtubeState = YouTubeEditorState()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(appState)
                .environmentObject(youtubeState)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { appState.loadSettings() }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 750)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
