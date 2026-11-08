import AppKit
import KittyFinderCore
import SwiftUI

/// The window that drops down from the menu bar icon.
struct MenuContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kitty Finder")
                .font(.headline)

            if model.isStarting {
                HStack(alignment: .top, spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting… If macOS asks to use the “Kitty Finder” keychain item, enter your Mac password and choose Always Allow.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let message = model.fatalError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { Task { await model.retryStart() } }
            } else if model.accounts.isEmpty && model.signIn == .idle {
                Text("Add a cloud drive to see it in Finder. Files download only when you open them.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.isOffline && !model.accounts.isEmpty {
                Label("You're offline. Offline folders and files already on this Mac still open; changes upload when you're back.",
                      systemImage: "wifi.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.recoveredEdits > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Kitty Finder found \(model.recoveredEdits) edit\(model.recoveredEdits == 1 ? "" : "s") from an earlier version that never uploaded, and saved a copy in “Recovered Edits”. Nothing on Google Drive was changed.",
                          systemImage: "doc.badge.clock")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Show in Finder") { model.showRecoveredEdits() }
                        Spacer()
                        Button("Dismiss") { model.dismissRecoveredEdits() }
                    }
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            if let release = model.updater.available {
                Button {
                    model.openSettingsHandler?(.updates)
                } label: {
                    Label("Kitty Finder \(release.version) is available", systemImage: "arrow.down.circle.fill")
                }
            }

            ForEach(model.accounts) { account in
                AccountRow(account: account)
            }

            if model.accounts.contains(where: { !$0.offlineFolders.isEmpty }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Offline folders")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    OfflineFolderList(compact: true)
                }
            }

            SignInStatus()

            if model.fatalError == nil && !model.isStarting {
                Button {
                    model.addGoogleAccount()
                } label: {
                    Label("Add Google Drive…", systemImage: "plus")
                }
                .disabled(model.signIn != .idle && !isFailed(model.signIn))
            }

            Divider()

            HStack {
                Button("Settings…") { model.openSettingsHandler?(nil) }
                Spacer()
                // On the next run-loop turn, so quitting can wait for drives to stop
                Button("Quit Kitty Finder") { RunLoop.main.perform { NSApp.terminate(nil) } }
            }
        }
        .buttonStyle(.borderless)
        .padding(14)
        .frame(width: 320)
    }

    private func isFailed(_ state: SignInState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}

struct AccountRow: View {
    @Environment(AppModel.self) private var model
    let account: Account

    var body: some View {
        let controller = model.controller(for: account)
        let state = controller?.state ?? .stopped
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(color(for: state))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(account.email)
                Text(driveStatusText(account: account, state: state, controller: controller))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button {
                model.openInFinder(account)
            } label: {
                Image(systemName: "folder")
            }
            .help("Open in Finder")
            .disabled(state != .mounted)
            Button {
                Task { await model.setEnabled(!account.enabled, for: account) }
            } label: {
                Image(systemName: account.enabled ? "pause.circle" : "play.circle")
            }
            .help(account.enabled ? "Disconnect" : "Connect")
        }
    }

    private func color(for state: MountState) -> Color {
        switch state {
        case .mounted: return .green
        case .starting: return .yellow
        case .failed: return .red
        case .stopped, .paused: return .gray
        }
    }
}

/// One line saying how a drive is doing.
@MainActor
func driveStatusText(account: Account, state: MountState, controller: MountController?) -> String {
    switch state {
    case .starting:
        return "Connecting…"
    case .mounted:
        let pending = controller?.pendingUploads ?? 0
        let local = ByteFormat.string(controller?.stats?.bytesUsed ?? 0)
        if pending > 0 { return "Uploading \(pending) file\(pending == 1 ? "" : "s")… · \(local) on this Mac" }
        return "Up to date · \(local) on this Mac"
    case .paused:
        return "Ejected. Click ▶︎ to reconnect."
    case .stopped:
        return account.enabled ? "Not connected" : "Disconnected"
    case .failed(let message):
        return message
    }
}

struct SignInStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.signIn {
        case .idle:
            EmptyView()
        case .waitingForBrowser(let url):
            VStack(alignment: .leading, spacing: 6) {
                Label("Finish signing in to Google in your browser.", systemImage: "globe")
                HStack {
                    if let url {
                        Link("Open sign-in page", destination: url)
                    }
                    Spacer()
                    Button("Cancel") { model.cancelSignIn() }
                }
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        case .finishing:
            HStack {
                ProgressView().controlSize(.small)
                Text("Connecting your Drive…")
            }
        case .failed(let message):
            HStack(alignment: .top) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Dismiss") { model.signIn = .idle }
            }
        }
    }
}
