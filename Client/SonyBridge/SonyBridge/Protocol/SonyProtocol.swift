//
//  SonyProtocol.swift
//  Sony headphone commands (request encoders) and reply parsers, for both protocol generations.
//
//  v1 = the original service UUID (WH-1000XM2-XM4 era), v2 = the second-generation UUID (XM5, CH720N...).
//  Opcodes overlap with different meanings across generations (0x22 is battery on v2 but POWER OFF on
//  v1), so every command here is only ever sent to the generation it is documented for.
//

import Foundation

nonisolated enum SonyProtocolVersion: String, Sendable {
    case v1
    case v2
}

nonisolated enum AmbientMode: Sendable {
    case off
    case noiseCancelling
    case ambientSound
}

nonisolated enum EqualizerPreset: UInt8, CaseIterable, Identifiable, Sendable {
    case off = 0x00
    case bright = 0x10
    case excited = 0x11
    case mellow = 0x12
    case relaxed = 0x13
    case vocal = 0x14
    case trebleBoost = 0x15
    case bassBoost = 0x16
    case speech = 0x17
    case manual = 0xa0

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .off:
            return "Off"
        case .bright:
            return "Bright"
        case .excited:
            return "Excited"
        case .mellow:
            return "Mellow"
        case .relaxed:
            return "Relaxed"
        case .vocal:
            return "Vocal"
        case .trebleBoost:
            return "Treble"
        case .bassBoost:
            return "Bass"
        case .speech:
            return "Speech"
        case .manual:
            return "Manual"
        }
    }
}

nonisolated enum AutoPowerOff: Int, CaseIterable, Identifiable, Sendable {
    case off
    case fiveMinutes
    case thirtyMinutes
    case oneHour
    case threeHours
    case whenTakenOff

    var id: Int { rawValue }

    var code: (UInt8, UInt8) {
        switch self {
        case .off:
            return (0x11, 0x00)
        case .fiveMinutes:
            return (0x00, 0x00)
        case .thirtyMinutes:
            return (0x01, 0x01)
        case .oneHour:
            return (0x02, 0x02)
        case .threeHours:
            return (0x03, 0x03)
        case .whenTakenOff:
            return (0x10, 0x00)
        }
    }

    var title: String {
        switch self {
        case .off:
            return "Off"
        case .fiveMinutes:
            return "5 min"
        case .thirtyMinutes:
            return "30 min"
        case .oneHour:
            return "1 hour"
        case .threeHours:
            return "3 hours"
        case .whenTakenOff:
            return "When taken off"
        }
    }
}

nonisolated struct BatteryStatus: Equatable, Sendable {
    var level: Int
    var charging: Bool
    // TWS earbuds only.
    var left: Int?
    var right: Int?
    var caseLevel: Int?
}

nonisolated struct EqualizerState: Equatable, Sendable {
    var preset: UInt8
    var clearBass: Int?
    var bands: [Int]?
}

nonisolated struct AmbientReading: Equatable, Sendable {
    var enabled: Bool
    var ambient: Bool
    var focusOnVoice: Bool
    var level: Int
}

// One entry of the headset's paired-device list (multipoint).
nonisolated struct PairedDevice: Identifiable, Equatable, Sendable {
    var address: String         // "XX:XX:XX:XX:XX:XX", exactly as the headset reports it
    var name: String
    var slot: Int               // 0 = paired only, 1/2 = connected multipoint slot
    var classOfDevice: Int?     // 24-bit Bluetooth class of device; 0xFFFFFF for paired-only devices
    var playback: Bool          // holds the playback (A2DP) right

    var id: String { address }
    var connected: Bool { slot != 0 }
    var displayName: String { name.isEmpty ? address : name }
}

