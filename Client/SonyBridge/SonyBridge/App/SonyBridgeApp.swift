//
//  SonyBridgeApp.swift
//  App entry: the main window, the menu-bar item and Settings, all sharing one HeadphonesController.
//

import AppKit
import SwiftUI

@main
struct SonyBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var headphones = HeadphonesController()

    var body: some Scene {
        Window("SonyBridge", id: MainWindow.id) {
            MainWindow()
                .environment(headphones)
        }
        .defaultSize(width: 420, height: 720)

        MenuBarExtra {
            MenuBarMenu()
                .environment(headphones)
        } label: {
            MenuBarLabel(headphones: headphones)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(headphones)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        DockPresence.apply()
    }

    // The menu-bar item keeps the app useful with the window closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// Whether the app shows in the Dock (with its app menus) or lives only in the menu bar.
enum DockPresence {
    static let defaultsKey = "showInDock"

    static var showInDock: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    static func set(_ show: Bool) {
        UserDefaults.standard.set(show, forKey: defaultsKey)
        apply()
    }

    static func apply() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        // Switching to .accessory deactivates the app; keep a visible window in front.
        if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            NSApp.activate()
        }
    }
}
