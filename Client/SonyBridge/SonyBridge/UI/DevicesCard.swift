//
//  DevicesCard.swift
//  Multipoint: connected and paired devices, which one has playback, fixing it, and switching it.
//

import AppKit
import SwiftUI

struct DevicesCard: View {
    @Environment(HeadphonesController.self) private var headphones

    var body: some View {
        Card("Devices", trailing: AnyView(headerAccessory)) {
            if headphones.multipointLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading devices from the headset…")
                        .foregroundStyle(.secondary)
                }
            } else {
                content
            }
        }
    }

    @ViewBuilder private var headerAccessory: some View {
        if headphones.multipointLoading || headphones.refreshingMultipoint || headphones.multipointBusy {
            ProgressView()
                .controlSize(.small)
        } else {
            Button("Refresh", systemImage: "arrow.clockwise", action: headphones.refreshMultipoint)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }

    @ViewBuilder private var content: some View {
        // Plain rows rather than LabeledContent, which only right-aligns its value inside a Form.
        if let enabled = headphones.multipointEnabled {
            HStack {
                Text("Connect to 2 devices")
                Spacer()
                Text(enabled ? "On" : "Off")
                    .foregroundStyle(.secondary)
            }
        }
        if let fixed = headphones.playbackFixed {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Playback device")
                    Text(fixed ? "Fixed" : "Switches automatically")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(fixed ? "Unfix" : "Fix") {
                    headphones.setPlaybackFixed(!fixed)
                }
                .buttonStyle(.bordered)
                .disabled(headphones.multipointBusy)
            }
        }

        if let devices = headphones.pairedDevices {
            let connected = devices.filter(\.connected).sorted { $0.slot < $1.slot }
            let paired = devices.filter { !$0.connected }
            if !connected.isEmpty {
                sectionLabel("Connected")
                ForEach(connected) { DeviceRow(device: $0) }
            }
            if !paired.isEmpty {
                sectionLabel("Paired")
                ForEach(paired) { DeviceRow(device: $0) }
            }
        } else {
            Text("This headset didn't return a device list.")
                .foregroundStyle(.secondary)
        }

        Divider()
        HStack {
            Text(headphones.multipointBusy ? "Sending…" : "Switching and fixing are experimental")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Copy Diagnostics") {
                let header = "\(headphones.deviceName) · fw \(headphones.firmware ?? "?") · \(headphones.protocolVersion?.rawValue ?? "")\n"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(header + headphones.multipointDiagnostics, forType: .string)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct DeviceRow: View {
    @Environment(HeadphonesController.self) private var headphones
    let device: PairedDevice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: DeviceRow.symbol(for: device.classOfDevice))
                .frame(width: 22)
                .foregroundStyle(device.connected ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .lineLimit(1)
                    .foregroundStyle(device.connected ? .primary : .secondary)
                if headphones.isThisMac(device) {
                    Text("This Mac")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
            Spacer()
            if device.playback {
                if headphones.playbackFixed == true {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .help("Playback fixed")
                }
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.tint)
                    .help("Playing")
            }
            if device.connected && headphones.canSwitchPlayback {
                Menu {
                    Button("Switch Playback Device and Fix") {
                        headphones.switchPlayback(to: device, fix: true)
                    }
                    if !device.playback {
                        Button("Switch Playback Device") {
                            headphones.switchPlayback(to: device, fix: false)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(headphones.multipointBusy)
            }
        }
    }

    // Major device class lives in bits 8-12 of the class of device (1 = computer, 2 = phone).
    static func symbol(for classOfDevice: Int?) -> String {
        guard let classOfDevice, classOfDevice != 0xFFFFFF else {
            return "dot.radiowaves.left.and.right"
        }
        switch (classOfDevice >> 8) & 0x1F {
        case 1:
            return "laptopcomputer"
        case 2:
            return "iphone"
        default:
            return "dot.radiowaves.left.and.right"
        }
    }
}
