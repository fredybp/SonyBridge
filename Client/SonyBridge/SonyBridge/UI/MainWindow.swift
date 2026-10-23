//
//  MainWindow.swift
//  The main window: connect screen, or the headset with its cards.
//

import SwiftUI

struct MainWindow: View {
    static let id = "main"

    @Environment(HeadphonesController.self) private var headphones

    var body: some View {
        Group {
            if headphones.isConnected {
                ConnectedView()
            } else {
                DisconnectedView()
            }
        }
        .frame(minWidth: 380, minHeight: 520)
        // A translucent window, so the desktop blurs through behind the glass cards.
        .containerBackground(.ultraThinMaterial, for: .window)
        .toolbar {
            if headphones.isConnected {
                ToolbarItem {
                    Button("Disconnect", systemImage: "power", action: headphones.disconnect)
                        .help("Disconnect from the headphones")
                }
            }
            ToolbarItem {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
    }
}

private struct DisconnectedView: View {
    @Environment(HeadphonesController.self) private var headphones
    @AppStorage(HeadphonesController.autoConnectDefaultsKey) private var connectAutomatically = true

    var body: some View {
        ContentUnavailableView {
            Label("No Headphones Connected", systemImage: "headphones")
        } description: {
            if let error = headphones.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
            } else {
                Text("Connect your headphones in Bluetooth settings first, and keep audio playing.")
            }
        } actions: {
            // On macOS the actions are laid out side by side; stack them so nothing gets pushed off screen.
            VStack(spacing: 12) {
                Button(headphones.state == .connecting ? "Connecting…" : "Connect Headphones") {
                    headphones.connect()
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(headphones.state == .connecting)
                if headphones.bluetoothDenied {
                    Button("Open Bluetooth Settings", action: BluetoothPermission.openSettings)
                        .buttonStyle(.glass)
                }
                Toggle("Connect automatically", isOn: $connectAutomatically)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .help("When SonyBridge opens, connect to a Sony headset that's already connected to this Mac")
            }
            .fixedSize()
        }
    }
}

private struct ConnectedView: View {
    @Environment(HeadphonesController.self) private var headphones

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HeaderView()
                AmbientCard()
                if headphones.isV2 {
                    DevicesCard()
                }
                if headphones.equalizer != nil {
                    EqualizerCard()
                }
                if headphones.dsee != nil || headphones.adaptiveVolume != nil || headphones.speakToChat != nil
                    || headphones.autoPowerOff != nil {
                    FeaturesCard()
                }
                if let error = headphones.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
    }
}

private struct HeaderView: View {
    @Environment(HeadphonesController.self) private var headphones

    var body: some View {
        VStack(spacing: 10) {
            Group {
                if let image = NSImage(named: headphones.deviceName.lowercased().replacingOccurrences(of: " ", with: "-")) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "headphones")
                        .font(.system(size: 88, weight: .thin))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 170, height: 170)

            Text(headphones.deviceName)
                .font(.title.bold())

            HStack(spacing: 6) {
                if let battery = headphones.battery {
                    Image(systemName: battery.charging ? "battery.100.bolt" : BatteryIcon.symbol(for: battery.level))
                        .foregroundStyle(battery.level <= 20 ? .red : .secondary)
                    Text(BatteryIcon.text(for: battery))
                } else {
                    Text("Connected")
                }
                if let codec = headphones.codec {
                    Text("·")
                    Text(codec)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }
}

enum BatteryIcon {
    static func symbol(for level: Int) -> String {
        switch level {
        case ...15:
            return "battery.0"
        case ...40:
            return "battery.25"
        case ...65:
            return "battery.50"
        case ...90:
            return "battery.75"
        default:
            return "battery.100"
        }
    }

    // "80%", "80% charging", or "L 80% · R 75%" for earbuds.
    static func text(for battery: BatteryStatus) -> String {
        if let left = battery.left, let right = battery.right {
            return "L \(left)% · R \(right)%"
        }
        return "\(battery.level)%" + (battery.charging ? " charging" : "")
    }
}

// A Liquid Glass panel. Controls inside use solid tiles (SelectableTileStyle), not glass, to avoid glass on glass.
struct Card<Content: View>: View {
    let title: String
    var trailing: AnyView?
    @ViewBuilder let content: Content

    init(_ title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                trailing
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

// Mode buttons and EQ presets inside the glass cards: accent fill when selected, a subtle fill otherwise.
struct SelectableTileStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: .rect(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(.rect(cornerRadius: 12))
    }
}
