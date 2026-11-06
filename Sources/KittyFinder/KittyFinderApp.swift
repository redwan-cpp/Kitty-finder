import AppKit
import KittyFinderCore
import SwiftUI

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
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var quitting = false
    private var statusItem: StatusItemController?
    private var window: NSWindow?
    private var settingsWindow: NSWindow?

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

        model.openSettingsHandler = { [weak self] in self?.showSettings() }
        statusItem = StatusItemController(model: model)
        Task {
            await model.start()
            // Until the first drive is added, show a window too: a menu bar icon is easy to miss.
            if model.accounts.isEmpty || model.fatalError != nil { showWindow() }
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

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "Kitty Finder Settings", content: SettingsView().environment(model))
        }
        present(settingsWindow)
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
            button.image = KittyGlyph.image
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
        let title: String
        if model.hasProblem {
            title = "!"
        } else if pending > 0 {
            title = "↑\(pending)"
        } else {
            title = ""
        }
        item.button?.title = title
        item.button?.setAccessibilityValue(title.isEmpty ? "Up to date" : (model.hasProblem ? "Needs attention" : "\(pending) uploading"))
    }
}

/// The two-tone kitty face from the app icon, as a monochrome template image
/// so macOS tints it for light and dark menu bars.
enum KittyGlyph {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
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
            // Hollow out the left half of the face, leaving an outline: the "two tones"
            ctx.setBlendMode(.clear)
            NSBezierPath(roundedRect: NSRect(x: 3.4, y: 5.9, width: 5.6, height: 8.7), xRadius: 2.3, yRadius: 2.3).fill()
            // Right eye cut out of the solid half
            NSBezierPath(ovalIn: NSRect(x: 11, y: 8.2, width: 2, height: 2.8)).fill()
            // Left eye drawn into the hollow half
            ctx.setBlendMode(.normal)
            NSBezierPath(ovalIn: NSRect(x: 5, y: 8.2, width: 2, height: 2.8)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Kitty Finder"
        return image
    }()
}
