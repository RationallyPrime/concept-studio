import SwiftUI

struct HuggingFaceAccountView: View {
    @Bindable var session: StudioSession
    var showsManualToken = false
    @State private var manualToken = ""

    private var connection: HuggingFaceConnection {
        session.huggingFace
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Hugging Face", value: status)
            HStack(spacing: 12) {
                Button("Sign in with Hugging Face") {
                    Task { await session.connectHuggingFace() }
                }
                .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                .disabled(session.demoMode || session.busy || connection.isBusy)
                .help("Connect in your browser to publish datasets and models and download models you have access to.")
                if connection.isBusy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { connection.cancel() }
                } else if connection.status.source != .none || connection.errorMessage != nil {
                    Button("Disconnect on this Mac") {
                        Task { await session.disconnectHuggingFace() }
                    }
                    .disabled(session.demoMode || session.busy)
                    .help("Removes saved Hugging Face credentials from this Mac. Manage remote access on Hugging Face.")
                }
            }
            Text("Publish datasets and LoRAs to your account, and download gated models you have access to. "
                + "Your connection stays in this Mac’s Keychain.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
            if let error = connection.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
            } else if !connection.message.isEmpty {
                Text(connection.message).font(.callout).foregroundStyle(StudioStyle.supportingText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsManualToken {
                Link("Manage connected apps", destination: HuggingFaceAuthorization.applicationsURL)
                if session.advancedUser {
                    DisclosureGroup("Advanced: paste a Hugging Face token") {
                        manualTokenControls.padding(.top, 12)
                    }
                } else if connection.status.source == .manual {
                    Text("A manually supplied token is active. Turn on Advanced user to replace it.")
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                }
            }
        }
        .task(id: session.demoMode) { await session.loadHuggingFace() }
        .onChange(of: session.demoMode) { _, _ in
            manualToken = ""
            connection.cancel()
        }
        .onDisappear { manualToken = ""; connection.cancel() }
    }

    private var status: String {
        if session.demoMode { return "Offline demo" }
        if connection.isBusy { return "Connecting…" }
        if connection.status.needsSignIn { return "Sign in again to continue" }
        if let username = connection.username { return "Connected as \(username)" }
        return connection.isConnected ? "Token saved in Keychain" : "Not connected"
    }

    private var manualTokenControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            SecureField("Hugging Face write token", text: $manualToken, prompt: Text("Paste write token"))
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                Button("Save and use token") {
                    let value = manualToken
                    Task { if await session.saveHuggingFaceToken(value) { manualToken = "" } }
                }
                .disabled(session.demoMode || session.busy || connection.isBusy
                    || manualToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Link("Token settings", destination: URL(string: "https://huggingface.co/settings/tokens")!)
            }
            Text("Checks the token and switches this connection to it. Use a write token with access to your "
                + "publishing destinations and gated models.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
