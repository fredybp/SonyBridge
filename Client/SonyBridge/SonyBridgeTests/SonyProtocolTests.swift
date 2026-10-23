//
//  SonyProtocolTests.swift
//  Command bytes (checked against the C++ client's encoders) and reply parsing with real XM5 replies.
//

@testable import SonyBridge
import Testing

struct SonyCommandTests {
    @Test
    func ambientV2MatchesTheCppEncoder() {
        #expect(SonyCommand.setAmbientV2(enabled: true, ambient: false, focusOnVoice: false, level: 0) == hex("68 17 01 01 00 00 01"))
        #expect(SonyCommand.setAmbientV2(enabled: true, ambient: true, focusOnVoice: true, level: 10) == hex("68 17 01 01 01 01 0a"))
        #expect(SonyCommand.setAmbientV2(enabled: false, ambient: false, focusOnVoice: false, level: 5) == hex("68 17 01 00 00 00 05"))
    }

    @Test
    func ambientV1MatchesTheCppEncoder() {
        // Off: level -1 (0xff), dual/single OFF. NC: level 0, DUAL. Ambient 1: SINGLE. Ambient > 1: OFF.
        #expect(SonyCommand.setAmbientV1(enabled: false, focusOnVoice: false, level: 0) == hex("68 02 00 01 00 01 00 ff"))
        #expect(SonyCommand.setAmbientV1(enabled: true, focusOnVoice: false, level: 0) == hex("68 02 11 01 02 01 00 00"))
        #expect(SonyCommand.setAmbientV1(enabled: true, focusOnVoice: false, level: 1) == hex("68 02 11 01 01 01 00 01"))
        #expect(SonyCommand.setAmbientV1(enabled: true, focusOnVoice: true, level: 10) == hex("68 02 11 01 00 01 01 0a"))
        // v1 tops out at 19.
        #expect(SonyCommand.setAmbientV1(enabled: true, focusOnVoice: false, level: 20) == hex("68 02 11 01 00 01 00 13"))
    }

    @Test
    func equalizerCommands() {
        #expect(SonyCommand.setEqualizerPreset(.bassBoost) == hex("58 00 16 00"))
        // Values clamp to -10...10 and are sent +10; missing bands are 0.
        #expect(SonyCommand.setCustomEqualizer(clearBass: 12, bands: [-11, 0, 5]) == hex("58 00 a0 06 14 00 0a 0f 0a 0a"))
    }

    @Test
    func featureCommands() {
        #expect(SonyCommand.setDsee(true) == hex("e8 01 01"))
        #expect(SonyCommand.setSpeakToChat(true) == hex("f8 0c 00 01"))
        #expect(SonyCommand.setAdaptiveVolume(false) == hex("f8 0a 01"))
        #expect(SonyCommand.setAutoPowerOff(.off) == hex("28 05 11 00"))
        #expect(SonyCommand.setAutoPowerOff(.thirtyMinutes) == hex("28 05 01 01"))
    }

    @Test
    func multipointCommands() {
        #expect(SonyCommand.switchPlayback(to: XM5.iPhone) == hex("3c 01 39 43 3a 44 41 3a 41 38 3a 35 36 3a 30 31 3a 33 45"))
        #expect(SonyCommand.setPlaybackFixed(true) == hex("38 01 00"))
        #expect(SonyCommand.setPlaybackFixed(false) == hex("38 01 01"))
        #expect(SonyCommand.generalSettingCapability(slot: 0xd2) == hex("d0 d2 01"))
    }
}

struct SonyReplyTests {
    @Test
    func initReplyAdvertisesTable2() {
        #expect(SonyReply.supportsTable2(initReply: XM5.initReply))
        #expect(!SonyReply.supportsTable2(initReply: hex("01 00 03 00 20 16 00 01")))
        #expect(!SonyReply.supportsTable2(initReply: []))
    }

