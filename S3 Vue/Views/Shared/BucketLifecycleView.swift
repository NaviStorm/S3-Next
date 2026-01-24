import SwiftUI

struct BucketLifecycleView: View {
    @EnvironmentObject var appState: S3AppState
    @State private var showingAddRule = false
    @State private var newRule = S3LifecycleRule()

    var body: some View {
        ZStack {
            #if os(macOS)
                VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                    .ignoresSafeArea()
            #else
                Color(UIColor.systemGroupedBackground)
                    .ignoresSafeArea()
            #endif

            VStack(spacing: 0) {
                headerSection

                if appState.isLifecycleLoading {
                    Spacer()
                    ProgressView("Chargement des configurations...")
                    Spacer()
                } else if appState.bucketLifecycleRules.isEmpty {
                    emptyStateView
                } else {
                    rulesList
                }
            }
        }
        .sheet(isPresented: $showingAddRule) {
            AddLifecycleRuleView(isPresented: $showingAddRule) { rule in
                appState.addLifecycleRule(rule)
            }
        }
        .onAppear {
            appState.loadLifecycleRules()
        }
    }

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Cycle de Vie S3")
                    .font(.title2)
                    .fontWeight(.bold)
                Text(appState.bucket)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: { showingAddRule = true }) {
                Label("Ajouter une règle", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(Color.primary.opacity(0.03))
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "clock.arrow.2.circlepath")
                .font(.system(size: 64))
                .foregroundColor(.secondary.opacity(0.5))

            Text("Aucune règle de cycle de vie")
                .font(.headline)

            Text(
                "Automatisez l'archivage ou la suppression de vos objets pour économiser des coûts."
            )
            .font(.subheadline)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)

            Button("Créer ma première règle") {
                showingAddRule = true
            }
            .buttonStyle(.bordered)
        }
        .frame(maxHeight: .infinity)
    }

    private var rulesList: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(Array(appState.bucketLifecycleRules.enumerated()), id: \.offset) {
                    index, rule in
                    LifecycleRuleCard(rule: rule) {
                        appState.deleteLifecycleRule(at: index)
                    }
                }
            }
            .padding(24)
        }
    }
}

struct LifecycleRuleCard: View {
    let rule: S3LifecycleRule
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(rule.id)
                        .font(.headline)
                    HStack {
                        Badge(
                            text: rule.status.rawValue,
                            color: rule.status == .enabled ? .green : .secondary)
                        if !rule.prefix.isEmpty {
                            Text("Préfixe: \(rule.prefix)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Tout le bucket")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }

            Divider()

            if !rule.transitions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Transitions", systemImage: "arrow.right.circle")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.blue)

                    ForEach(rule.transitions, id: \.self) { transition in
                        HStack {
                            Text("Vers \(transition.storageClass)")
                            Spacer()
                            Text("Après \(transition.days ?? 0) jours")
                                .foregroundColor(.secondary)
                        }
                        .font(.subheadline)
                    }
                }
            }

            if let expiration = rule.expiration {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Expiration", systemImage: "xmark.bin")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.red)

                    HStack {
                        Text("Suppression définitive")
                        Spacer()
                        Text("Après \(expiration.days ?? 0) jours")
                            .foregroundColor(.secondary)
                    }
                    .font(.subheadline)
                }
            }

            if let abort = rule.abortIncompleteMultipartUploadDays {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Nettoyage Multipart", systemImage: "broom")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.orange)

                    HStack {
                        Text("Supprimer fragment incomplets")
                        Spacer()
                        Text("Après \(abort) jours")
                            .foregroundColor(.secondary)
                    }
                    .font(.subheadline)
                }
            }
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
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

struct AddLifecycleRuleView: View {
    @Binding var isPresented: Bool
    let onAdd: (S3LifecycleRule) -> Void

    @State private var id = ""
    @State private var prefix = ""
    @State private var enableTransition = false
    @State private var transitionDays = 30
    @State private var storageClass = "GLACIER"

    @State private var enableExpiration = false
    @State private var expirationDays = 365

    @State private var enableAbortIncomplete = true
    @State private var abortIncompleteDays = 7

    let storageClasses = [
        "STANDARD_IA", "ONEZONE_IA", "INTELLIGENT_TIERING", "GLACIER", "DEEP_ARCHIVE",
    ]

    var body: some View {
        NavigationStack {
            Form {
                #if os(macOS)
                    VStack(alignment: .leading, spacing: 12) {
                        Section("Général") {
                            TextField("ID de la règle", text: $id)
                            TextField("Préfixe (ex: logs/)", text: $prefix)
                        }

                        Section("Archivage (Transitions)") {
                            Toggle("Activer la transition", isOn: $enableTransition)
                            if enableTransition {
                                Picker("Classe de stockage", selection: $storageClass) {
                                    ForEach(storageClasses, id: \.self) { sc in
                                        Text(sc).tag(sc)
                                    }
                                }
                                HStack {
                                    Text("Après")
                                    TextField("", value: $transitionDays, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 60)
                                    Text("jours")
                                }
                            }
                        }

                        Section("Suppression (Expiration)") {
                            Toggle("Activer l'expiration", isOn: $enableExpiration)
                            if enableExpiration {
                                HStack {
                                    Text("Après")
                                    TextField("", value: $expirationDays, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                    Text("jours")
                                }
                            }
                        }

                        Section("Nettoyage") {
                            Toggle(
                                "Supprimer les transferts incomplets", isOn: $enableAbortIncomplete)
                            if enableAbortIncomplete {
                                HStack {
                                    Text("Après")
                                    TextField("", value: $abortIncompleteDays, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 60)
                                    Text("jours")
                                }
                            }
                        }
                    }
                    .padding()
                #else
                    Section("Général") {
                        TextField("ID de la règle", text: $id)
                        TextField("Préfixe (ex: logs/)", text: $prefix)
                    }

                    Section("Archivage (Transitions)") {
                        Toggle("Activer la transition", isOn: $enableTransition)
                        if enableTransition {
                            Picker("Classe de stockage", selection: $storageClass) {
                                ForEach(storageClasses, id: \.self) { sc in
                                    Text(sc).tag(sc)
                                }
                            }
                            Stepper("\(transitionDays) jours", value: $transitionDays, in: 1...3650)
                        }
                    }

                    Section("Suppression (Expiration)") {
                        Toggle("Activer l'expiration", isOn: $enableExpiration)
                        if enableExpiration {
                            Stepper("\(expirationDays) jours", value: $expirationDays, in: 1...3650)
                        }
                    }

                    Section("Nettoyage") {
                        Toggle("Supprimer les transferts incomplets", isOn: $enableAbortIncomplete)
                        if enableAbortIncomplete {
                            Stepper(
                                "\(abortIncompleteDays) jours", value: $abortIncompleteDays,
                                in: 1...30)
                        }
                    }
                #endif
            }
            .navigationTitle("Nouvelle Règle")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ajouter") {
                        var rule = S3LifecycleRule(
                            id: id.isEmpty ? UUID().uuidString : id, prefix: prefix)
                        if enableTransition {
                            rule.transitions = [
                                S3LifecycleTransition(
                                    days: transitionDays, storageClass: storageClass)
                            ]
                        }
                        if enableExpiration {
                            rule.expiration = S3LifecycleExpiration(days: expirationDays)
                        }
                        rule.abortIncompleteMultipartUploadDays =
                            enableAbortIncomplete ? abortIncompleteDays : nil

                        onAdd(rule)
                        isPresented = false
                    }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 500)
    }
}
