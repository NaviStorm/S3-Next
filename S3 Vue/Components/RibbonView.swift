#if os(macOS)
    import SwiftUI

    struct RibbonView: View {
        @EnvironmentObject var appState: S3AppState
        @State private var selectedTab: Int = 0
        @Namespace private var animation

        // Callbacks pour les actions
        var onUploadFile: () -> Void
        var onUploadFolder: () -> Void
        var onCreateFolder: () -> Void
        var onRefresh: () -> Void
        var onNavigateHome: () -> Void
        var onNavigateBack: () -> Void
        var onDownload: () -> Void
        var onPreview: () -> Void
        var onRename: () -> Void
        var onDelete: () -> Void
        var onShowTimeMachine: () -> Void
        var onShowHistory: () -> Void
        var onShowLifecycle: () -> Void

        var body: some View {
            VStack(spacing: 0) {
                // Header des onglets avec animation de glissement
                HStack(spacing: 20) {
                    RibbonTabHeader(
                        title: "ACCUEIL", isSelected: selectedTab == 0, namespace: animation
                    ) { withAnimation(.spring(response: 0.3)) { selectedTab = 0 } }
                    RibbonTabHeader(
                        title: "TRANSFERTS & GESTION", isSelected: selectedTab == 1,
                        namespace: animation
                    ) { withAnimation(.spring(response: 0.3)) { selectedTab = 1 } }
                    RibbonTabHeader(
                        title: "SEAU (BUCKET)", isSelected: selectedTab == 2, namespace: animation
                    ) { withAnimation(.spring(response: 0.3)) { selectedTab = 2 } }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .background(Color(NSColor.windowBackgroundColor))

                // Corps du ruban avec fond légèrement vitré (vibrant)
                ZStack {
                    VisualEffectView(material: .headerView, blendingMode: .withinWindow)
                        .shadow(color: Color.black.opacity(0.1), radius: 0.5, y: 1)

                    HStack(alignment: .top, spacing: 0) {
                        Group {
                            if selectedTab == 0 {
                                // Onglet ACCUEIL
                                HStack(alignment: .top, spacing: 15) {
                                    RibbonGroup(label: "Navigation") {
                                        RibbonButton(
                                            title: "Racine", icon: "house.fill",
                                            action: onNavigateHome)
                                        RibbonButton(
                                            title: "Retour", icon: "arrow.left.circle.fill",
                                            action: onNavigateBack,
                                            disabled: appState.currentPath.isEmpty)
                                        RibbonButton(
                                            title: "Actualiser",
                                            icon: "arrow.clockwise.circle.fill",
                                            action: onRefresh)
                                    }

                                    RibbonGroup(label: "Affichage") {
                                        Menu {
                                            Picker("Trier par", selection: $appState.sortOption) {
                                                ForEach(S3AppState.SortOption.allCases) { option in
                                                    Text(
                                                        option == .name
                                                            ? "Nom"
                                                            : (option == .date ? "Date" : "Taille")
                                                    ).tag(option)
                                                }
                                            }
                                            Divider()
                                            Toggle("Ordre croissant", isOn: $appState.sortAscending)
                                        } label: {
                                            VStack(spacing: 4) {
                                                Image(
                                                    systemName:
                                                        "line.3.horizontal.decrease.circle.fill"
                                                )
                                                .font(.system(size: 20))
                                                .foregroundStyle(
                                                    .linearGradient(
                                                        colors: [.blue, .purple], startPoint: .top,
                                                        endPoint: .bottom))
                                                Text("Trier")
                                                    .font(.system(size: 11))
                                            }
                                            .frame(width: 50)
                                            .contentShape(Rectangle())
                                        }
                                        .menuStyle(.borderlessButton)
                                    }
                                }
                                .transition(
                                    .asymmetric(
                                        insertion: .move(edge: .leading).combined(with: .opacity),
                                        removal: .move(edge: .trailing).combined(with: .opacity)))
                            } else if selectedTab == 1 {
                                // Onglet FUSIONNÉ : TRANSFERTS & GESTION
                                HStack(alignment: .top, spacing: 15) {
                                    RibbonGroup(label: "Transferts") {
                                        RibbonButton(
                                            title: "Fichiers", icon: "doc.badge.plus", color: .blue,
                                            action: onUploadFile)
                                        RibbonButton(
                                            title: "Dossier", icon: "folder.badge.plus",
                                            color: .blue,
                                            action: onUploadFolder)
                                        RibbonButton(
                                            title: "Télécharger", icon: "arrow.down.doc.fill",
                                            color: .green, action: onDownload)
                                    }

                                    RibbonGroup(label: "Chiffrement") {
                                        Menu {
                                            Button(action: {
                                                appState.selectedEncryptionAlias = nil
                                            }) {
                                                HStack {
                                                    if appState.selectedEncryptionAlias == nil {
                                                        Image(systemName: "checkmark")
                                                    }
                                                    Text("Sans chiffrement")
                                                }
                                            }
                                            Divider()
                                            ForEach(appState.encryptionAliases, id: \.self) {
                                                alias in
                                                Button(action: {
                                                    appState.selectedEncryptionAlias = alias
                                                }) {
                                                    HStack {
                                                        if appState.selectedEncryptionAlias == alias
                                                        {
                                                            Image(systemName: "checkmark")
                                                        }
                                                        Text(alias)
                                                    }
                                                }
                                            }
                                        } label: {
                                            VStack(spacing: 4) {
                                                ZStack(alignment: .bottomTrailing) {
                                                    Image(systemName: "key.horizontal.fill")
                                                        .font(.system(size: 20))
                                                        .foregroundStyle(
                                                            .linearGradient(
                                                                colors: [.orange, .yellow],
                                                                startPoint: .top, endPoint: .bottom)
                                                        )
                                                    if appState.selectedEncryptionAlias != nil {
                                                        Image(systemName: "lock.fill")
                                                            .font(.system(size: 9))
                                                            .foregroundColor(.green)
                                                            .background(
                                                                Circle().fill(Color.white).frame(
                                                                    width: 12, height: 12)
                                                            )
                                                            .offset(x: 4, y: 4)
                                                    }
                                                }
                                                Text(
                                                    appState.selectedEncryptionAlias ?? "Clé active"
                                                )
                                                .font(.system(size: 11))
                                                .lineLimit(1)
                                            }
                                            .frame(width: 70)
                                        }
                                        .menuStyle(.borderlessButton)
                                    }

                                    RibbonGroup(label: "Gestion Objets") {
                                        RibbonButton(
                                            title: "Nouveau", icon: "plus.rectangle.on.folder.fill",
                                            color: .blue, action: onCreateFolder)
                                        RibbonButton(
                                            title: "Renommer", icon: "pencil.circle.fill",
                                            action: onRename)
                                        RibbonButton(
                                            title: "Aperçu", icon: "eye.fill", action: onPreview)
                                        RibbonButton(
                                            title: "Supprimer", icon: "trash.fill", color: .red,
                                            action: onDelete)
                                    }
                                }
                                .transition(.opacity)
                            } else if selectedTab == 2 {
                                // Onglet BUCKET
                                HStack(alignment: .top, spacing: 15) {
                                    RibbonGroup(label: "Versioning") {
                                        VStack(spacing: 6) {
                                            Toggle(
                                                "",
                                                isOn: Binding(
                                                    get: { appState.isVersioningEnabled ?? false },
                                                    set: { _ in appState.toggleVersioning() }
                                                )
                                            )
                                            .toggleStyle(.switch)
                                            .controlSize(.small)
                                            .disabled(appState.isVersioningEnabled == nil)

                                            Text(
                                                appState.isVersioningEnabled == true
                                                    ? "Activé" : "Désactivé"
                                            )
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                        }
                                        .frame(width: 60)
                                    }

                                    RibbonGroup(label: "Configuration") {
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack {
                                                Image(systemName: "archivebox.fill")
                                                    .foregroundColor(
                                                        .secondary)
                                                Text(appState.bucket).fontWeight(.bold)
                                            }
                                            .font(.system(size: 11))

                                            HStack {
                                                Image(systemName: "globe.europe.africa.fill")
                                                    .foregroundColor(.secondary)
                                                Text(appState.region)
                                            }
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                        }
                                        .padding(.horizontal, 4)
                                    }

                                    RibbonGroup(label: "Time Machine") {
                                        RibbonButton(
                                            title: "Historique", icon: "clock.arrow.circlepath",
                                            color: .purple, action: onShowTimeMachine)
                                        RibbonButton(
                                            title: "Activités", icon: "calendar.badge.clock",
                                            color: .blue, action: onShowHistory)
                                    }

                                    RibbonGroup(label: "Automatisation") {
                                        RibbonButton(
                                            title: "Cycle de Vie", icon: "clock.arrow.2.circlepath",
                                            color: .orange, action: onShowLifecycle)
                                    }
                                }
                                .transition(
                                    .asymmetric(
                                        insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }
                .frame(height: 95)

                Divider()
            }
            .frame(height: 125)
        }
    }

    // MARK: - Subviews

    struct RibbonTabHeader: View {
        let title: String
        let isSelected: Bool
        var namespace: Namespace.ID
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                VStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(isSelected ? .primary : .secondary)
                        .characterSpacing(0.5)

                    if isSelected {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.accentColor)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "activeTab", in: namespace)
                    } else {
                        Rectangle()
                            .fill(Color.clear)
                            .frame(height: 2)
                    }
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
    }

    struct RibbonGroup: View {
        let label: String
        let content: () -> AnyView

        init<Content: View>(label: String, @ViewBuilder content: @escaping () -> Content) {
            self.label = label
            self.content = { AnyView(content()) }
        }

        var body: some View {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    content()
                }
                .frame(minHeight: 45)

                Text(label.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.8))
                    .characterSpacing(0.2)
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 2)
            .overlay(
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, .secondary.opacity(0.2), .clear], startPoint: .top,
                            endPoint: .bottom)
                    )
                    .frame(width: 1)
                    .padding(.vertical, 8),
                alignment: .trailing
            )
        }
    }

    struct RibbonButton: View {
        let title: String
        let icon: String
        var color: Color = .primary
        var action: () -> Void
        var disabled: Bool = false
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                VStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundStyle(
                            disabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(color)
                        )
                        .scaleEffect(isHovered ? 1.1 : 1.0)

                    Text(title)
                        .font(.system(size: 11))
                        .foregroundColor(disabled ? .secondary : .primary)
                }
                .frame(minWidth: 55)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.2)) {
                    isHovered = hovering && !disabled
                }
            }
        }
    }

    // MARK: - AppState Extension
    extension View {
        func characterSpacing(_ spacing: CGFloat) -> some View {
            self.kerning(spacing)
        }
    }
#endif
