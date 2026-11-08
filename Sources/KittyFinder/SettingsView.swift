import AppKit
import KittyFinderCore
import SwiftUI

enum SettingsTab: Int, CaseIterable {
    case general, drives, storage, sync, google, updates, about

    var title: String {
        switch self {
        case .general: return "General"
        case .drives: return "Drives"
        case .storage: return "Storage"
        case .sync: return "Sync"
        case .google: return "Google"
        case .updates: return "Updates"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .drives: return "externaldrive.connected.to.line.below"
        case .storage: return "internaldrive"
        case .sync: return "arrow.triangle.2.circlepath"
        case .google: return "key"
        case .updates: return "arrow.down.circle"
        case .about: return "info.circle"
        }
    }

    @MainActor @ViewBuilder var page: some View {
        switch self {
        case .general: GeneralSettings()
        case .drives: DrivesSettings()
        case .storage: StorageSettings()
        case .sync: SyncSettings()
        case .google: GoogleSettings()
        case .updates: UpdatesSettings()
        case .about: AboutSettings()
        }
    }
}

/// The Settings window: one toolbar tab per page, like macOS's own apps.
@MainActor
final class SettingsWindowController {
    static let size = NSSize(width: 640, height: 560)
    let window: NSWindow
    private let tabs = NSTabViewController()

    init(model: AppModel) {
        tabs.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let host = NSHostingController(rootView: tab.page.environment(model))
            host.sizingOptions = []
            host.preferredContentSize = Self.size
            host.title = tab.title
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .preference
        window.contentMinSize = NSSize(width: 560, height: 440)
        window.setContentSize(Self.size)
        window.isReleasedWhenClosed = false
        window.center()
    }

    func select(_ tab: SettingsTab) {
        tabs.selectedTabViewItemIndex = tab.rawValue
    }
}

extension AppModel {
    /// A binding to one setting; changes are saved (and applied) as they're made.
    func binding<T>(_ key: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: key] },
                set: { value in Task { await self.update { $0[keyPath: key] = value } } })
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Message: View {
    let text: String
    var isError = false

    var body: some View {
        Label(text, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
            .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: General

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = false
    @State private var notificationsDenied = false

    var body: some View {
        Form {
            Section {
                Toggle("Open Kitty Finder when you log in", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in model.launchAtLogin = value }
                Toggle("Show the Kitty Finder window when it opens", isOn: model.binding(\.showWindowAtLaunch))
            }
            Section("Menu bar") {
                LabeledContent("Icon") {
                    HStack(spacing: 10) {
                        ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
                            IconChoice(style: style, selected: model.settings.menuBarIcon == style) {
                                Task { await model.update { $0.menuBarIcon = style } }
                            }
                        }
                    }
                }
                Toggle("Show how many files are uploading (↑3)", isOn: model.binding(\.showUploadCount))
            }
            Section {
                Toggle("A drive stops working or files can't upload", isOn: notify(\.notifyUploadProblems))
                Toggle("An offline folder finishes downloading", isOn: notify(\.notifyOfflineReady))
                Toggle("A new version of Kitty Finder is out", isOn: notify(\.notifyUpdates))
                if notificationsDenied {
                    HStack {
                        Caption("Notifications for Kitty Finder are turned off in System Settings.")
                        Spacer()
                        Button("Open System Settings") { Notifier.openSystemSettings() }
                    }
                }
            } header: {
                Text("Notify me when")
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = model.launchAtLogin }
        .task { notificationsDenied = await Notifier.isDenied() }
    }

    /// Turning a notification on asks macOS for permission first.
    private func notify(_ key: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: key] }, set: { on in
            Task {
                if on, !(await Notifier.requestPermission()) {
                    notificationsDenied = true
                    return
                }
                notificationsDenied = false
                await model.update { $0[keyPath: key] = on }
            }
        })
    }
}

private struct IconChoice: View {
    let style: MenuBarIconStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(nsImage: KittyGlyph.image(style))
                    .frame(width: 44, height: 30)
                    .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                Text(style.label)
                    .font(.caption)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Drives

struct DrivesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var folderMessage: String?
    @State private var movingFolder = false