// Results of the playback switch / fix writes (Sound Connect's SourceSwitchControlResult).
nonisolated enum SourceSwitchResult: Equatable, Sendable {
    case success
    case failed
    case inCall
    case audioNotConnected
    case voiceAssistantPriority
    case other(UInt8)
    // Ours, not the headset's: no notify arrived in time. The state is re-read afterwards.
    case noConfirmation

    init(code: UInt8) {
        switch code {
        case 0x00:
            self = .success
        case 0x01:
            self = .failed
        case 0x02:
            self = .inCall
        case 0x03:
            self = .audioNotConnected
        case 0x04:
            self = .voiceAssistantPriority
        default:
            self = .other(code)
        }
    }

    var message: String? {
        switch self {
        case .success:
            return nil
        case .failed:
            return "The headset refused the change."
        case .inCall:
            return "The headset refused: a call is in progress."
        case .audioNotConnected:
            return "The headset refused: that device isn't connected for audio."
        case .voiceAssistantPriority:
            return "The headset refused: the voice assistant has priority."
        case .other(let code):
            return "The headset refused the change (result \(code))."
        case .noConfirmation:
            return "The headset didn't confirm the change. Showing the state it reports now."
        }
    }
}

// MARK: - Opcodes

nonisolated enum SonyOpcode {
    // Table 1, v2
    static let initRequest: UInt8 = 0x00
    static let initReply: UInt8 = 0x01
    static let firmwareGet: UInt8 = 0x04
    static let firmwareReply: UInt8 = 0x05
    static let codecGet: UInt8 = 0x12
    static let codecReply: UInt8 = 0x13
    static let batteryGet: UInt8 = 0x22
    static let batteryReply: UInt8 = 0x23
    static let batteryNotify: UInt8 = 0x25
    static let autoPowerOffGet: UInt8 = 0x26
    static let autoPowerOffReply: UInt8 = 0x27
    static let autoPowerOffSet: UInt8 = 0x28
    static let equalizerGet: UInt8 = 0x56
    static let equalizerReply: UInt8 = 0x57
    static let equalizerSet: UInt8 = 0x58
    static let ambientGet: UInt8 = 0x66
    static let ambientReply: UInt8 = 0x67
    static let ambientSet: UInt8 = 0x68
    static let generalSettingCapabilityGet: UInt8 = 0xd0
    static let generalSettingCapabilityReply: UInt8 = 0xd1
    static let generalSettingGet: UInt8 = 0xd6
    static let generalSettingReply: UInt8 = 0xd7
    static let dseeGet: UInt8 = 0xe6
    static let dseeReply: UInt8 = 0xe7
    static let dseeSet: UInt8 = 0xe8
    static let buttonModeGet: UInt8 = 0xf6
    static let buttonModeReply: UInt8 = 0xf7
    static let buttonModeSet: UInt8 = 0xf8

    // Table 2, v2 (multipoint). Never send these as table 1.
    static let supportFunctionGet: UInt8 = 0x06
    static let supportFunctionReply: UInt8 = 0x07
    static let peripheralGet: UInt8 = 0x36
    static let peripheralReply: UInt8 = 0x37
    static let peripheralSet: UInt8 = 0x38
    static let peripheralNotify: UInt8 = 0x39
    static let peripheralSetExtended: UInt8 = 0x3c
    static let peripheralNotifyExtended: UInt8 = 0x3d
}

nonisolated enum SonySubtype {
    static let batterySingle: UInt8 = 0x00
    static let batteryDual: UInt8 = 0x09
    static let batteryCase: UInt8 = 0x0a
    static let ambientV2: UInt8 = 0x17
    static let ambientV1: UInt8 = 0x02
    static let adaptiveVolume: UInt8 = 0x0a
    static let speakToChat: UInt8 = 0x0c
    static let generalSettingSlots: ClosedRange<UInt8> = 0xd1...0xd4
    static let multipointSettingName = "MULTIPOINT_SETTING"

    // Peripheral inquired types (table 2).
    static let devicesClassic: UInt8 = 0x00
    static let sourceSwitch: UInt8 = 0x01
    static let devicesWithClassOfDevice: UInt8 = 0x02

    // Function ids in the table 2 support-function list.
    static let functionDevicesClassic: UInt8 = 0x30
    static let functionSourceSwitch: UInt8 = 0x31
    static let functionDevicesWithClassOfDevice: UInt8 = 0x32
    static let functionDevicesWithClassOfDeviceLE: UInt8 = 0x33
}