    @Test
    func supportFunctionsReadOnlyFunctionPositions() throws {
        let functions = try #require(SonyReply.supportFunctions(XM5.supportFunctions))
        #expect(functions == [0x41, 0x50, 0xf2, 0x32, 0x31, 0xf8])
        #expect(!functions.contains(0x30))   // 0x30 only appears as a priority there
    }

    @Test
    func xm5DeviceList() throws {
        let devices = try #require(SonyReply.pairedDevices(XM5.deviceList, withClassOfDevice: true))
        #expect(devices.map(\.name) == ["Fred's Work MacBook Pro", "Frederico's iPhone", "Nintendo Switch 2", "Freddy iPad", "Fred's MacBook Pro"])
        #expect(devices.map(\.slot) == [2, 1, 0, 0, 0])
        #expect(devices.map(\.address).prefix(2) == [XM5.workMac, XM5.iPhone])
        #expect(devices.map(\.classOfDevice) == [0x38010c, 0x7a020c, 0xffffff, 0xffffff, 0xffffff])
        // The trailing 02 is a slot, not an index: the Work MacBook (slot 2) plays, not the 3rd entry.
        #expect(devices.filter(\.playback).map(\.address) == [XM5.workMac])
    }

    @Test
    func truncatedDeviceListIsRejected() {
        #expect(SonyReply.pairedDevices(Array(XM5.deviceList.dropLast(5)), withClassOfDevice: true) == nil)
        #expect(SonyReply.pairedDevices(XM5.deviceList, withClassOfDevice: false) == nil)
    }

    @Test
    func multipointSettings() {
        #expect(SonyReply.playbackFixed(XM5.playbackFixed) == true)
        #expect(SonyReply.playbackFixed(hex("37 01 01")) == false)
        #expect(SonyReply.generalSettingName(XM5.generalSettingD1) == "TOUCH_PANEL_SETTING")
        #expect(SonyReply.generalSettingName(XM5.generalSettingD2) == "MULTIPOINT_SETTING")
        #expect(SonyReply.generalSettingEnabled(XM5.multipointOn) == true)
        #expect(SonyReply.generalSettingEnabled(hex("d7 d2 00 01")) == false)
    }

    @Test
    func writeResults() {
        #expect(SonyReply.switchResult(hex("3d 01 00") + Array(XM5.iPhone.utf8)) == .success)
        #expect(SonyReply.fixResult(hex("39 01 00 00"), requested: 0x00) == .success)
        // Captured on the XM5: unfixing during a call is refused.
        #expect(SonyReply.fixResult(hex("39 01 00 02"), requested: 0x01) == .inCall)
        #expect(SonyReply.fixResult(hex("39 01 01"), requested: 0x00) == .failed)
    }

    @Test
    func statusReplies() throws {
        #expect(SonyReply.battery(hex("23 00 50 01"))?.level == 80)
        #expect(SonyReply.battery(hex("23 00 50 01"))?.charging == true)
        #expect(SonyReply.dualBattery(hex("23 09 46 00 3c 00"))?.right == 60)
        let equalizer = try #require(SonyReply.equalizer(hex("57 00 a0 06 0a 00 05 0a 0f 14")))
        #expect(equalizer.preset == 0xa0)
        #expect(equalizer.clearBass == 0)
        #expect(equalizer.bands == [-10, -5, 0, 5, 10])
        #expect(SonyReply.ambientV2(hex("67 17 01 01 01 01 0c")) == AmbientReading(enabled: true, ambient: true, focusOnVoice: true, level: 12))
        #expect(SonyReply.codec(hex("13 02 10")) == "LDAC")
        #expect(SonyReply.autoPowerOff(hex("27 05 10 00")) == .whenTakenOff)
        #expect(SonyReply.buttonModeEnabled(hex("f7 0c 00")) == true)
        #expect(SonyReply.firmware(hex("05 02 05 32 2e 35 2e 31")) == "2.5.1")
    }
}
