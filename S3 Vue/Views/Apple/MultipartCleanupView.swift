import SwiftUI

struct MultipartCleanupView: View {
    @EnvironmentObject var appState: S3AppState

    var body: some View {
        VStack(spacing: 0) {
            if appState.isOrphanLoading {
                VStack {
                    ProgressView()
                    Text("Recherche des transferts abandonnés...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.orphanUploads.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 48))
                        .foregroundColor(.green)
                    Text("Aucun transfert abandonné trouvé.")
                        .font(.headline)
                    Button("Actualiser") {
                        appState.loadOrphanUploads()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(appState.orphanUploads) { upload in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(upload.key)
                                        .font(.headline)
                                    Text("ID: \(upload.uploadId)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Text(
                                        "Initié le : \(upload.initiated.formatted(date: .abbreviated, time: .shortened))"
                                    )
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                                }

                                Spacer()

                                Button(role: .destructive) {
                                    appState.abortOrphanUpload(
                                        key: upload.key, uploadId: upload.uploadId)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        HStack {
                            Text("\(appState.orphanUploads.count) Transferts en cours")
                            Spacer()
                            Button("Tout supprimer", role: .destructive) {
                                appState.abortAllOrphanUploads()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .navigationTitle("Transferts abandonnés")
        #if os(macOS)
            .frame(minWidth: 500, minHeight: 400)
        #endif
        .onAppear {
            appState.loadOrphanUploads()
        }
    }
}
