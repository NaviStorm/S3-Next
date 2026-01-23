import SwiftUI

struct TransferProgressView: View {
    @EnvironmentObject var appState: S3AppState

    var body: some View {
        VStack(spacing: 0) {
            if appState.transferManager.transferTasks.isEmpty {
                VStack {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("Aucun transfert en cours")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(appState.transferManager.transferTasks) { transferTask in
                        TransferTaskRow(transferTask: transferTask)
                    }
                    .onDelete { indexSet in
                        appState.transferManager.transferTasks.remove(atOffsets: indexSet)
                    }
                }
            }

            if !appState.transferManager.transferTasks.isEmpty {
                Divider()
                HStack {
                    Button("Tout effacer") {
                        appState.transferManager.transferTasks.removeAll {
                            $0.status == .completed || $0.status == .failed
                                || $0.status == .cancelled
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)

                    Spacer()
                }
                .padding(8)
            }
        }
        .frame(minWidth: 400, minHeight: 300)
    }
}

struct TransferTaskRow: View {
    @EnvironmentObject var appState: S3AppState
    let transferTask: TransferTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(
                    systemName: transferTask.type == .upload
                        ? "arrow.up.circle.fill"
                        : transferTask.type == .download
                            ? "arrow.down.circle.fill"
                            : transferTask.type == .rename
                                ? "pencil.circle.fill" : "trash.circle.fill"
                )
                .foregroundColor(
                    transferTask.type == .upload
                        ? .blue
                        : transferTask.type == .download
                            ? .green : transferTask.type == .rename ? .orange : .red
                )
                Text(transferTask.name)
                    .fontWeight(.medium)
                Spacer()
                if transferTask.status == .completed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else if transferTask.status == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                } else if transferTask.status == .cancelled {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                } else if transferTask.status == .inProgress {
                    Button(action: { appState.cancelTask(id: transferTask.id) }) {
                        Image(systemName: "xmark.circle")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            ProgressView(value: transferTask.progress)
                .progressViewStyle(.linear)
                .tint(transferTask.status == .cancelled ? .gray : .blue)

            HStack {
                Text(
                    transferTask.type == .upload || transferTask.type == .download
                        ? "\(transferTask.completedFiles) / \(transferTask.totalFiles) fichiers"
                        : "\(transferTask.completedFiles) / \(transferTask.totalFiles) objets"
                )
                .font(.caption)
                .foregroundColor(.secondary)

                Spacer()

                if let error = transferTask.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(1)
                } else {
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(transferTask.status == .cancelled ? .gray : .secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    var statusText: String {
        switch transferTask.status {
        case .pending: return "En attente..."
        case .inProgress: return "\(Int(transferTask.progress * 100))%"
        case .completed: return "Terminé"
        case .failed: return "Échoué"
        case .cancelled: return "Annulé"
        }
    }
}
