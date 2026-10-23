//
//  MenuBar.swift
//  The menu-bar item: pin playback to this Mac without opening the window. Its icon shows the playback
//  device next to the headphones (phone, computer, or slot number) and fills in while playback is fixed
//  to this Mac.
//

import AppKit
import SwiftUI

struct MenuBarMenu: View {
    @Environment(HeadphonesController.self) private var headphones
    @Environment(\.openWindow) private var openWindow
    @AppStorage(DockPresence.defaultsKey) private var showInDock = true

    var body: some View {
        if headphones.isConnected {
            Text([headphones.deviceName, headphones.battery.map { BatteryIcon.text(for: $0) }].compactMap { $0 }.joined(separator: " · "))
            if headphones.canSwitchPlayback {
                if headphones.thisMac != nil {
                    Toggle("Pin Playback to This Mac", isOn: Binding(
                        get: { headphones.pinnedToThisMac },
                        set: { $0 ? headphones.pinPlaybackToThisMac() : headphones.setPlaybackFixed(false) }
                    ))
                    .disabled(headphones.multipointBusy)
                } else {
                    Text("This Mac isn't a connected device")
                }
                if headphones.playbackFixed == true && !headphones.pinnedToThisMac {
                    Button("Unfix Playback") {
                        headphones.setPlaybackFixed(false)
                    }
                    .disabled(headphones.multipointBusy)
                }
            }
            if headphones.multipointBusy {
                Text("Sending…")
            } else if let error = headphones.errorMessage {
                Text(error)
            }
        } else {
            Text("No headphones connected")
            Button(headphones.state == .connecting ? "Connecting…" : "Connect Headphones") {
                NSApp.activate()
                headphones.connect()
            }
            .disabled(headphones.state == .connecting)
        }
        Divider()
        Toggle("Show in Dock", isOn: Binding(get: { showInDock }, set: { DockPresence.set($0) }))
        Button("Open SonyBridge") {
            openWindow(id: MainWindow.id)
            NSApp.activate()
        }
        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit SonyBridge") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

struct MenuBarLabel: View {
    let headphones: HeadphonesController

    var body: some View {
        Image(nsImage: MenuBarIcon.image(base: headphones.pinnedToThisMac ? "headphones.circle.fill" : "headphones",
                                         accessory: headphones.isConnected ? headphones.playbackDevice.map { MenuBarIcon.symbol(for: $0) } : nil))
            .help(tooltip)
            // The menu-bar label exists from launch even with the window closed, so auto-connect starts here.
            .task {
                headphones.connectAutomatically()
            }
    }

    private var tooltip: String {
        guard headphones.isConnected else {
            return "SonyBridge"
        }
        var lines = [String]()
        if let device = headphones.playbackDevice {
            lines.append("Playing on \(device.displayName)" + (headphones.playbackFixed == true ? " (fixed)" : ""))
        } else {
            lines.append(headphones.deviceName)
        }
        if let battery = headphones.battery {
            lines.append("Battery \(BatteryIcon.text(for: battery))")
        }
        return lines.joined(separator: "\n")
    }
}

enum MenuBarIcon {
    // Phone if the name says so, computer for a Mac, otherwise the multipoint slot number.
    static func symbol(for device: PairedDevice) -> String {
        let name = device.name.lowercased()
        if name.contains("phone") {
            return "iphone"
        }
        if name.contains("mac") || device.classOfDevice.map({ ($0 >> 8) & 0x1F == 1 && $0 != 0xFFFFFF }) == true {
            return "laptopcomputer"
        }
        return "\(device.slot).circle"
    }

    // The headphones symbol with an optional second symbol beside it, as one template image.
    static func image(base: String, accessory: String?) -> NSImage {
        let baseConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let accessoryConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        guard let baseImage = NSImage(systemSymbolName: base, accessibilityDescription: "SonyBridge")?
            .withSymbolConfiguration(baseConfig) else {
            return NSImage()
        }
        guard let accessory,
              let accessoryImage = NSImage(systemSymbolName: accessory, accessibilityDescription: nil)?
                .withSymbolConfiguration(accessoryConfig) else {
            baseImage.isTemplate = true
            return baseImage
        }
        let spacing: CGFloat = 2
        let size = NSSize(width: baseImage.size.width + spacing + accessoryImage.size.width,
                          height: max(baseImage.size.height, accessoryImage.size.height))
        let image = NSImage(size: size, flipped: false) { _ in
            baseImage.draw(in: NSRect(x: 0, y: (size.height - baseImage.size.height) / 2,
                                      width: baseImage.size.width, height: baseImage.size.height))
            accessoryImage.draw(in: NSRect(x: baseImage.size.width + spacing, y: (size.height - accessoryImage.size.height) / 2,
                                           width: accessoryImage.size.width, height: accessoryImage.size.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SonyBridge"
        return image
    }
}
