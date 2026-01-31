import AppIntents
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
                .onAppear {
                    if #available(macOS 13.0, iOS 16.0, *) {
                        S3Shortcuts.updateAppShortcutParameters()
                    }
                }
        }
        #if os(macOS)
            .commands {
                CommandGroup(replacing: .appInfo) {
                    AboutButton()
                }
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
            Window("À propos de S3 Next", id: "about-window") {
                AboutView()
            }
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)

            Window("Réglages", id: "app-settings") {
                NavigationStack {
                    SettingsView()
                        .environmentObject(appState)
                }
            }
            .windowResizability(.contentSize)

            Window("Création de bucket", id: "create-bucket") {
                CreateBucketView()
                    .environmentObject(appState)
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

    struct AboutButton: View {
        @Environment(\.openWindow) var openWindow
        var body: some View {
            Button("À propos de S3 Next") {
                openWindow(id: "about-window")
            }
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
