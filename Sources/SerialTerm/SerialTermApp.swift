// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import AppKit
import SwiftUI

@main
struct SerialTermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var scanner = PortScanner()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(scanner)
        }
        .windowToolbarStyle(.unified(showsTitle: true))

        Settings {
            SettingsWindow(settings: AppSettings.shared)
                .environmentObject(scanner)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to a transfer program that has just exited must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        // Needed when run unbundled via `swift run`; harmless inside a .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = TerminalModel.transfersRunning
        guard running > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = running == 1 ? "A file transfer is running" : "\(running) file transfers are running"
        alert.informativeText = "Quitting cancels it and tells the device to stop."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Windows aren't torn down at quit: close the ports now, so a transfer is cancelled
        // cleanly and each log gets its closing line.
        TerminalModel.disconnectAll()
    }
}