// MARK: - Requests

nonisolated enum SonyCommand {
    static let initDevice: [UInt8] = [SonyOpcode.initRequest, 0x00]
    static let firmware: [UInt8] = [SonyOpcode.firmwareGet, 0x02]
    static let codec: [UInt8] = [SonyOpcode.codecGet, 0x02]
    static let autoPowerOff: [UInt8] = [SonyOpcode.autoPowerOffGet, 0x05]
    static let equalizer: [UInt8] = [SonyOpcode.equalizerGet, 0x00]
    static let dsee: [UInt8] = [SonyOpcode.dseeGet, 0x01]
    static let ambientV2: [UInt8] = [SonyOpcode.ambientGet, SonySubtype.ambientV2]
    static let ambientV1: [UInt8] = [SonyOpcode.ambientGet, SonySubtype.ambientV1]
    static let supportFunctions: [UInt8] = [SonyOpcode.supportFunctionGet, 0x00]

    static func battery(_ type: UInt8) -> [UInt8] {
        [SonyOpcode.batteryGet, type]
    }

    static func buttonMode(_ subtype: UInt8) -> [UInt8] {
        [SonyOpcode.buttonModeGet, subtype]
    }

    static func setAutoPowerOff(_ option: AutoPowerOff) -> [UInt8] {
        [SonyOpcode.autoPowerOffSet, 0x05, option.code.0, option.code.1]
    }

    static func setEqualizerPreset(_ preset: EqualizerPreset) -> [UInt8] {
        [SonyOpcode.equalizerSet, 0x00, preset.rawValue, 0x00]
    }

    // 58 00 a0 06 <clear bass+10> <5 bands +10>, values clamped to -10...10.
    static func setCustomEqualizer(clearBass: Int, bands: [Int]) -> [UInt8] {
        let encode = { (value: Int) in UInt8(max(-10, min(10, value)) + 10) }
        var command: [UInt8] = [SonyOpcode.equalizerSet, 0x00, EqualizerPreset.manual.rawValue, 0x06, encode(clearBass)]
        for index in 0..<5 {
            command.append(encode(index < bands.count ? bands[index] : 0))
        }
        return command
    }

    static func setDsee(_ enabled: Bool) -> [UInt8] {
        [SonyOpcode.dseeSet, 0x01, enabled ? 0x01 : 0x00]
    }

    // The enable byte is inverted on v2: 00 = on.
    static func setSpeakToChat(_ enabled: Bool) -> [UInt8] {
        [SonyOpcode.buttonModeSet, SonySubtype.speakToChat, enabled ? 0x00 : 0x01, 0x01]
    }

    static func setAdaptiveVolume(_ enabled: Bool) -> [UInt8] {
        [SonyOpcode.buttonModeSet, SonySubtype.adaptiveVolume, enabled ? 0x00 : 0x01]
    }

    // v2: 68 17 01 <on> <0 = NC, 1 = ambient> <voice passthrough> <level, 1-based>
    static func setAmbientV2(enabled: Bool, ambient: Bool, focusOnVoice: Bool, level: Int) -> [UInt8] {
        [SonyOpcode.ambientSet, SonySubtype.ambientV2, 0x01, enabled ? 0x01 : 0x00, ambient ? 0x01 : 0x00,
         focusOnVoice ? 0x01 : 0x00, UInt8(clamping: max(level, 1))]
    }

    // v1: 68 02 <effect> 01 <dual/single> 01 <asm id> <level>. Level 0 = noise cancelling, -1 (0xff) = off,
    // at most 19 (the C++ client refused anything higher).
    static func setAmbientV1(enabled: Bool, focusOnVoice: Bool, level: Int) -> [UInt8] {
        let effect: UInt8 = enabled ? 0x11 : 0x00   // ADJUSTMENT_COMPLETION / OFF
        let asmLevel = enabled ? max(0, min(level, 19)) : -1
        let dualSingle: UInt8
        switch asmLevel {
        case 0:
            dualSingle = 0x02   // DUAL
        case 1:
            dualSingle = 0x01   // SINGLE
        default:
            dualSingle = 0x00   // OFF
        }
        return [SonyOpcode.ambientSet, SonySubtype.ambientV1, effect, 0x01, dualSingle, 0x01,
                focusOnVoice ? 0x01 : 0x00, UInt8(bitPattern: Int8(clamping: asmLevel))]
    }

    // MARK: Multipoint

    static func generalSettingCapability(slot: UInt8) -> [UInt8] {
        [SonyOpcode.generalSettingCapabilityGet, slot, 0x01]   // 01 = English names
    }

    static func generalSetting(slot: UInt8) -> [UInt8] {
        [SonyOpcode.generalSettingGet, slot]
    }

    static func peripheral(_ inquiredType: UInt8) -> [UInt8] {
        [SonyOpcode.peripheralGet, inquiredType]
    }

    // 3c 01 <17 ASCII address bytes, exactly as the headset reported them>
    static func switchPlayback(to address: String) -> [UInt8] {
        [SonyOpcode.peripheralSetExtended, SonySubtype.sourceSwitch] + Array(address.utf8)
    }

    // 38 01 <00 = fixed, 01 = switches freely>
    static func setPlaybackFixed(_ fixed: Bool) -> [UInt8] {
        [SonyOpcode.peripheralSet, SonySubtype.sourceSwitch, fixed ? 0x00 : 0x01]
    }
}

