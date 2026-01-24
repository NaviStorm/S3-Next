import SwiftUI

struct MentionsLegalesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Mentions Légales")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Group {
                    Text("Édition du logiciel")
                        .font(.headline)
                    Text(
                        "S3 Next est une application développée à titre personnel par Andreu-Ascensio Thierry."
                    )
                }

                Group {
                    Text("Hébergement")
                        .font(.headline)
                    Text(
                        "L'application S3 Next est un logiciel client s'exécutant localement sur l'appareil de l'utilisateur. Aucune donnée n'est hébergée sur des serveurs appartenant à l'éditeur de l'application."
                    )
                }

                Group {
                    Text("Propriété intellectuelle")
                        .font(.headline)
                    Text(
                        "L'application S3 Next, ainsi que ses logos et son design, sont la propriété de leur auteur. Toute reproduction est interdite sans accord préalable."
                    )
                }

                Group {
                    Text("Services tiers")
                        .font(.headline)
                    Text(
                        "Cette application permet de se connecter à des services de stockage tiers (compatibles S3). L'utilisation de ces services est régie par les conditions générales de ces fournisseurs tiers. L'éditeur de S3 Next ne saurait être tenu responsable des interruptions de service ou pertes de données chez ces tiers."
                    )
                }

                Text(
                    "Date de dernière mise à jour : \(Date().formatted(date: .long, time: .omitted))"
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding()
        }
        .navigationTitle("Mentions Légales")
        #if os(macOS)
            .frame(minWidth: 400, minHeight: 500)
        #endif
    }
}

struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Politique de Confidentialité (RGPD)")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Group {
                    Text("Collecte des données")
                        .font(.headline)
                    Text(
                        "S3 Next ne collecte, ne stocke ni ne transmet aucune donnée personnelle vers des serveurs tiers autres que ceux explicitement configurés par l'utilisateur (fournisseur S3)."
                    )
                }

                Group {
                    Text("Sécurité et stockage local")
                        .font(.headline)
                    Text(
                        "Vos identifiants de connexion (Clés d'accès et Clés secrètes) ainsi que vos clés de chiffrement CSE sont stockés de manière sécurisée localement sur votre appareil, dans le Keychain (Trousseau d'accès) d'Apple. Ces données ne sont jamais partagées en clair et ne quittent votre appareil que pour communiquer directement avec votre fournisseur S3 via des protocoles sécurisés (HTTPS)."
                    )
                }

                Group {
                    Text("Transfert de fichiers")
                        .font(.headline)
                    Text(
                        "Le contenu de vos fichiers transite directement entre votre appareil et votre service S3. L'application S3 Next ne dispose d'aucun serveur intermédiaire de transit."
                    )
                }

                Group {
                    Text("Vos droits")
                        .font(.headline)
                    Text(
                        "Conformément au Règlement Général sur la Protection des Données (RGPD), vous disposez d'un droit total sur vos données. Comme celles-ci sont stockées localement sur votre appareil, vous pouvez les consulter, les modifier ou les supprimer à tout moment en désinstallant l'application ou en supprimant vos configurations dans les réglages."
                    )
                }

                Group {
                    Text("Contact")
                        .font(.headline)
                    Text(
                        "Pour toute question concernant la confidentialité, vous pouvez contacter l'auteur via les canaux officiels de Next.ink."
                    )
                }

                Text(
                    "Date de dernière mise à jour : \(Date().formatted(date: .long, time: .omitted))"
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding()
        }
        .navigationTitle("Confidentialité")
        #if os(macOS)
            .frame(minWidth: 400, minHeight: 500)
        #endif
    }
}

struct AboutView: View {
    @Environment(\.dismiss) var dismiss

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        #if os(macOS)
            macOSLayout
                .frame(width: 500, height: 280)
        #else
            iOSLayout
                .navigationTitle("À propos")
                .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    #if os(macOS)
        private var macOSLayout: some View {
            HStack(alignment: .top, spacing: 30) {
                // Icône de l'application à gauche
                AppIconView()
                    .frame(width: 128, height: 128)
                    .shadow(radius: 5)
                    .padding(.top, 10)

                // Contenu à droite
                VStack(alignment: .leading, spacing: 4) {
                    Text("S3 Next")
                        .font(.system(size: 38, weight: .bold))
                        .padding(.bottom, 10)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Version \(appVersion) (Build \(appBuild))")
                            .font(.system(size: 13, weight: .medium))
                        Text("Licence GNU GPL v3")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(.bottom, 15)

                    Link(destination: URL(string: "https://github.com/NaviStorm/S3-Next.git")!) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                            Text("Code source sur GitHub")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Copyright © 2024–2026 Andreu-Ascensio Thierry.")
                        Text("Tous droits réservés.")
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                }
                .padding(.trailing, 20)
            }
            .padding(30)
        }
    #endif

    private var iOSLayout: some View {
        VStack(spacing: 25) {
            AppIconView()
                .frame(width: 128, height: 128)
                .shadow(radius: 10)

            VStack(spacing: 8) {
                Text("S3 Next")
                    .font(.system(size: 34, weight: .bold))

                VStack(spacing: 2) {
                    Text("Version \(appVersion) (Build \(appBuild))")
                    Text("Licence GNU GPL v3")
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
            }

            Link(destination: URL(string: "https://github.com/NaviStorm/S3-Next.git")!) {
                Label(
                    "Code source sur GitHub", systemImage: "chevron.left.forwardslash.chevron.right"
                )
                .font(.headline)
            }
            .buttonStyle(.bordered)

            Spacer()

            VStack(spacing: 4) {
                Text("Copyright © 2024–2026 Andreu-Ascensio Thierry.")
                Text("Tous droits réservés.")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding()
    }
}

struct AppIconView: View {
    var body: some View {
        #if os(macOS)
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
            } else {
                DefaultIcon()
            }
        #else
            DefaultIcon()
        #endif
    }
}

struct DefaultIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.blue, .purple], startPoint: .topLeading,
                        endPoint: .bottomTrailing)
                )

            Image(systemName: "square.stack.3d.up.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(30)
                .foregroundColor(.white)
        }
    }
}
