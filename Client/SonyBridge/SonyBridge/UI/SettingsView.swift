//
//  SettingsView.swift
//  Settings window: app options and details about the connected headset.
//

import SwiftUI

struct SettingsView: View {
    @Environment(HeadphonesController.self) private var headphones
    @AppStorage(DockPresence.defaultsKey) private var showInDock = true

    var body: some View {
        Form {
            Section("General") {
                Toggle(isOn: Binding(get: { showInDock }, set: { DockPresence.set($0) })) {
                    Text("Show in Dock")
                    Text("When off, SonyBridge lives only in the menu bar.")
                }
            }
            Section("Headphones") {
                if headphones.isConnected {
                    LabeledContent("Name", value: headphones.deviceName)
                    if let battery = headphones.battery {
                        LabeledContent("Battery", value: BatteryIcon.text(for: battery))
                        if let caseLevel = battery.caseLevel {
                            LabeledContent("Case", value: "\(caseLevel)%")
                        }
                    }
                    if let codec = headphones.codec {
                        LabeledContent("Codec", value: codec)
                    }
                    if let firmware = headphones.firmware {
                        LabeledContent("Firmware", value: firmware)
                    }
                    if let version = headphones.protocolVersion {
                        LabeledContent("Protocol", value: version.rawValue)
                    }
                    LabeledContent("Bluetooth", value: headphones.deviceAddress)
                } else {
                    Text("Not connected")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Text("SonyBridge \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · not affiliated with Sony")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