// MARK: - Replies

nonisolated enum SonyReply {
    static let bluetoothAddressLength = 17

    // 01 <type> <protocol version, 4 bytes> <table 1: 00 = yes> <table 2: 00 = yes>
    static func supportsTable2(initReply reply: [UInt8]) -> Bool {
        reply.count > 7 && reply[7] == 0x00
    }

    // 23 <type> <level> <charging>
    static func battery(_ reply: [UInt8]) -> (level: Int, charging: Bool)? {
        guard reply.count >= 4 else {
            return nil
        }
        return (Int(reply[2]), reply[3] == 0x01)
    }

    // 23 09 <left> <left charging> <right> <right charging>
    static func dualBattery(_ reply: [UInt8]) -> (left: Int, right: Int)? {
        guard reply.count >= 6 else {
            return nil
        }
        return (Int(reply[2]), Int(reply[4]))
    }

    // 57 00 <preset> [06 <clear bass+10> <5 bands +10>]
    static func equalizer(_ reply: [UInt8]) -> EqualizerState? {
        guard reply.count >= 3 else {
            return nil
        }
        var state = EqualizerState(preset: reply[2])
        if reply.count >= 10 {
            state.clearBass = Int(reply[4]) - 10
            state.bands = (5..<10).map { Int(reply[$0]) - 10 }
        }
        return state
    }

    // e7 01 <enabled>
    static func dsee(_ reply: [UInt8]) -> Bool? {
        reply.count >= 3 ? reply[2] != 0 : nil
    }

    // v2: 67 17 01 <on> <0 = NC, 1 = ambient> <voice> <level>
    static func ambientV2(_ reply: [UInt8]) -> AmbientReading? {
        guard reply.count >= 7 else {
            return nil
        }
        return AmbientReading(enabled: reply[3] != 0, ambient: reply[4] != 0, focusOnVoice: reply[5] != 0, level: Int(reply[6]))
    }

    // 05 02 <len?> <ascii version...>
    static func firmware(_ reply: [UInt8]) -> String? {
        guard reply.count > 3 else {
            return nil
        }
        return String(decoding: reply[3...], as: UTF8.self)
    }

    // 13 02 <codec>
    static func codec(_ reply: [UInt8]) -> String? {
        guard reply.count >= 3 else {
            return nil
        }
        switch reply[2] {
        case 0x01:
            return "SBC"
        case 0x02:
            return "AAC"
        case 0x10:
            return "LDAC"
        case 0x20:
            return "aptX"
        case 0x21:
            return "aptX HD"
        default:
            return nil
        }
    }

    // 27 05 <c0> <c1>
    static func autoPowerOff(_ reply: [UInt8]) -> AutoPowerOff? {
        guard reply.count >= 4 else {
            return nil
        }
        return AutoPowerOff.allCases.first { $0.code == (reply[2], reply[3]) } ?? .off
    }

    // f7 <subtype> <00 = enabled>
    static func buttonModeEnabled(_ reply: [UInt8]) -> Bool? {
        reply.count >= 3 ? reply[2] == 0x00 : nil
    }

    // 07 00 <n> (<function> <priority>) x n
    static func supportFunctions(_ reply: [UInt8]) -> Set<UInt8>? {
        guard reply.count >= 3 else {
            return nil
        }
        let count = Int(reply[2])
        var functions = Set<UInt8>()
        for index in 0..<count where 3 + index * 2 < reply.count {
            functions.insert(reply[3 + index * 2])
        }
        return functions
    }

    // 37/39 <type> <count> { <address, 17 ASCII> <slot> [<class of device, 3 bytes BE>] <name length> <name> } x count
    // <playback slot>. Returns nil on any length mismatch so a misread never reaches the UI.
    static func pairedDevices(_ reply: [UInt8], withClassOfDevice: Bool) -> [PairedDevice]? {
        guard reply.count >= 4 else {
            return nil
        }
        var position = 2
        let count = Int(reply[position])
        position += 1
        var devices = [PairedDevice]()
        for _ in 0..<count {
            let fixedLength = bluetoothAddressLength + 1 + (withClassOfDevice ? 3 : 0) + 1
            guard position + fixedLength <= reply.count else {
                return nil
            }
            let address = String(decoding: reply[position..<(position + bluetoothAddressLength)], as: UTF8.self)
            position += bluetoothAddressLength
            let slot = Int(reply[position])
            position += 1
            var classOfDevice: Int?
            if withClassOfDevice {
                classOfDevice = Int(reply[position]) << 16 | Int(reply[position + 1]) << 8 | Int(reply[position + 2])
                position += 3
            }
            let nameLength = Int(reply[position])
            position += 1
            guard position + nameLength <= reply.count else {
                return nil
            }
            let name = String(decoding: reply[position..<(position + nameLength)], as: UTF8.self)
            position += nameLength
            devices.append(PairedDevice(address: address, name: name, slot: slot, classOfDevice: classOfDevice, playback: false))
        }
        guard position + 1 == reply.count else {
            return nil
        }
        // The trailing byte is the slot (1/2) that holds playback, not an index into the list.
        let playbackSlot = Int(reply[position])
        for index in devices.indices {
            devices[index].playback = devices[index].slot != 0 && devices[index].slot == playbackSlot
        }
        return devices
    }

    // 37 01 <value>: 0 = playback fixed, 1 = switches freely.
    static func playbackFixed(_ reply: [UInt8]) -> Bool? {
        reply.count >= 3 ? reply[2] == 0x00 : nil
    }

    // d1 <slot> <00 = boolean> <format> <name length> <name> ...
    static func generalSettingName(_ reply: [UInt8]) -> String? {
        guard reply.count >= 5, reply[2] == 0x00 else {
            return nil
        }
        let length = Int(reply[4])
        guard 5 + length <= reply.count else {
            return nil
        }
        return String(decoding: reply[5..<(5 + length)], as: UTF8.self)
    }

    // d7 <slot> <00 = boolean> <00 = on, 01 = off>
    static func generalSettingEnabled(_ reply: [UInt8]) -> Bool? {
        guard reply.count >= 4, reply[2] == 0x00 else {
            return nil
        }
        return reply[3] == 0x00
    }

    // 3d 01 <result> <address>
    static func switchResult(_ notify: [UInt8]) -> SourceSwitchResult? {
        notify.count >= 3 ? SourceSwitchResult(code: notify[2]) : nil
    }

    // 39 01 <value> <result>
    static func fixResult(_ notify: [UInt8], requested value: UInt8) -> SourceSwitchResult? {
        if notify.count >= 4 {
            return SourceSwitchResult(code: notify[3])
        }
        if notify.count == 3 {
            return notify[2] == value ? .success : .failed
        }
        return nil
    }
}

nonisolated extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

nonisolated extension Array where Element == UInt8 {
    var hexString: String {
        Data(self).hexString
    }
}
