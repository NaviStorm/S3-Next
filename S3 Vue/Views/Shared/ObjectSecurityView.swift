import SwiftUI

#if !os(macOS)
    import UIKit
#endif

struct ObjectSecurityView: View {
    @EnvironmentObject var appState: S3AppState
    let objectKey: String

    @State private var selectedMode: S3RetentionMode = .governance
    @State private var expirationDate = Date().addingTimeInterval(86400 * 30)
    @State private var showingComplianceWarning = false
    @State private var animateContent = false

    var body: some View {
        ZStack {
            #if os(macOS)
                VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                    .ignoresSafeArea()
            #else
                Color(UIColor.systemGroupedBackground)
                    .ignoresSafeArea()
            #endif

            ScrollView {
                VStack(spacing: 24) {
                    headerSection
                        .offset(y: animateContent ? 0 : 10)
                        .opacity(animateContent ? 1 : 0)

                    if appState.isSecurityLoading {
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.large)
                            Text("Analyse de la sécurité...")
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        VStack(spacing: 20) {
                            // Section Legal Hold
                            SecurityCard(
                                title: "Conservation Légale",
                                icon: "lock.shield.fill",
                                color: .blue,
                                isWarning: false
                            ) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Toggle(
                                        isOn: Binding(
                                            get: { appState.selectedObjectLegalHold },
                                            set: { _ in appState.toggleLegalHold(for: objectKey) }
                                        )
                                    ) {
                                        Text(
                                            appState.selectedObjectLegalHold
                                                ? "Legal Hold Activé" : "Legal Hold Désactivé"
                                        )
                                        .fontWeight(.medium)
                                    }
                                    .toggleStyle(.switch)
                                    .disabled(appState.bucketObjectLockEnabled == false)

                                    Text(
                                        "Le Legal Hold empêche toute suppression ou modification sans date d'expiration."
                                    )
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                }
                            }

                            // Section Retention
                            SecurityCard(
                                title: "Rétention Temporelle",
                                icon: "clock.badge.checkmark.fill",
                                color: .orange,
                                isWarning: appState.selectedObjectRetention?.mode == .compliance
                            ) {
                                retentionContent
                            }

                            if appState.bucketObjectLockEnabled == false {
                                bucketLockWarning
                            }
                        }
                        .offset(y: animateContent ? 0 : 20)
                    }
                }
                .padding(24)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: animateContent)
        .onAppear {
            // S'assurer que les données sont chargées
            appState.loadSecurityStatus(for: objectKey)
            appState.loadBucketConfiguration()

            // Petit délai pour l'animation d'entrée
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                animateContent = true
            }
        }
    }

    private var headerSection: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.blue, .purple], startPoint: .topLeading,
                            endPoint: .bottomTrailing)
                    )
                    .frame(width: 56, height: 56)
                    .shadow(color: .blue.opacity(0.3), radius: 8, x: 0, y: 4)

                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Sécurité")
                    .font(.system(size: 22, weight: .bold))
                Text(objectKey)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var retentionContent: some View {
        if let retention = appState.selectedObjectRetention {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Badge(
                        text: retention.mode.rawValue,
                        color: retention.mode == .compliance ? .red : .orange)
                    Spacer()
                    Text("Jusqu'au")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text(retention.retainUntilDate.formatted(date: .long, time: .shortened))
                    .font(.headline)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Prolonger la durée")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)

                    datePickerSection
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Picker("", selection: $selectedMode) {
                    Text("Governance").tag(S3RetentionMode.governance)
                    Text("Compliance").tag(S3RetentionMode.compliance)
                }
                .pickerStyle(.segmented)
                .disabled(appState.bucketObjectLockEnabled == false)

                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        selectedMode == .governance
                            ? "Mode Governance : Les administrateurs peuvent encore supprimer l'objet."
                            : "Mode Compliance : Strictement IMPOSSIBLE de supprimer l'objet avant expiration."
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    datePickerSection
                }

                Button {
                    if selectedMode == .compliance {
                        showingComplianceWarning = true
                    } else {
                        appState.updateRetention(
                            for: objectKey, mode: selectedMode, until: expirationDate)
                    }
                } label: {
                    HStack {
                        Image(systemName: "lock.circle.fill")
                        Text("Activer")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(appState.bucketObjectLockEnabled == false)
                .alert("💥 Action Irréversible", isPresented: $showingComplianceWarning) {
                    Button("Annuler", role: .cancel) {}
                    Button("Confirmer", role: .destructive) {
                        appState.updateRetention(
                            for: objectKey, mode: .compliance, until: expirationDate)
                    }
                } message: {
                    Text(
                        "En mode COMPLIANCE, ce fichier sera protégé de TOUTE suppression jusqu'au \(expirationDate.formatted(date: .long, time: .omitted))."
                    )
                }
            }
        }
    }

    private var bucketLockWarning: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundColor(.orange)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Object Lock non supporté")
                    .fontWeight(.bold)
                Text("Ce seau n'a pas le verrouillage d'objets activé.")
                    .font(.caption)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        )
    }

    private var datePickerSection: some View {
        DatePicker("", selection: $expirationDate, in: Date()..., displayedComponents: .date)
            .labelsHidden()
            #if os(macOS)
                .datePickerStyle(.stepperField)
            #endif
            .disabled(appState.bucketObjectLockEnabled == false)
    }
}

// MARK: - Helpers

#if os(macOS)
    struct VisualEffectView: NSViewRepresentable {
        let material: NSVisualEffectView.Material
        let blendingMode: NSVisualEffectView.BlendingMode

        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.material = material
            view.blendingMode = blendingMode
            view.state = .active
            return view
        }

        func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
            nsView.material = material
            nsView.blendingMode = blendingMode
        }
    }
#endif

struct SecurityCard<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    var isWarning: Bool = false
    let content: Content

    init(
        title: String, icon: String, color: Color, isWarning: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.color = color
        self.isWarning = isWarning
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.headline)
                Text(title)
                    .font(.headline)
                Spacer()
                if isWarning {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundColor(.red)
                }
            }

            content
        }
        .padding(20)
        #if os(macOS)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        #else
            .background(Color(UIColor.secondarySystemGroupedBackground))
        #endif
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    isWarning ? Color.red.opacity(0.3) : Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(6)
    }
}
