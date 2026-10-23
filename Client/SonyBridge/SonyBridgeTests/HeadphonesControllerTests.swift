//
//  HeadphonesControllerTests.swift
//  End-to-end flows against a fake WH-1000XM5: startup reads, multipoint switching and fixing, refusals
//  during a call, and the v1 safety rules.
//

@testable import SonyBridge
import Testing

@MainActor
struct HeadphonesControllerTests {
    private func connected(_ headset: FakeXM5, version: SonyProtocolVersion = .v2) async -> HeadphonesController {
        let controller = HeadphonesController()
        await controller.start(transport: headset, protocolVersion: version, name: "WH-1000XM5",
                               address: "AA:BB:CC:DD:EE:FF", hostAddress: XM5.workMac, polling: false)
        return controller
    }

    private func waitForWrites(_ controller: HeadphonesController) async {
        while controller.multipointBusy {
            await Task.yield()
        }
    }

    private func table2Writes(_ headset: FakeXM5) -> [[UInt8]] {
        headset.commands.filter { $0.dataType == MDRFrame.dataMDRNo2 && [0x38, 0x3c].contains($0.payload[0]) }.map(\.payload)
    }

    @Test
    func readsEverythingOnConnect() async {
        let headset = FakeXM5()
        let controller = await connected(headset)

        #expect(controller.battery?.level == 70)
        #expect(controller.equalizer?.preset == EqualizerPreset.bright.rawValue)
        #expect(controller.ambientMode == .noiseCancelling)
        #expect(controller.codec == "LDAC")
        #expect(controller.firmware == "2.5.1")
        #expect(controller.speakToChat == true)
        #expect(controller.adaptiveVolume == false)
        #expect(controller.autoPowerOff == .whenTakenOff)
        #expect(controller.pairedDevices?.count == 3)
        #expect(controller.playbackDevice?.address == XM5.workMac)
        #expect(controller.pinnedToThisMac)
        #expect(controller.multipointEnabled == true)
        #expect(controller.multipointDiagnostics.contains("T1 d0 d2 01 -> d1 d2"))
        #expect(!headset.sentFirmwareRangeOnTable1)
    }

    @Test
    func plainSwitchEndsUnfixed() async {
        let headset = FakeXM5()
        let controller = await connected(headset)
        let iPhone = controller.pairedDevices!.first { $0.address == XM5.iPhone }!

        controller.switchPlayback(to: iPhone, fix: false)
        await waitForWrites(controller)

        #expect(table2Writes(headset) == [SonyCommand.switchPlayback(to: XM5.iPhone), hex("38 01 01")])
        #expect(controller.playbackDevice?.address == XM5.iPhone)
        #expect(controller.playbackFixed == false)
        #expect(controller.errorMessage == nil)
    }

    @Test
    func switchAndFixUnfixesSwitchesThenFixes() async {
        let headset = FakeXM5()
        let controller = await connected(headset)
        let iPhone = controller.pairedDevices!.first { $0.address == XM5.iPhone }!

        controller.switchPlayback(to: iPhone, fix: true)
        await waitForWrites(controller)

        #expect(table2Writes(headset) == [hex("38 01 01"), SonyCommand.switchPlayback(to: XM5.iPhone), hex("38 01 00")])
        #expect(controller.playbackDevice?.address == XM5.iPhone)
        #expect(controller.playbackFixed == true)
        #expect(!controller.pinnedToThisMac)
    }

    @Test
    func pinToThisMacOnlyFixesWhenTheMacAlreadyPlays() async {
        let headset = FakeXM5()
        headset.fixed = false
        let controller = await connected(headset)

        controller.pinPlaybackToThisMac()
        await waitForWrites(controller)

        #expect(table2Writes(headset) == [hex("38 01 00")])
        #expect(controller.pinnedToThisMac)
    }

    @Test
    func refusedSwitchReFixesThePreviousDevice() async {
        let headset = FakeXM5()
        headset.switchRefusal = 0x03
        let controller = await connected(headset)
        let iPhone = controller.pairedDevices!.first { $0.address == XM5.iPhone }!

        controller.switchPlayback(to: iPhone, fix: true)
        await waitForWrites(controller)

        #expect(table2Writes(headset) == [hex("38 01 01"), SonyCommand.switchPlayback(to: XM5.iPhone), hex("38 01 00")])
        #expect(controller.errorMessage == SourceSwitchResult.audioNotConnected.message)
        #expect(controller.pinnedToThisMac)
    }

    @Test
    func unfixDuringACallIsRefusedAndNothingElseIsSent() async {
        let headset = FakeXM5()
        let controller = await connected(headset)
        let iPhone = controller.pairedDevices!.first { $0.address == XM5.iPhone }!
        headset.inCall = true

        controller.switchPlayback(to: iPhone, fix: true)
        await waitForWrites(controller)

        #expect(table2Writes(headset) == [hex("38 01 01")])
        #expect(controller.errorMessage == SourceSwitchResult.inCall.message)
        #expect(controller.pinnedToThisMac)
    }

