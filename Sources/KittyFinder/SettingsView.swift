import AppKit
import KittyFinderCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AccountsSettings()
                .tabItem { Label("Accounts", systemImage: "person.2") }
            GoogleSettings()
                .tabItem { Label("Google", systemImage: "key") }
        }
        .frame(width: 480)
        .padding(20)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var limit = 10
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section {
                Stepper(value: $limit, in: AppSettings.cacheLimitRange) {
                    Text("Keep up to **\(limit) GB** of downloaded files on this Mac")
                }
                Text("Files you open are kept on this Mac so they open fast next time. When this limit is reached, the files you haven't used for longest are removed from this Mac. They stay in the cloud.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Apply") { Task { await model.update { $0.cacheLimitGB = limit } } }
                        .disabled(limit == model.settings.cacheLimitGB)
                }
            }
            Section {
                Toggle("Open Kitty Finder when you log in", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in model.launchAtLogin = value }
                LabeledContent("Drives folder") {
                    Button(model.paths.mountRoot.path) { NSWorkspace.shared.open(model.paths.mountRoot) }
                        .buttonStyle(.link)
                }
                LabeledContent("Logs") {
                    Button("Show in Finder") { model.openLogs() }
                        .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            limit = model.settings.cacheLimitGB
            launchAtLogin = model.launchAtLogin
        }
    }
}

struct AccountsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var message: String?
    @State private var confirmRemove: Account?

    var body: some View {
        Form {
            if model.accounts.isEmpty {
                Text("No drives yet. Use “Add Google Drive…” in the menu bar.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.accounts) { account in
                Section(account.title) {
                    LabeledContent("On this Mac", value: ByteFormat.string(model.localCopyBytes(account)))
                    HStack {
                        Button("Free Up Space") {
                            Task {
                                let cleared = await model.clearLocalCopies(account)
                                message = cleared
                                    ? "Removed downloaded copies for \(account.email). Everything is still in the cloud."
                                    : "\(account.email) still has changes uploading. Try again when it says “Up to date”."
                            }
                        }
                        Spacer()
                        Button("Remove…", role: .destructive) { confirmRemove = account }
                    }
                }
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove \(confirmRemove?.email ?? "")?", isPresented: .init(
            get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }
        ), presenting: confirmRemove) { account in
            Button("Remove", role: .destructive) {
                Task {
                    if await model.remove(account) {
                        message = "Removed \(account.email). Your files are still in Google Drive."
                    } else {
                        message = "\(account.email) still has changes uploading, so it wasn't removed. Try again when it says “Up to date”."
                    }
                }
            }
        } message: { _ in
            Text("The drive disappears from Finder and its downloaded copies are deleted from this Mac. Nothing is deleted from Google Drive.")
        }
    }
}

struct GoogleSettings: View {
    @Environment(AppModel.self) private var model
    @State private var clientID = ""
    @State private var clientSecret = ""

    var body: some View {
        Form {
            Section {
                if model.googleClient != nil && model.settings.googleClientID.isEmpty {
                    Label("This copy of Kitty Finder has a Google sign-in client built in.", systemImage: "checkmark.seal")
                }
                TextField("Client ID", text: $clientID)
                SecureField("Client secret", text: $clientSecret)
                HStack {
                    Link("How to create one", destination: URL(string: "https://rclone.org/drive/#making-your-own-client-id")!)
                    Spacer()
                    Button("Save") {
                        Task {
                            await model.update {
                                $0.googleClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
                                $0.googleClientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                    }
                }
            } header: {
                Text("Google sign-in client")
            } footer: {
                Text("Google requires each app to have its own sign-in client. Create a “Desktop app” OAuth client in Google Cloud Console and paste it here. Leave empty to use the one built into the app.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            clientID = model.settings.googleClientID
            clientSecret = model.settings.googleClientSecret
        }
    }
}
