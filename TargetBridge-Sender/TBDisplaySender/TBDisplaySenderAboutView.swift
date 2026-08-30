import SwiftUI

struct TBDisplaySenderAboutView: View {
    @ObservedObject var service: TBDisplaySenderService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SurfaceCard {
                HStack(alignment: .top, spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.green.opacity(0.30),
                                        Color.cyan.opacity(0.16)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: "display.2")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.95))
                    }
                    .frame(width: 74, height: 74)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(TBDisplaySenderL10n.appName(service.language))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text(aboutSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        versionChip
                    }

                    Spacer()

                    Button(closeTitle) {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
            }

            SurfaceCard {
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeading(projectTitle)
                    Text(projectDescription)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Link(destination: URL(string: "https://github.com/vikiboy/imac-5k-display-appliance")!) {
                            Label(githubTitle, systemImage: "link")
                        }
                        .buttonStyle(.borderedProminent)

                        Link(destination: URL(string: "https://github.com/swellweb/targetBridge")!) {
                            Label(upstreamTitle, systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            SurfaceCard {
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeading(creditsTitle)
                    Text(creditsBody)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 420)
        .background(appBackground)
        // Fixed dark background → force dark scheme so semantic text colors stay
        // light and don't render dark-on-dark in system Light mode.
        .preferredColorScheme(.dark)
    }

    private var versionChip: some View {
        Text("\(versionTitle) \(TBDisplaySenderBuildInfo.versionDisplay)")
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(.caption, design: .rounded, weight: .bold))
            .tracking(1.0)
            .foregroundStyle(.secondary)
    }

    private var appBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.12, green: 0.13, blue: 0.14),
                Color(red: 0.08, green: 0.09, blue: 0.10)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var aboutSubtitle: String {
        switch service.language {
        case .italian: return "Un display Retina 5K personale per iMac 2017, costruito sul progetto open source TargetBridge."
        case .english: return "A personal 2017-iMac Retina 5K display appliance built on the open-source TargetBridge foundation."
        case .german: return "Eine persönliche Retina-5K-Display-Lösung für den iMac 2017 auf Basis des Open-Source-Projekts TargetBridge."
        case .french: return "Un écran Retina 5K personnel pour iMac 2017, construit sur la base open source de TargetBridge."
        case .chinese: return "基于开源 TargetBridge 构建的个人 2017 款 iMac Retina 5K 显示方案。"
        }
    }

    private var projectTitle: String {
        switch service.language {
        case .italian: return "Progetto"
        case .english: return "Project"
        case .german: return "Projekt"
        case .french: return "Projet"
        case .chinese: return "项目"
        }
    }

    private var projectDescription: String {
        switch service.language {
        case .italian: return "Questa variante indipendente cattura un vero display Retina esteso 2×, invia frame 4:4:4 lossless tramite Thunderbolt Bridge e li presenta sull’iMac con Metal."
        case .english: return "This independent derivative captures a true 2× Retina extended display, sends lossless 4:4:4 frames over Thunderbolt Bridge, and presents them on the iMac with Metal."
        case .german: return "Diese unabhängige Ableitung erfasst ein echtes erweitertes 2×-Retina-Display, sendet verlustfreie 4:4:4-Frames über Thunderbolt Bridge und zeigt sie per Metal auf dem iMac an."
        case .french: return "Cette variante indépendante capture un véritable écran Retina étendu 2×, envoie des images 4:4:4 sans perte via Thunderbolt Bridge et les affiche sur l’iMac avec Metal."
        case .chinese: return "这个独立衍生项目捕获真实的 2× Retina 扩展显示器，通过 Thunderbolt Bridge 传输无损 4:4:4 帧，并使用 Metal 在 iMac 上呈现。"
        }
    }

    private var creditsTitle: String {
        switch service.language {
        case .italian: return "Crediti"
        case .english: return "Credits"
        case .german: return "Mitwirkende"
        case .french: return "Crédits"
        case .chinese: return "致谢"
        }
    }

    private var creditsBody: String {
        switch service.language {
        case .italian: return "Progetto personale di Vikram Mohanty, basato su TargetBridge di Marco Caciotti. Il codec TBD2 deriva dal lavoro di Aykut Alpgiray Ates (PR #158); il percorso Metal deriva dal lavoro di Betafer (PR #174). Licenza e crediti completi sono nel file NOTICE."
        case .english: return "Personal project by Vikram Mohanty, built on TargetBridge by Marco Caciotti. TBD2 comes from Aykut Alpgiray Ates's PR #158; the native-Metal path comes from Betafer's PR #174. Full license and credits are in NOTICE."
        case .german: return "Persönliches Projekt von Vikram Mohanty auf Basis von TargetBridge von Marco Caciotti. TBD2 stammt aus PR #158 von Aykut Alpgiray Ates; der native Metal-Pfad aus PR #174 von Betafer. Vollständige Lizenz- und Urheberhinweise stehen in NOTICE."
        case .french: return "Projet personnel de Vikram Mohanty, basé sur TargetBridge de Marco Caciotti. TBD2 provient de la PR #158 d’Aykut Alpgiray Ates ; le chemin Metal natif de la PR #174 de Betafer. Licence et crédits complets figurent dans NOTICE."
        case .chinese: return "Vikram Mohanty 的个人项目，基于 Marco Caciotti 的 TargetBridge。TBD2 来自 Aykut Alpgiray Ates 的 PR #158；原生 Metal 路径来自 Betafer 的 PR #174。完整许可和致谢见 NOTICE。"
        }
    }

    private var githubTitle: String {
        switch service.language {
        case .italian: return "Repository del progetto"
        case .english: return "Project repository"
        case .german: return "Projekt-Repository"
        case .french: return "Dépôt du projet"
        case .chinese: return "项目仓库"
        }
    }

    private var upstreamTitle: String {
        switch service.language {
        case .italian: return "TargetBridge originale"
        case .english: return "Upstream TargetBridge"
        case .german: return "Ursprüngliches TargetBridge"
        case .french: return "TargetBridge d’origine"
        case .chinese: return "上游 TargetBridge"
        }
    }

    private var versionTitle: String {
        switch service.language {
        case .italian: return "Versione"
        case .english: return "Version"
        case .german: return "Version"
        case .french: return "Version"
        case .chinese: return "版本"
        }
    }

    private var closeTitle: String {
        switch service.language {
        case .italian: return "Chiudi"
        case .english: return "Close"
        case .german: return "Schließen"
        case .french: return "Fermer"
        case .chinese: return "关闭"
        }
    }
}
