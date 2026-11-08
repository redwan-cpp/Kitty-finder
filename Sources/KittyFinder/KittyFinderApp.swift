import AppKit
import KittyFinderCore
import SwiftUI
import UserNotifications

/// Kitty Finder is a menu bar app built on AppKit (status item + popover),
/// with SwiftUI views inside. There is no Dock icon (LSUIElement).
@main
enum KittyFinderMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()
    private var quitting = false
    private var statusItem: StatusItemController?
    private var window: NSWindow?
    private var settings: SettingsWindowController?
    private var services: FinderServices?

    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A plain SIGTERM (kill, pkill) would end the app on the spot and leave its
        // drives' engines behind. Turn it into a normal quit that stops them cleanly.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        // Not NSApp.terminate directly: this handler runs inside the main queue, and
        // terminate's wait for stopAll (a main-actor task) would then never finish.
        source.setEventHandler { RunLoop.main.perform { NSApp.terminate(nil) } }
        source.resume()
        terminationSignal = source

        model.openSettingsHandler = { [weak self] tab in self?.showSettings(tab) }
        statusItem = StatusItemController(model: model)
        UNUserNotificationCenter.current().delegate = self
        // Finder → right-click a folder → Quick Actions → Keep Offline
        let services = FinderServices(model: model)
        self.services = services
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        Task {
            await model.start()
            // Until the first drive is added, show a window too: a menu bar icon is easy to miss.
            if model.accounts.isEmpty || model.fatalError != nil || model.settings.showWindowAtLaunch { showWindow() }
        }
        Task {
            // Startup normally takes a moment. If it's still going, macOS is most
            // likely showing a keychain prompt: show the window explaining it.
            try? await Task.sleep(for: .seconds(1.5))
            if model.isStarting { showWindow() }
        }
    }

    /// Opening the app again (Finder, Spotlight) shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func showWindow() {
        if window == nil {
            let content = VStack(alignment: .leading, spacing: 0) {
                MenuContent()
                Text("Kitty Finder lives in your menu bar, near the clock. Open Kitty Finder again any time to get this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding([.horizontal, .bottom], 14)
                    .frame(width: 320, alignment: .leading)
            }
            .environment(model)
            window = makeWindow(title: "Kitty Finder", content: content)
        }
        present(window)
    }

    func showSettings(_ tab: SettingsTab? = nil) {
        if settings == nil { settings = SettingsWindowController(model: model) }
        if let tab { settings?.select(tab) }
        present(settings?.window)
    }

    // Show notifications even while the menu is open, and open the right page when clicked.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        await MainActor.run {
            let tab: SettingsTab = id.hasPrefix("update") ? .updates : id.hasPrefix("offline") ? .storage : .drives
            self.showSettings(tab)
        }
    }

    private func makeWindow(title: String, content: some View) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        statusItem?.closePopover()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        let pending = model.totalPendingUploads
        if pending > 0 {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "\(pending) file\(pending == 1 ? " is" : "s are") still uploading"
            alert.informativeText = "If you quit now, the uploads finish the next time you open Kitty Finder."
            alert.addButton(withTitle: "Keep Uploading")
            alert.addButton(withTitle: "Quit Anyway")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        quitting = true
        Task {
            await model.stopAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// The menu bar item: the kitty glyph, plus an upload count or "!" when needed.
/// Clicking it opens the same content as the window, in a popover.
@MainActor
final class StatusItemController: NSObject {
    static let autosaveName = "KittyFinder"
    private let model: AppModel
    private let item: NSStatusItem
    private let popover = NSPopover()

    init(model: AppModel) {
        self.model = model
        // macOS keeps each item's spot (distance from the right edge) under this key.
        // On first run ask for the right end, beside the clock, so it isn't hidden
        // behind the notch on a full menu bar. If you Cmd-drag it, macOS remembers that instead.
        let positionKey = "NSStatusItem Preferred Position \(Self.autosaveName)"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(Double(1), forKey: positionKey)
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.autosaveName = Self.autosaveName
        item.behavior = []
        if let button = item.button {
            button.image = KittyGlyph.image(.twoTone)
            button.imagePosition = .imageLeading
            button.toolTip = "Kitty Finder"
            button.setAccessibilityLabel("Kitty Finder")
            button.target = self
            button.action = #selector(toggle)
        }
        let host = NSHostingController(rootView: MenuContent().environment(model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        observe()
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = item.button {
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func closePopover() { popover.performClose(nil) }

    /// Updates the badge whenever upload counts or errors change.
    private func observe() {
        withObservationTracking {
            updateBadge()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func updateBadge() {
        let pending = model.totalPendingUploads
        item.button?.image = KittyGlyph.image(model.settings.menuBarIcon)
        let title: String
        if model.hasProblem {
            title = "!"
        } else if pending > 0 && model.settings.showUploadCount {
            title = "↑\(pending)"
        } else {
            title = ""
        }
        item.button?.title = title
        item.button?.setAccessibilityValue(title.isEmpty ? "Up to date" : (model.hasProblem ? "Needs attention" : "\(pending) uploading"))
    }
}

/// Menu bar icons, as monochrome template images so macOS tints them for
/// light and dark menu bars.
@MainActor
enum KittyGlyph {
    private static var cache: [MenuBarIconStyle: NSImage] = [:]

    static func image(_ style: MenuBarIconStyle) -> NSImage {
        if let image = cache[style] { return image }
        let image: NSImage
        switch style {
        case .twoTone: image = kitty(outline: false)
        case .outline: image = kitty(outline: true)
        case .cloud:
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            image = NSImage(systemSymbolName: "cloud", accessibilityDescription: "Kitty Finder")?
                .withSymbolConfiguration(config) ?? kitty(outline: false)
        }
        image.isTemplate = true
        image.accessibilityDescription = "Kitty Finder"
        cache[style] = image
        return image
    }

    /// The kitty face from the app icon: two-tone (one half hollow), or a plain outline.
    private static func kitty(outline: Bool) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let ctx = NSGraphicsContext.current!.cgContext
            NSColor.black.setFill()
            // Head with ears
            let head = NSBezierPath(roundedRect: NSRect(x: 2, y: 4.5, width: 14, height: 11.5), xRadius: 3.6, yRadius: 3.6)
            head.fill()
            for ear in [[NSPoint(x: 2.6, y: 7), NSPoint(x: 4, y: 1.2), NSPoint(x: 8, y: 5)],
                        [NSPoint(x: 15.4, y: 7), NSPoint(x: 14, y: 1.2), NSPoint(x: 10, y: 5)]] {
                let p = NSBezierPath()
                p.move(to: ear[0]); p.line(to: ear[1]); p.line(to: ear[2]); p.close()
                p.fill()
            }
            ctx.setBlendMode(.clear)
            if outline {
                // Hollow out the whole face, leaving its outline and solid ears
                NSBezierPath(roundedRect: NSRect(x: 3.5, y: 6, width: 11, height: 8.5), xRadius: 2.4, yRadius: 2.4).fill()
                ctx.setBlendMode(.normal)
                NSBezierPath(ovalIn: NSRect(x: 5.6, y: 8.4, width: 1.9, height: 2.6)).fill()
                NSBezierPath(ovalIn: NSRect(x: 10.5, y: 8.4, width: 1.9, height: 2.6)).fill()
            } else {
                // Hollow out the left half of the face, leaving an outline: the "two tones"
                NSBezierPath(roundedRect: NSRect(x: 3.4, y: 5.9, width: 5.6, height: 8.7), xRadius: 2.3, yRadius: 2.3).fill()
                // Right eye cut out of the solid half
                NSBezierPath(ovalIn: NSRect(x: 11, y: 8.2, width: 2, height: 2.8)).fill()
                // Left eye drawn into the hollow half
                ctx.setBlendMode(.normal)
                NSBezierPath(ovalIn: NSRect(x: 5, y: 8.2, width: 2, height: 2.8)).fill()
            }
            return true
        }
    }
}

/// Finder's Services / Quick Actions entries for folders (declared as NSServices
/// in Info.plist): "Keep Offline" and "Stop Keeping Offline".
@MainActor
final class FinderServices: NSObject {
    private let model: AppModel

    init(model: AppModel) { self.model = model }

    @objc func keepOffline(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pasteboard) { await self.model.keepOffline($0) }
    }

    @objc func stopKeepingOffline(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pasteboard) { await self.model.stopKeepingOffline($0) }
    }

    private func handle(_ pasteboard: NSPasteboard, _ action: @escaping (URL) async -> String?) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        Task {
            var problems: [String] = []
            for url in urls {
                if let problem = await action(url) { problems.append(problem) }
            }
            guard !problems.isEmpty else { return }
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Kitty Finder"
            alert.informativeText = problems.joined(separator: "\n\n")
            alert.runModal()
        }
    }
}
