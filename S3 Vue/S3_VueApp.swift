import SwiftUI

@main
struct S3_VueApp: App {
    @StateObject private var appState = S3AppState()
    #if os(macOS)
        @Environment(\.openWindow) var openWindow
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        #if os(macOS)
            .commands {
                CommandGroup(replacing: .appSettings) {
                    SettingsButton()
                }
                CommandGroup(after: .windowList) {
                    Divider()
                    OpenTransfersWindowButton()
                    OpenDebugWindowButton()
                    OpenHistoryWindowButton()
                }
            }
        #endif

        #if os(macOS)
            Window("Logs de débogage", id: "debug-logs") {
                DebugView()
                    .environmentObject(appState)
            }
        #endif

        #if os(macOS)
            Window("Transferts", id: "transfers") {
                TransferProgressView()
                    .environmentObject(appState)
            }
        #endif

        #if os(macOS)
            Window("Historique des Activités", id: "activity-history") {
                ActivityHistoryView()
                    .environmentObject(appState)
            }
        #endif

        #if os(macOS)
            Window("Réglages", id: "app-settings") {
                NavigationStack {
                    SettingsView()
                        .environmentObject(appState)
                }
            }
            .windowResizability(.contentSize)
        #endif
    }
}

#if os(macOS)
    struct SettingsButton: View {
        @Environment(\.openWindow) var openWindow
        var body: some View {
            Button("Réglages...") {
                openWindow(id: "app-settings")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }

    struct OpenDebugWindowButton: View {
        @Environment(\.openWindow) var openWindow

        var body: some View {
            Button("Afficher les logs de débogage") {
                openWindow(id: "debug-logs")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }

    struct OpenTransfersWindowButton: View {
        @Environment(\.openWindow) var openWindow

        var body: some View {
            Button("Afficher les transferts") {
                openWindow(id: "transfers")
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
        }
    }

    struct OpenHistoryWindowButton: View {
        @Environment(\.openWindow) var openWindow

        var body: some View {
            Button("Afficher l'historique des activités") {
                openWindow(id: "activity-history")
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
        }
    }
#endif