    @Test
    func switchingToAPairedOnlyDeviceSendsNothing() async {
        let headset = FakeXM5()
        let controller = await connected(headset)
        let nintendo = controller.pairedDevices!.first { $0.address == XM5.nintendoSwitch }!

        controller.switchPlayback(to: nintendo, fix: false)
        await waitForWrites(controller)

        #expect(table2Writes(headset).isEmpty)
        #expect(controller.errorMessage == "That device isn't connected to the headset.")
    }

    @Test
    func deviceListNotificationUpdatesThePlaybackDevice() async {
        let headset = FakeXM5()
        let controller = await connected(headset)

        headset.playbackSlot = 1
        headset.push(headset.deviceList.replacingFirst(0x37, with: 0x39), table: .two)
        while controller.playbackDevice?.address != XM5.iPhone {
            await Task.yield()
        }

        #expect(controller.playbackDevice?.address == XM5.iPhone)
    }

    @Test
    func timedOutSwitchReFixesThePreviousDevice() async {
        let headset = FakeXM5()
        let controller = await connected(headset)
        controller.multipointWriteTimeout = .milliseconds(100)
        headset.unanswered = [0x3c]
        let iPhone = controller.pairedDevices!.first { $0.address == XM5.iPhone }!

        controller.switchPlayback(to: iPhone, fix: true)
        await waitForWrites(controller)

        #expect(table2Writes(headset) == [hex("38 01 01"), SonyCommand.switchPlayback(to: XM5.iPhone), hex("38 01 00")])
        #expect(controller.errorMessage == SourceSwitchResult.noConfirmation.message)
        #expect(controller.pinnedToThisMac)
    }

    @Test
    func ambientWritesMatchTheCppClient() async {
        let headset = FakeXM5()
        let controller = await connected(headset)
        func ambientWrites() -> [[UInt8]] {
            headset.commands.map(\.payload).filter { $0.first == 0x68 }
        }

        controller.setAmbientMode(.ambientSound)
        controller.setFocusOnVoice(true)
        controller.setAmbientMode(.off)
        controller.setAmbientMode(.noiseCancelling)
        while ambientWrites().count < 4 {
            await Task.yield()
        }

        // Off keeps the last mode's type, voice and level; noise cancelling sends level 1 and no voice.
        #expect(ambientWrites() == [hex("68 17 01 01 01 00 0a"), hex("68 17 01 01 01 01 0a"),
                                    hex("68 17 01 00 01 01 0a"), hex("68 17 01 01 00 00 01")])
    }

    @Test
    func writesWaitForTheirReadToBeAnswered() async {
        let headset = FakeXM5()
        headset.unanswered = [0x66, 0x56, 0xe6]
        let controller = await connected(headset)

        controller.setAmbientMode(.ambientSound)
        controller.setEqualizerPreset(.bassBoost)
        controller.setDsee(true)
        await Task.yield()

        #expect(!controller.ambientWritable)
        #expect(headset.commands.filter { [0x68, 0x58, 0xe8].contains($0.payload[0]) }.isEmpty)
    }

    @Test
    func noInitReplyMeansNoFollowUpReads() async {
        let headset = FakeXM5()
        headset.unanswered = [0x00]
        let controller = await connected(headset)
        await controller.refreshBattery()

        let opcodes = Set(headset.commands.map(\.payload[0]))
        #expect(opcodes.isDisjoint(with: [0x22, 0x56, 0xe6, 0x06, 0x36, 0xd0]))
        #expect(!controller.multipointLoading)
    }

    @Test
    func reconnectingStartsClean() async {
        let first = FakeXM5()
        let controller = HeadphonesController()
        let startup = Task {
            await controller.start(transport: first, protocolVersion: .v2, name: "WH-1000XM5", address: "AA:BB:CC:DD:EE:FF",
                                   hostAddress: XM5.workMac, polling: false)
        }
        // Disconnect while the startup reads are still running.
        await Task.yield()
        controller.disconnect()
        await startup.value

        let second = FakeXM5()
        await controller.start(transport: second, protocolVersion: .v2, name: "WH-1000XM5", address: "AA:BB:CC:DD:EE:FF",
                               hostAddress: XM5.workMac, polling: false)

        #expect(second.commands.contains { $0.payload.first == 0xd0 })
        #expect(controller.multipointEnabled == true)
        #expect(controller.isConnected)
    }

    @Test
    func lostLinkIsDetectedOnTheNextExchange() async {
        let headset = FakeXM5()
        let controller = await connected(headset)

        headset.isOpen = false
        await controller.refreshBattery()

        #expect(!controller.isConnected)
        #expect(controller.errorMessage == "Headphones disconnected.")
    }

    @Test
    func v1HeadsetsOnlyGetTheAmbientRead() async {
        let headset = FakeXM5()
        let controller = await connected(headset, version: .v1)
        await controller.refreshBattery()

        // 0x22 is POWER OFF on v1, and table 2 doesn't exist there.
        #expect(headset.commands.map(\.payload) == [hex("66 02")])
        #expect(controller.pairedDevices == nil)
    }
}

extension Array where Element == UInt8 {
    func replacingFirst(_ old: UInt8, with new: UInt8) -> [UInt8] {
        var copy = self
        if let index = copy.firstIndex(of: old) {
            copy[index] = new
        }
        return copy
    }
}
