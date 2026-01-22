import SwiftUI

@main
struct S3_VueApp: App {
    @StateObject private var appState = S3AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        #if os(macOS)
            .commands {
                CommandMenu("Débogage") {
                    OpenDebugWindowButton()
                }
                CommandMenu("Fenêtre") {
                    OpenTransfersWindowButton()
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
            Settings {
                NavigationStack {
                    SettingsView()
                        .environmentObject(appState)
                }
            }
        #endif
    }
}

#if os(macOS)
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
#endif
