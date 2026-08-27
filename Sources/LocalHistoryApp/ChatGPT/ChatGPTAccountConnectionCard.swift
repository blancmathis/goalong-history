#if os(macOS)
    import SwiftUI

    /// Shared account entry point for Settings and the detailed AI recap page.
    /// Goalong delegates credential handling to Codex and only observes account metadata.
    struct ChatGPTAccountConnectionCard: View {
        @ObservedObject var runtime: ChatGPTRecapRuntime

        var body: some View {
            LHCard {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: connectionSymbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(connectionTint)
                        .frame(width: 42, height: 42)
                        .background(
                            connectionTint.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 5) {
                        Text("AI analysis with ChatGPT")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(connectionTitle)
                            .font(.system(size: 14, weight: .semibold))
                        Text(connectionMessage)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(
                            "No API key is used. Goalong never reads or copies your sign-in tokens; the local Codex runtime stores and refreshes them in Goalong’s isolated private directory."
                        )
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 16)

                    VStack(alignment: .trailing, spacing: 10) {
                        StatusPill(
                            title: connectionPill,
                            symbol: connectionSymbol,
                            tint: connectionTint
                        )
                        accountActions
                    }
                }
            }
        }

        @ViewBuilder private var accountActions: some View {
            switch runtime.connectionState {
            case .codexUnavailable:
                Button("Install Codex") {
                    runtime.openCodexInstallGuide()
                }
                .buttonStyle(.borderedProminent)
            case .connected:
                HStack(spacing: 8) {
                    Button {
                        runtime.refreshAccount()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(runtime.isCheckingAccount)
                    .help("Refresh ChatGPT account status")

                    Button("Disconnect") {
                        runtime.disconnectChatGPT()
                    }
                    .buttonStyle(.bordered)
                }
            case .checking:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking ChatGPT connection")
            default:
                HStack(spacing: 8) {
                    Button {
                        runtime.refreshAccount()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(runtime.isCheckingAccount)
                    .help("Refresh ChatGPT account status")

                    Button(runtime.isConnecting ? "Connecting…" : "Connect ChatGPT") {
                        runtime.connectChatGPT()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(runtime.isConnecting)
                }
            }
        }

        private var connectionTitle: String {
            switch runtime.connectionState {
            case .checking: return "Checking your ChatGPT account"
            case .codexUnavailable: return "ChatGPT sign-in component required"
            case .signedOut: return "Connect your ChatGPT account"
            case .connected(let email, let plan):
                return [email, plan.map { "ChatGPT \($0)" }].compactMap { $0 }.joined(separator: " · ")
            case .unsupportedCredentialMode: return "This Codex login does not use ChatGPT"
            case .failed: return "ChatGPT connection needs attention"
            }
        }

        private var connectionMessage: String {
            switch runtime.connectionState {
            case .checking:
                return "Goalong is checking the account used for AI analysis."
            case .codexUnavailable:
                return "Install the official Codex CLI once so Goalong can open the secure ChatGPT browser sign-in."
            case .signedOut:
                return "Sign in in your browser and use the Codex usage included with your ChatGPT plan—no OpenAI API key or separate API billing."
            case .connected:
                return "Ready to run private, temporary recap agents from the activity you choose to analyze."
            case .unsupportedCredentialMode(let mode):
                return "Codex reports “\(mode)”. Goalong blocks it so an API-billed credential is never used by surprise."
            case .failed(let message):
                return message
            }
        }

        private var connectionPill: String {
            switch runtime.connectionState {
            case .checking: return "Checking"
            case .codexUnavailable: return "Setup needed"
            case .signedOut: return "Not connected"
            case .connected(_, let plan): return plan.map { "ChatGPT \($0)" } ?? "Connected"
            case .unsupportedCredentialMode: return "Blocked"
            case .failed: return "Error"
            }
        }

        private var connectionSymbol: String {
            switch runtime.connectionState {
            case .connected: return "checkmark.seal.fill"
            case .checking: return "arrow.triangle.2.circlepath"
            case .codexUnavailable: return "terminal.fill"
            case .signedOut: return "person.crop.circle.badge.plus"
            case .unsupportedCredentialMode: return "exclamationmark.shield.fill"
            case .failed: return "exclamationmark.triangle.fill"
            }
        }

        private var connectionTint: Color {
            switch runtime.connectionState {
            case .connected: return LHTheme.success
            case .checking: return LHTheme.accent
            case .signedOut, .codexUnavailable: return LHTheme.warning
            case .unsupportedCredentialMode, .failed: return LHTheme.danger
            }
        }
    }
#endif
