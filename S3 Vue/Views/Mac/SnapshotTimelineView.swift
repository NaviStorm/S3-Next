#if os(macOS)
    import SwiftUI

    struct SnapshotTimelineView: View {
        @EnvironmentObject var appState: S3AppState
        @Environment(\.dismiss) var dismiss

        @State private var selectionA: UUID?
        @State private var selectionB: UUID?

        var body: some View {
            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("S3 Next Time Machine")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("Bucket: \(appState.bucket)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Fermer") { dismiss() }
                        .keyboardShortcut(.escape, modifiers: [])
                }
                .padding()
                .background(Color(NSColor.windowBackgroundColor))

                Divider()

                if appState.savedSnapshots.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 50))
                            .foregroundColor(.secondary)
                        Text("Aucun instantane disponible")
                            .font(.headline)
                        Text("Capturez l'etat actuel pour commencer votre historique.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        Button(action: { appState.takeSnapshot() }) {
                            Label(
                                appState.isScanning ? "Scan en cours..." : "Capturer maintenant",
                                systemImage: "camera.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.isScanning)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section(header: Text("Instantanes disponibles")) {
                            ForEach(appState.savedSnapshots) { snapshot in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(snapshot.displayName)
                                            .fontWeight(.medium)
                                        Text("\(snapshot.objectCount) objets")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    // Selection A (Base)
                                    SelectionToggle(
                                        label: "Tn", isSelected: selectionA == snapshot.id
                                    ) {
                                        selectionA = (selectionA == snapshot.id) ? nil : snapshot.id
                                    }

                                    // Selection B (Cible)
                                    SelectionToggle(
                                        label: "Tx", isSelected: selectionB == snapshot.id
                                    ) {
                                        selectionB = (selectionB == snapshot.id) ? nil : snapshot.id
                                    }

                                    Button(role: .destructive) {
                                        SnapshotManager.shared.delete(snapshot)
                                        appState.loadSavedSnapshots()
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.leading, 10)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }

                    // Barre d'actions en bas
                    VStack(spacing: 12) {
                        if let selA = selectionA, let selB = selectionB, selA != selB {
                            HStack {
                                Image(systemName: "arrow.left.arrow.right.circle.fill")
                                    .foregroundColor(.blue)
                                Text("Comparer Tn et Tx")
                                    .fontWeight(.bold)
                                Spacer()
                                Button("Lancer le Diff") {
                                    appState.compareSnapshots(idA: selA, idB: selB)
                                    dismiss()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding()
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                        } else if selectionA != nil || selectionB != nil {
                            Text("Selectionnez deux instantanes pour comparer les differences.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.bottom, 5)
                        }

                        HStack {
                            Button(action: { appState.takeSnapshot() }) {
                                Label(
                                    appState.isScanning ? "Scan en cours..." : "Nouvelle Capture",
                                    systemImage: "camera.fill")
                            }
                            .disabled(appState.isScanning)

                            Spacer()

                            if appState.activeComparison != nil {
                                Button("Effacer la comparaison actuelle") {
                                    appState.clearComparison()
                                    selectionA = nil
                                    selectionB = nil
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                }
            }
            .frame(width: 500, height: 600)
        }
    }

    struct SelectionToggle: View {
        let label: String
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isSelected ? Color.blue : Color.secondary.opacity(0.2))
                    .foregroundColor(isSelected ? .white : .primary)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
        }
    }
#endif
