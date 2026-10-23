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
        Task { await send(SonyCommand.setEqualizerPreset(preset)) }
    }

    // Manual EQ: selects the Manual preset with the current clear bass and band values.
    func setCustomEqualizer(clearBass: Int, bands: [Int]) {
        guard isV2, equalizer != nil else {
            return
        }
        equalizer = EqualizerState(preset: EqualizerPreset.manual.rawValue, clearBass: clearBass, bands: bands)
        errorMessage = nil
        Task { await send(SonyCommand.setCustomEqualizer(clearBass: clearBass, bands: bands)) }
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
