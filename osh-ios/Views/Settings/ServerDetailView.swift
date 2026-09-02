import SwiftUI

// MARK: - ServerDetailView
//
// Used for both creating a new server config and editing an existing one.
// Title is "New Server" when creating, the server label when editing.

struct ServerDetailView: View {
    @EnvironmentObject var settings: AppSettingsStore
    @Environment(\.dismiss) private var dismiss

    // Non-nil when editing an existing config
    let existingConfig: ServerConfig?

    // MARK: - Form state

    @State private var label: String
    @State private var description: String
    @State private var url: String
    @State private var username: String
    @State private var password: String
    @State private var allowSelfSigned: Bool

    // MARK: - Validation errors

    @State private var labelError: String?
    @State private var urlError: String?

    // MARK: - Connection test

    @State private var testResult: TestResult = .none

    private enum TestResult: Equatable {
        case none, testing, connected, authFailed, unreachable(String)
    }

    // MARK: - Init

    init(existingConfig: ServerConfig? = nil) {
        self.existingConfig = existingConfig
        _label       = State(initialValue: existingConfig?.label       ?? "")
        _description = State(initialValue: existingConfig?.description ?? "")
        _url         = State(initialValue: existingConfig?.url         ?? "")
        _username    = State(initialValue: existingConfig?.username    ?? "")
        _password    = State(initialValue: existingConfig?.password    ?? "")
        _allowSelfSigned = State(
            initialValue: existingConfig?.allowSelfSignedCertificates ?? false)
    }

    // MARK: - Body

    var body: some View {
        Form {
            detailsSection
            connectionSection
            testSection
        }
        .navigationTitle(existingConfig == nil ? "New Server" : (existingConfig!.label))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
            }
        }
    }

    // MARK: - Sections

    private var detailsSection: some View {
        Section("Details") {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Label", text: $label)
                    .autocorrectionDisabled()
                    .onChange(of: label) { _, _ in labelError = nil }
                if let err = labelError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            TextField("Description (optional)", text: $description)
                .autocorrectionDisabled()
        }
    }

    private var connectionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                TextField("http://url:port/sensorhub/api", text: $url)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: url) { _, _ in urlError = nil }
                if let err = urlError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            TextField("Username (optional)", text: $username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            SecureField("Password (optional)", text: $password)

            // Shown for every server rather than only https:// ones: the URL
            // field is still being typed while this section is on screen, and
            // a toggle that appeared and vanished mid-edit would be worse than
            // one that is simply irrelevant to an http:// node.
            Toggle("Trust server certificate (self-signed)", isOn: $allowSelfSigned)
        } header: {
            Text("Connection")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                // Not every node wants credentials, and sending empty ones is worse
                // than sending none: a node with anonymous read enabled answers 401
                // to an empty Basic user it would have served without a header.
                Text("Leave the username blank for a node that allows anonymous access.")
                Text("Turn on certificate trust only for an https:// node you run yourself — it accepts a certificate that does not chain to a trusted root, for this server's host only.")
            }
        }
    }

    private var testSection: some View {
        Section {
            Button {
                Task { await runConnectionTest() }
            } label: {
                HStack {
                    if testResult == .testing {
                        ProgressView().tint(.white)
                            .padding(.trailing, 4)
                    }
                    Text("Test Connection")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(testResult == .testing)

            switch testResult {
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .authFailed:
                Label("Authentication failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case .unreachable(let msg):
                // The message is the point — it names ATS, an untrusted
                // certificate or a redirect and what to do about it, none of
                // which fits in a .help() tooltip on a touch device.
                VStack(alignment: .leading, spacing: 2) {
                    Label("Could not reach server", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .none, .testing:
                EmptyView()
            }
        }
    }

    // MARK: - Actions

    private func runConnectionTest() async {
        testResult = .testing
        do {
            let client = try ConnectedSystemsClient(
                nodeURL: url,
                username: username,
                password: password,
                allowSelfSignedCertificates: allowSelfSigned
            )
            let result = await client.testConnectivity()
            switch result {
            case .connected:          testResult = .connected
            case .authenticationFailed: testResult = .authFailed
            case .unreachable(let m): testResult = .unreachable(m)
            }
        } catch {
            testResult = .unreachable(error.localizedDescription)
        }
        // Auto-clear result after 4 seconds
        try? await Task.sleep(for: .seconds(4))
        if testResult != .testing {
            testResult = .none
        }
    }

    private func save() {
        guard validate() else { return }
        let config = ServerConfig(
            id:          existingConfig?.id ?? UUID(),
            label:       label.trimmingCharacters(in: .whitespaces),
            description: description.trimmingCharacters(in: .whitespaces),
            url:         url.trimmingCharacters(in: .whitespaces),
            username:    username.trimmingCharacters(in: .whitespaces),
            password:    password,
            allowSelfSignedCertificates: allowSelfSigned
        )
        settings.saveServer(config)
        dismiss()
    }

    @discardableResult
    private func validate() -> Bool {
        var valid = true
        let trimLabel = label.trimmingCharacters(in: .whitespaces)
        let trimURL   = url.trimmingCharacters(in: .whitespaces)

        if trimLabel.isEmpty {
            labelError = "Label is required"
            valid = false
        }
        if trimURL.isEmpty {
            urlError = "URL is required"
            valid = false
        } else if !trimURL.hasPrefix("http://") && !trimURL.hasPrefix("https://") {
            urlError = "URL must start with http:// or https://"
            valid = false
        }
        return valid
    }
}

#Preview {
    NavigationStack {
        ServerDetailView()
    }
    .environmentObject(AppSettingsStore())
}
