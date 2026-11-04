//
//  HeadphonesController+Settings.swift
//  Changing sound settings: ambient sound / noise cancelling, equalizer, DSEE and the optional features.
//

import Foundation

extension HeadphonesController {
    // Mirrors the C++ client: noise cancelling clears focus on voice; off keeps the last mode's type, level
    // and voice setting so the headset restores them when turned back on.
    func setAmbientMode(_ mode: AmbientMode) {
        guard ambientWritable else {
            return
        }
        ambientMode = mode
        if mode == .noiseCancelling {
            focusOnVoice = false
        }
        if mode != .off {
            lastOnMode = mode
        }
        pushAmbientState()
    }

    func setAmbientLevel(_ level: Int) {
        guard ambientWritable else {
            return
        }
        ambientLevel = max(1, min(level, maxAmbientLevel))
        if ambientMode == .ambientSound {
            pushAmbientState()
        }
    }

    func setFocusOnVoice(_ enabled: Bool) {
        guard ambientWritable else {
            return
        }
        focusOnVoice = enabled
        pushAmbientState()
    }

    private func pushAmbientState() {
        guard let protocolVersion else {
            return
        }
        let enabled = ambientMode != .off
        let ambient = (enabled ? ambientMode : lastOnMode) == .ambientSound
        let command: [UInt8]
        switch protocolVersion {
        case .v2:
            command = SonyCommand.setAmbientV2(enabled: enabled, ambient: ambient, focusOnVoice: focusOnVoice,
                                               level: ambient ? ambientLevel : 1)
        case .v1:
            // v1 has no separate NC/ambient field: level 0 means noise cancelling.
            command = SonyCommand.setAmbientV1(enabled: enabled, focusOnVoice: focusOnVoice, level: ambient ? ambientLevel : 0)
        }
        errorMessage = nil
        Task { await send(command) }
    }

    func setEqualizerPreset(_ preset: EqualizerPreset) {
        guard isV2, equalizer != nil else {
            return
        }
        equalizer?.preset = preset.rawValue
        errorMessage = nil
        let command = SonyCommand.setEqualizerPreset(preset, tenBand: tenBandEqualizer)
        let generation = self.generation
        Task {
            await send(command)
            // The bands that go with a preset live on the headset: Manual restores the curve last stored there,
            // and every other preset has its own. Without this read the sliders keep the previous preset's
            // values, and touching one writes them over the stored curve. Skipped if the user has moved on.
            guard isCurrent(generation), equalizer?.preset == preset.rawValue else {
                return
            }
            await refreshEqualizer()
        }
    }

    // Manual EQ: selects the Manual preset with these values. Standard layout: clear bass and five bands in
    // -10...10. Ten-band layout (WH-1000XM6): ten raw steps in 0...12, and clearBass is ignored.
    func setCustomEqualizer(clearBass: Int, bands: [Int]) {
        guard isV2, equalizer != nil else {
            return
        }
        let command: [UInt8]
        if tenBandEqualizer {
            let raw = bands.map { max(0, min(12, $0)) }
            equalizer = EqualizerState(preset: EqualizerPreset.manual.rawValue, clearBass: nil, bands: raw)
            command = SonyCommand.setTenBandEqualizer(bands: raw)
        } else {
            equalizer = EqualizerState(preset: EqualizerPreset.manual.rawValue, clearBass: clearBass, bands: bands)
            command = SonyCommand.setCustomEqualizer(clearBass: clearBass, bands: bands)
        }
        errorMessage = nil
        Task { await send(command) }
    }

    func setDsee(_ enabled: Bool) {
        guard isV2, dsee != nil else {
            return
        }
        dsee = enabled
        errorMessage = nil
        Task { await send(SonyCommand.setDsee(enabled)) }
    }

    // Like EQ and DSEE above: only sent when the headset answered the matching GET on connect.
    func setAutoPowerOff(_ option: AutoPowerOff) {
        guard autoPowerOff != nil else {
            return
        }
        autoPowerOff = option
        errorMessage = nil
        Task { await send(SonyCommand.setAutoPowerOff(option)) }
    }

    func setSpeakToChat(_ enabled: Bool) {
        guard speakToChat != nil else {
            return
        }
        speakToChat = enabled
        errorMessage = nil
        Task { await send(SonyCommand.setSpeakToChat(enabled)) }
    }

    func setAdaptiveVolume(_ enabled: Bool) {
        guard adaptiveVolume != nil else {
            return
        }
        adaptiveVolume = enabled
        errorMessage = nil
        Task { await send(SonyCommand.setAdaptiveVolume(enabled)) }
    }
}
