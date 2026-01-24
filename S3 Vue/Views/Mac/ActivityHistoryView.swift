#if os(macOS)
    import SwiftUI
    import UniformTypeIdentifiers

    struct ActivityHistoryView: View {
        @EnvironmentObject var appState: S3AppState
        @Environment(\.dismiss) var dismiss

        var body: some View {
            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Historique des Activités")
                            .font(.headline)
                        Text("Filtrage des objets modifiés par date")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                .background(Color(NSColor.windowBackgroundColor))

                Divider()

                // Search Bar / Filters
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Date de début").font(.caption).foregroundColor(.secondary)
                        DatePicker(
                            "", selection: $appState.historyStartDate,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .labelsHidden()
                        .controlSize(.small)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Date de fin").font(.caption).foregroundColor(.secondary)
                        DatePicker(
                            "", selection: $appState.historyEndDate,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .labelsHidden()
                        .controlSize(.small)
                    }

                    Spacer()

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
                            Text("Rechercher")
                        }
                        .frame(width: 100)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.isHistoryLoading)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

                Divider()

                // Results Table
                if appState.historyResults.isEmpty && !appState.isHistoryLoading {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "tray.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("Aucun résultat pour cette période")
                            .foregroundColor(.secondary)
                        Text("Essayez d'élargir la plage de dates.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Table(appState.historyResults) {
                        TableColumn("Action") { ver in
                            Image(
                                systemName: ver.isDeleteMarker ? "trash.fill" : "plus.circle.fill"
                            )
                            .foregroundColor(ver.isDeleteMarker ? .red : .green)
                        }
                        .width(40)

                        TableColumn("Fichier") { ver in
                            HStack {
                                Image(
                                    systemName: ver.isDeleteMarker ? "minus.circle" : "doc"
                                )
                                .foregroundColor(.secondary)
                                Text(ver.key)
                                    .font(.system(size: 11, design: .monospaced))
                                    .strikethrough(ver.isDeleteMarker)
                            }
                        }

                        TableColumn("Modifié le") { ver in
                            Text(ver.lastModified.formatted(date: .abbreviated, time: .shortened))
                                .foregroundColor(.secondary)
                        }
                        .width(180)

                        TableColumn("Taille") { ver in
                            Text(ver.isDeleteMarker ? "--" : formatBytes(ver.size))
                                .foregroundColor(.secondary)
                                .font(.system(size: 10))
                        }
                        .width(80)
                    }
                }

                Divider()

                // Footer
                HStack {
                    Text("\(appState.historyResults.count) objets trouvés")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    if !appState.historyResults.isEmpty {
                        Button(action: exportResults) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("Exporter CSV")
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
                .padding(10)
                .background(Color(NSColor.windowBackgroundColor))
            }
            .frame(minWidth: 700, minHeight: 450)
        }

        private func formatBytes(_ bytes: Int64) -> String {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useAll]
            formatter.countStyle = .file
            return formatter.string(fromByteCount: bytes)
        }

        private func exportResults() {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "history_export.csv"

            panel.begin { response in
                if response == .OK, let url = panel.url {
                    var csv = "Key,LastModified,Size\n"
                    for obj in appState.historyResults {
                        csv += "\(obj.key),\(obj.lastModified),\(obj.size)\n"
                    }
                    try? csv.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }
    }
#endif