    var body: some View {
        Form {
            if model.accounts.isEmpty {
                Section {
                    Text("No drives yet.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.accounts) { account in
                DriveSection(account: account)
            }
            Section {
                Button {
                    model.addGoogleAccount()
                } label: {
                    Label("Add Google Drive…", systemImage: "plus")
                }
                .disabled(model.signIn != .idle)
                SignInStatus()
            }
            Section {
                Toggle("Show Google Docs, Sheets and Slides", isOn: model.binding(\.showGoogleDocs))
            } footer: {
                Caption("They appear as links that open in your browser, so you can also move and delete them in Finder. Drives reconnect when you change this.")
            }
            Section {
                LabeledContent("Location") {
                    Text((model.paths.mountRoot.path as NSString).abbreviatingWithTildeInPath)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.open(model.paths.mountRoot) }
                    Spacer()
                    if movingFolder { ProgressView().controlSize(.small) }
                    Button("Use Default") { move(to: nil) }
                        .disabled(model.settings.drivesFolder == nil || movingFolder)
                    Button("Choose…") { chooseFolder() }
                        .disabled(movingFolder)
                }
                if let folderMessage { Message(text: folderMessage, isError: true) }
            } header: {
                Text("Drives folder")
            } footer: {
                Caption("Each drive appears as a folder here. Folders that iCloud or another cloud app syncs, such as Desktop and Documents with iCloud turned on, can't be used: they would copy your whole drive back onto this Mac.")
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose where your drives appear."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        move(to: url)
    }

    private func move(to folder: URL?) {
        movingFolder = true
        folderMessage = nil
        Task {
            folderMessage = await model.moveDrivesFolder(to: folder)
            movingFolder = false
        }
    }
}

private struct DriveSection: View {
    @Environment(AppModel.self) private var model
    let account: Account
    @State private var name = ""
    @State private var message: (text: String, isError: Bool)?
    @State private var confirmRemove = false
    @State private var confirmForceRemove = false
    @State private var busy = false

    var body: some View {
        let controller = model.controller(for: account)
        let state = controller?.state ?? .stopped
        Section {
            HStack {
                TextField("Name", text: $name, prompt: Text(account.defaultTitle))
                    .onSubmit(rename)
                Button("Rename", action: rename)
                    .disabled(name.trimmingCharacters(in: .whitespaces) == (account.displayName ?? "") || busy)
            }
            LabeledContent("Account", value: account.email)
            LabeledContent("Status") {
                Text(driveStatusText(account: account, state: state, controller: controller))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("On this Mac", value: ByteFormat.string(model.localCopyBytes(account)))
            HStack {
                Button("Open in Finder") { model.openInFinder(account) }
                    .disabled(state != .mounted)
                Button(account.enabled ? "Disconnect" : "Connect") {
                    Task { await model.setEnabled(!account.enabled, for: account) }
                }
                Spacer()
                Button("Free Up Space") { freeUpSpace() }
                    .disabled(busy)
                Button("Remove…", role: .destructive) { confirmRemove = true }
                    .disabled(busy)
            }
            if let message { Message(text: message.text, isError: message.isError) }
        } header: {
            Text(account.title)
        } footer: {
            Caption("Free Up Space deletes the downloaded copies from this Mac; offline folders download again. Nothing is deleted from Google Drive.")
        }
        .onAppear { name = account.displayName ?? "" }
        .onChange(of: account.displayName) { _, value in name = value ?? "" }
        .confirmationDialog("Remove \(account.title)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { remove(force: false) }
        } message: {
            Text("The drive disappears from Finder and its downloaded copies are deleted from this Mac. Nothing is deleted from Google Drive.")
        }
        .confirmationDialog("\(account.title) still has changes uploading", isPresented: $confirmForceRemove) {
            Button("Remove and Lose Changes", role: .destructive) { remove(force: true) }
        } message: {
            Text("Changes that haven't uploaded yet will be lost. To keep them, wait until the drive says “Up to date”.")
        }
    }

    private func rename() {
        busy = true
        Task {
            if let problem = await model.rename(account, to: name) {
                message = (problem, true)
            } else {
                message = nil
            }
            busy = false
        }
    }

    private func freeUpSpace() {
        busy = true
        Task {
            message = await model.clearLocalCopies(account)
                ? ("Removed the downloaded copies. Everything is still in the cloud.", false)
                : ("Some changes are still uploading. Try again when it says “Up to date”.", true)
            busy = false
        }
    }

    private func remove(force: Bool) {
        busy = true
        Task {
            if !(await model.remove(account, force: force)) { confirmForceRemove = true }
            busy = false
        }
    }
}

// MARK: Storage

struct StorageSettings: View {
    @Environment(AppModel.self) private var model
    @State private var limit = 10
    @State private var keepFree = 5
    @State private var keepDays = 30
    @State private var applying = false
    @State private var offlineMessage: String?

    private static let dayChoices = [7, 14, 30, 90, 180, 365]

    var body: some View {
        Form {
            Section {
                Stepper(value: $limit, in: AppSettings.cacheLimitRange) {
                    Text("Keep up to **\(limit) GB** of downloaded files")
                }
                Stepper(value: $keepFree, in: AppSettings.keepFreeRange) {
                    Text(keepFree == 0 ? "Don't reserve free space" : "Always leave at least **\(keepFree) GB** free on this Mac")
                }
                Picker("Clear files not opened for", selection: $keepDays) {
                    ForEach(Set(Self.dayChoices + [keepDays]).sorted(), id: \.self) { days in
                        Text(days == 365 ? "1 year" : "\(days) days").tag(days)
                    }
                }
                HStack {
                    Spacer()
                    if applying { ProgressView().controlSize(.small) }
                    Button("Apply") { apply() }
                        .disabled(!changed || applying)
                }
            } header: {
                Text("Downloaded files")
            } footer: {
                Caption("Files you open stay on this Mac so they open fast next time. When a limit is reached, the files you haven't used for longest are cleared from this Mac; they stay in the cloud. Applying reconnects your drives.")
            }
            Section("Space used on this Mac") {
                ForEach(model.accounts) { account in
                    LabeledContent(account.title, value: ByteFormat.string(model.localCopyBytes(account)))
                }
                LabeledContent("Total") {
                    Text(ByteFormat.string(model.accounts.reduce(0) { $0 + model.localCopyBytes($1) })).bold()
                }
            }
            Section {
                OfflineFolderList()
                if let offlineMessage { Message(text: offlineMessage, isError: true) }
                HStack {
                    Button("Sync Now") { model.syncAllOffline() }
                        .disabled(model.accounts.allSatisfy(\.offlineFolders.isEmpty))
                    Spacer()
                    Button("Add Folder…") { addFolder() }
                        .disabled(model.accounts.isEmpty)
                }
            } header: {
                Text("Offline folders")
            } footer: {
                Caption("Files in these folders stay on this Mac so they open without internet, and they don't count toward the limit above. In Finder, right-click a folder in a drive and choose Quick Actions → Keep Offline.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private var changed: Bool {
        limit != model.settings.cacheLimitGB || keepFree != model.settings.keepFreeGB || keepDays != model.settings.keepCopiesDays
    }

    private func load() {
        limit = model.settings.cacheLimitGB
        keepFree = model.settings.keepFreeGB
        keepDays = model.settings.keepCopiesDays
    }

    private func apply() {
        applying = true
        Task {
            await model.update {
                $0.cacheLimitGB = limit
                $0.keepFreeGB = keepFree
                $0.keepCopiesDays = keepDays
            }
            load()
            applying = false
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Keep Offline"
        panel.message = "Choose a folder in one of your drives."
        panel.directoryURL = model.accounts.first.map { $0.mountPath(in: model.paths) } ?? model.paths.mountRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { offlineMessage = await model.keepOffline(url) }
    }
}

struct OfflineFolderList: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        let rows = model.accounts.flatMap { account in account.offlineFolders.map { OfflineRow(account: account, folder: $0) } }
        if rows.isEmpty && !compact {
            Text("No offline folders yet.")
                .foregroundStyle(.secondary)
        }
        ForEach(rows) { row in
            let account = row.account, folder = row.folder
            let sync = model.offlineSyncs[account.id]
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppModel.displayName(folder, in: account))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text((model.accounts.count > 1 && !compact ? account.title + " · " : "") + offlineStatusText(sync?.status[folder]))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(compact ? 1 : 3)
                }
                Spacer(minLength: 4)
                if let bytes = sync?.bytes[folder] {
                    Text(ByteFormat.string(bytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !compact {
                    Button {
                        Task { _ = await model.stopKeepingOffline(accountID: account.id, folder: folder) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Stop keeping offline")
                }
            }
        }
    }
}

private struct OfflineRow: Identifiable {
    let account: Account
    let folder: String
    var id: String { account.id + "/" + folder }
}

func offlineStatusText(_ status: OfflineSync.Status?) -> String {
    switch status {
    case nil: return "Waiting"
    case .waiting(let reason): return reason
    case .downloading(let done, let total): return "Downloading \(done) of \(total) files…"
    case .upToDate: return "Available offline"
    case .failed(let message): return message
    }
}

// MARK: Sync

struct SyncSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Picker("Check for changes made elsewhere", selection: model.binding(\.pollSeconds)) {
                    Text("Every 15 seconds").tag(15)
                    Text("Every minute").tag(60)
                    Text("Every 5 minutes").tag(300)
                }
            } footer: {
                Caption("Changes from your phone, the web or other computers show up in Finder this often. Drives reconnect when you change this.")
            }
            Section {
                HStack {
                    Button("Connect All") { Task { await model.setAllEnabled(true) } }
                        .disabled(model.accounts.allSatisfy(\.enabled))
                    Button("Disconnect All") { Task { await model.setAllEnabled(false) } }
                        .disabled(!model.accounts.contains(where: \.enabled))
                    Spacer()
                }
            } header: {
                Text("Drives")
            } footer: {
                Caption("Disconnected drives disappear from Finder. Files waiting to upload continue when you connect again.")
            }
            Section {
                LabeledContent("Internet", value: model.isOffline ? "Offline" : "Connected")
                HStack {
                    Spacer()
                    Button("Sync Offline Folders Now") { model.syncAllOffline() }
                        .disabled(model.accounts.allSatisfy(\.offlineFolders.isEmpty))
                }
            } header: {
                Text("Offline folders")
            } footer: {
                Caption("Offline folders download changes every 15 minutes, and as soon as this Mac is back online. Without internet, files in them still open, and your edits upload when you're back online.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Google

struct GoogleSettings: View {
    @Environment(AppModel.self) private var model
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                if let bundled = OAuthClient.bundled(), bundled.id == model.settings.googleClientID {
                    Label("This copy of Kitty Finder came with a sign-in client. It's saved here so updates keep working.",
                          systemImage: "checkmark.seal")
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField("Client ID", text: $clientID)
                SecureField("Client secret", text: $clientSecret)
                HStack {
                    Link("How to create one", destination: URL(string: "https://github.com/redwan-cpp/Kitty-finder/blob/main/docs/google-setup.md")!)
                    Spacer()
                    if saved { Text("Saved").foregroundStyle(.secondary) }
                    Button("Save") {
                        Task {
                            await model.update {
                                $0.googleClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
                                $0.googleClientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            saved = true
                        }
                    }
                    .disabled(clientID == model.settings.googleClientID && clientSecret == model.settings.googleClientSecret)
                }
            } header: {
                Text("Google sign-in client")
            } footer: {
                Caption("Google requires each app to have its own sign-in client. Create a “Desktop app” OAuth client in Google Cloud Console and paste it here. It's used when you add a drive; drives you already added keep working.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            clientID = model.settings.googleClientID
            clientSecret = model.settings.googleClientSecret
        }
        .onChange(of: clientID) { saved = false }
        .onChange(of: clientSecret) { saved = false }
    }
}

// MARK: Updates

struct UpdatesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updater = model.updater
        Form {
            Section {
                LabeledContent("This version", value: updater.currentVersion)
                LabeledContent("Latest version") {
                    switch updater.state {
                    case .checking: ProgressView().controlSize(.small)
                    case .upToDate: Text("You're up to date")
                    case .idle: Text(model.settings.lastUpdateCheck == nil ? "Not checked yet" : "—").foregroundStyle(.secondary)
                    case .failed: Text("Couldn't check").foregroundStyle(.secondary)
                    default: Text(updater.available?.version ?? "—")
                    }
                }
                if let last = model.settings.lastUpdateCheck {
                    LabeledContent("Last checked", value: last.formatted(date: .abbreviated, time: .shortened))
                }
                Toggle("Check for updates automatically", isOn: model.binding(\.checkForUpdates))
                HStack {
                    Spacer()
                    Button("Check Now") { Task { await model.checkForUpdates() } }
                        .disabled(updater.isBusy)
                }
            } footer: {
                Caption("Kitty Finder checks GitHub once a day. Nothing about you or your files is sent.")
            }
            if let release = updater.available {
                Section {
                    ScrollView {
                        Text(notes(release))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                    switch updater.state {
                    case .downloading(let fraction):
                        ProgressView(value: fraction) { Text("Downloading…") }
                    case .installing:
                        HStack { ProgressView().controlSize(.small); Text("Installing…") }
                    default:
                        EmptyView()
                    }
                    HStack {
                        Link("Release page", destination: release.pageURL)
                        Spacer()
                        Button("Install and Relaunch") { Task { await updater.install() } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(updater.isBusy)
                    }
                } header: {
                    Text("Kitty Finder \(release.version)")
                } footer: {
                    Caption("Your drives disconnect for a moment and come back after the restart; uploads that were waiting continue. Afterwards macOS may ask once to let Kitty Finder use its keychain item: enter your Mac password and choose Always Allow.")
                }
            }
            if case .failed(let message) = updater.state {
                Section { Message(text: message, isError: true) }
            }
        }
        .formStyle(.grouped)
    }

    private func notes(_ release: Release) -> AttributedString {
        let text = release.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { return AttributedString("No release notes.") }
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

// MARK: About

struct AboutSettings: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false
    @State private var confirmReset = false
    @State private var confirmForceReset = false
    @State private var resetting = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Kitty Finder").font(.title2.bold())
                        Text("Version \(model.appVersion) (\(model.buildNumber))")
                            .foregroundStyle(.secondary)
                        Text("Sync engine: rclone \(model.engineVersion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                Text("Your cloud drives in Finder. Files download only when you open them, so they don't fill up your Mac.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Links") {
                Link("Website", destination: URL(string: "https://kittydock.vercel.app")!)
                Link("Source code on GitHub", destination: URL(string: "https://github.com/redwan-cpp/Kitty-finder")!)
                Link("Privacy policy", destination: URL(string: "https://kittydock.vercel.app/privacy")!)
                Link("License (MIT)", destination: URL(string: "https://github.com/redwan-cpp/Kitty-finder/blob/main/LICENSE")!)
            }
            Section {
                HStack {
                    Button("Report a Problem…") { model.reportProblem() }
                    Button("Copy Diagnostics") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.diagnostics(), forType: .string)
                        copied = true
                    }
                    if copied { Text("Copied").foregroundStyle(.secondary) }
                    Spacer()
                    Button("Show Logs") { model.openLogs() }
                }
            } header: {
                Text("Help")
            } footer: {
                Caption("Report a Problem opens a new issue on GitHub. Diagnostics list versions and drive states without your email, drive names or file names; paste them into the report.")
            }
            Section {
                HStack {
                    Button("Reset Kitty Finder…", role: .destructive) { confirmReset = true }
                        .disabled(resetting)
                    if resetting { ProgressView().controlSize(.small) }
                }
            } footer: {
                Caption("Removes every drive, sign-in, setting and downloaded copy from this Mac. Nothing is deleted from your cloud drives.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset Kitty Finder?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { reset(force: false) }
        } message: {
            Text("All drives are removed from this Mac and you'll need to sign in again. Nothing is deleted from your cloud drives.")
        }
        .confirmationDialog("Some changes are still uploading", isPresented: $confirmForceReset) {
            Button("Reset and Lose Changes", role: .destructive) { reset(force: true) }
        } message: {
            Text("Changes that haven't uploaded yet will be lost. To keep them, wait until every drive says “Up to date”.")
        }
    }

    private func reset(force: Bool) {
        resetting = true
        Task {
            if !(await model.reset(force: force)) { confirmForceReset = true }
            resetting = false
        }
    }
}
