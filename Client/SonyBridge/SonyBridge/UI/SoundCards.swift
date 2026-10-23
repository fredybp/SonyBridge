//
//  SoundCards.swift
//  Ambient sound / noise cancelling, equalizer, and the optional feature switches.
//

import SwiftUI

struct AmbientCard: View {
    @Environment(HeadphonesController.self) private var headphones

    var body: some View {
        Card("Ambient Sound Control") {
            HStack(spacing: 10) {
                modeButton(.noiseCancelling, "Noise Cancelling", "person.wave.2.fill")
                modeButton(.ambientSound, "Ambient Sound", "ear.fill")
                modeButton(.off, "Off", "circle.slash")
            }

            if headphones.ambientMode == .ambientSound {
                LabeledContent {
                    Text("\(headphones.ambientLevel)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } label: {
                    Text("Ambient Sound Level")
                }
                Slider(value: Binding(get: { Double(headphones.ambientLevel) },
                                      set: { headphones.setAmbientLevel(Int($0.rounded())) }),
                       in: 1...Double(headphones.maxAmbientLevel), step: 1)
                if headphones.focusOnVoiceAvailable {
                    Toggle("Focus on Voice", isOn: Binding(get: { headphones.focusOnVoice },
                                                           set: { headphones.setFocusOnVoice($0) }))
                        .toggleStyle(.switch)
                }
            }
        }
        .disabled(!headphones.ambientWritable)
    }

    private func modeButton(_ mode: AmbientMode, _ title: String, _ symbol: String) -> some View {
        let selected = headphones.ambientMode == mode
        return Button {
            headphones.setAmbientMode(mode)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.title2)
                Text(title)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(SelectableTileStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct EqualizerCard: View {
    @Environment(HeadphonesController.self) private var headphones

    private static let bandLabels = ["400", "1k", "2.5k", "6.3k", "16k"]

    var body: some View {
        Card("Equalizer") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(EqualizerPreset.allCases) { preset in
                    let selected = headphones.equalizer?.preset == preset.rawValue
                    Button {
                        if preset == .manual {
                            applyManual()
                        } else {
                            headphones.setEqualizerPreset(preset)
                        }
                    } label: {
                        Text(preset.title)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SelectableTileStyle(selected: selected))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }

            if headphones.equalizer?.preset == EqualizerPreset.manual.rawValue {
                Divider()
                ForEach(0..<5, id: \.self) { index in
                    bandRow(Self.bandLabels[index], value: bands[index]) { value in
                        var newBands = bands
                        newBands[index] = value
                        headphones.setCustomEqualizer(clearBass: clearBass, bands: newBands)
                    }
                }
                bandRow("Clear Bass", value: clearBass) { value in
                    headphones.setCustomEqualizer(clearBass: value, bands: bands)
                }
            }
        }
    }

    private var bands: [Int] { headphones.equalizer?.bands ?? [0, 0, 0, 0, 0] }
    private var clearBass: Int { headphones.equalizer?.clearBass ?? 0 }

    private func applyManual() {
        headphones.setCustomEqualizer(clearBass: clearBass, bands: bands)
    }

    private func bandRow(_ label: String, value: Int, set: @escaping @MainActor (Int) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Slider(value: Binding(get: { Double(value) }, set: { set(Int($0.rounded())) }), in: -10...10, step: 1)
            Text(value > 0 ? "+\(value)" : "\(value)")
                .font(.caption.monospacedDigit())
                .frame(width: 28, alignment: .trailing)
        }
    }
}

struct FeaturesCard: View {
    @Environment(HeadphonesController.self) private var headphones

    var body: some View {
        Card("Settings") {
            if let dsee = headphones.dsee {
                featureToggle("DSEE", "Upscale compressed audio", dsee, headphones.setDsee)
            }
            if let adaptiveVolume = headphones.adaptiveVolume {
                featureToggle("Adaptive Volume", "Adjust volume to your surroundings", adaptiveVolume, headphones.setAdaptiveVolume)
            }
            if let speakToChat = headphones.speakToChat {
                featureToggle("Speak-to-Chat", "Pause music when you talk", speakToChat, headphones.setSpeakToChat)
            }
            if let autoPowerOff = headphones.autoPowerOff {
                Picker(selection: Binding(get: { autoPowerOff }, set: { headphones.setAutoPowerOff($0) })) {
                    ForEach(AutoPowerOff.allCases) { option in
                        Text(option.title).tag(option)
                    }
                } label: {
                    featureLabel("Auto Power-Off", "Turn off when idle")
                }
            }
        }
    }

    private func featureToggle(_ title: String, _ subtitle: String, _ isOn: Bool,
                               _ set: @escaping @MainActor (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            featureLabel(title, subtitle)
        }
        .toggleStyle(.switch)
    }

    private func featureLabel(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
