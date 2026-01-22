import SwiftUI

struct TransferProgressView: View {
    @EnvironmentObject var appState: S3AppState

    var body: some View {
        VStack(spacing: 0) {
            if appState.transferTasks.isEmpty {
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
                    ForEach(appState.transferTasks) { task in
                        TransferTaskRow(task: task)
                    }
                    .onDelete { indexSet in
                        appState.transferTasks.remove(atOffsets: indexSet)
                    }
                }
            }

            if !appState.transferTasks.isEmpty {
                Divider()
                HStack {
                    Button("Tout effacer") {
                        appState.transferTasks.removeAll {
                            $0.status == .completed || $0.status == .failed
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
    let task: TransferTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(
                    systemName: task.type == .upload
                        ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
                )
                .foregroundColor(task.type == .upload ? .blue : .green)
                Text(task.name)
                    .fontWeight(.medium)
                Spacer()
                if task.status == .completed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else if task.status == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                }
            }

            ProgressView(value: task.progress)
                .progressViewStyle(.linear)

            HStack {
                Text("\(task.completedFiles) / \(task.totalFiles) fichiers")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if let error = task.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(1)
                } else {
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    var statusText: String {
        switch task.status {
        case .pending: return "En attente..."
        case .inProgress: return "\(Int(task.progress * 100))%"
        case .completed: return "Terminé"
        case .failed: return "Échoué"
        }
    }
}
