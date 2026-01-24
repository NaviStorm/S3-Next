import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    struct ActivityHistoryView_iOS: View {
        @EnvironmentObject var appState: S3AppState
        @Environment(\.dismiss) var dismiss
        @State private var csvURL: URL? = nil

        var body: some View {
            NavigationStack {
                VStack(spacing: 0) {
                    // Filters Header
                    VStack(spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Date de début").font(.caption).foregroundColor(.secondary)
                                DatePicker(
                                    "", selection: $appState.historyStartDate,
                                    displayedComponents: [.date, .hourAndMinute]
                                )
                                .labelsHidden()
                                .controlSize(.small)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("Date de fin").font(.caption).foregroundColor(.secondary)
                                DatePicker(
                                    "", selection: $appState.historyEndDate,
                                    displayedComponents: [.date, .hourAndMinute]
                                )
                                .labelsHidden()
                                .controlSize(.small)
                            }
                        }

                        Button(action: {
                            let currentPrefix =
                                appState.currentPath.isEmpty
                                ? "" : appState.currentPath.joined(separator: "/") + "/"
                            appState.loadHistory(for: currentPrefix)
                        }) {
                            HStack {
                                if appState.isHistoryLoading {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "magnifyingglass")
                                }
                                Text("Rechercher dans ce dossier")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.isHistoryLoading)
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))

                    Divider()

                    // Results
                    if appState.historyResults.isEmpty && !appState.isHistoryLoading {
                        VStack(spacing: 20) {
                            Spacer()
                            Image(systemName: "tray.fill")
                                .font(.system(size: 60))
                                .foregroundColor(.secondary.opacity(0.3))
                            Text("Aucun résultat")
                                .font(.headline)
                            Text("Ajustez vos dates ou rafraîchissez.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    } else {
                        List(appState.historyResults) { ver in
                            historyRow(for: ver)
                        }
                        .listStyle(.plain)
                    }
                }
                .navigationTitle("Historique")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fermer") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if !appState.historyResults.isEmpty {
                            Button(action: prepareExport) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                }
                .sheet(
                    isPresented: Binding(
                        get: { csvURL != nil },
                        set: { if !$0 { csvURL = nil } }
                    )
                ) {
                    if let url = csvURL {
                        ActivityView(activityItems: [url])
                    }
                }
            }
        }

        @ViewBuilder
        private func historyRow(for ver: S3Version) -> some View {
            HStack(spacing: 12) {
                Image(systemName: ver.isDeleteMarker ? "trash.fill" : "plus.circle.fill")
                    .foregroundColor(ver.isDeleteMarker ? .red : .green)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(ver.key)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .lineLimit(2)
                        .strikethrough(ver.isDeleteMarker)
                        .foregroundColor(ver.isDeleteMarker ? .secondary : .primary)

                    HStack {
                        Text(ver.lastModified.formatted(date: .abbreviated, time: .shortened))
                        if !ver.isDeleteMarker {
                            Text("•")
                            Text(formatBytes(ver.size))
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
        }

        private func formatBytes(_ bytes: Int64) -> String {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useAll]
            formatter.countStyle = .file
            return formatter.string(fromByteCount: bytes)
        }

        private func prepareExport() {
            var csv = "Action,Key,LastModified,Size\n"
            for ver in appState.historyResults {
                let action = ver.isDeleteMarker ? "DELETE" : "PUT/POST"
                csv += "\(action),\(ver.key),\(ver.lastModified),\(ver.size)\n"
            }

            let tempDir = FileManager.default.temporaryDirectory
            let fileURL = tempDir.appendingPathComponent("history_export.csv")
            try? csv.write(to: fileURL, atomically: true, encoding: .utf8)
            self.csvURL = fileURL
        }
    }

#endif
