//
//  ModelQuirksTests.swift
//  Per-model protocol differences ported from the C++ client: per-earbud battery on TWS models, the
//  WH-1000XM6's noise-control read (66 19) and ten-band equalizer (56/58 04), and reading the bands back after
//  a preset switch.
//

@testable import SonyBridge
import Testing

struct ModelQuirksProtocolTests {
    @Test
    func earbudBatteryReplies() throws {
        // WF-1000XM5 (fw 6.1.0), both earbuds out: the reply is 8 bytes, longer than the documented 6.
        let both = try #require(SonyReply.dualBattery(hex("23 09 64 00 64 00 64 64")))
        #expect(both == EarbudBatteryReading(left: 100, leftCharging: false, right: 100, rightCharging: false))
        // Right earbud docked: its level reads 0, which means "not reporting", not empty.
        let docked = try #require(SonyReply.dualBattery(hex("23 09 64 00 00 00 64 64")))
        #expect(docked.left == 100)
        #expect(docked.right == nil)
        // Both docked and charging is still an answer.
        #expect(SonyReply.dualBattery(hex("23 09 00 01 00 01")) == EarbudBatteryReading(left: nil, leftCharging: true,
                                                                                          right: nil, rightCharging: true))
        #expect(SonyReply.dualBattery(hex("23 09 64 00")) == nil)
    }

    @Test
    func zeroedAmbientReplyIsNotState() {
        // The WH-1000XM6's answer to 66 17 in every mode: reading it as "off" snapped its UI back.
        #expect(SonyReply.ambientV2(hex("67 17 00 00 00 00 00")) == nil)
        // Its 66 19 answer: same first seven bytes, two trailing ones.
        #expect(SonyReply.ambientV2(hex("67 19 01 01 01 00 0a 00 00")) ==
                AmbientReading(enabled: true, ambient: true, focusOnVoice: false, level: 10))
    }

    @Test
    func tenBandEqualizer() throws {
        let state = try #require(SonyReply.tenBandEqualizer(hex("57 04 a0 0a 06 06 06 06 06 06 06 06 06 0c")))
        #expect(state.preset == EqualizerPreset.manual.rawValue)
        #expect(state.clearBass == nil)
        #expect(state.bands == [6, 6, 6, 6, 6, 6, 6, 6, 6, 12])
        #expect(SonyReply.tenBandEqualizer(hex("57 04 a0 0a 06 06")) == nil)
        #expect(SonyReply.tenBandEqualizer(hex("57 00 10 06 0a 0a 0a 0a 0a 0a")) == nil)

        // Same bytes as the C++ client: raw steps clamped to 0...12, no clear bass.
        #expect(SonyCommand.setTenBandEqualizer(bands: [0, 1, 2, 3, 4, 5, 6, 7, 8, 13]) ==
                hex("58 04 a0 0a 00 01 02 03 04 05 06 07 08 0c"))
        #expect(SonyCommand.setEqualizerPreset(.off, tenBand: true) == hex("58 04 00 00"))
        #expect(SonyCommand.tenBandEqualizer == hex("56 04"))
        #expect(SonyCommand.ambientXM6 == hex("66 19"))
    }
}

@MainActor
struct ModelQuirksControllerTests {
    // A FakeXM5 that answers `overrides` first, then falls back to its usual replies.
    private func headset(_ overrides: @escaping ([UInt8]) -> [UInt8]?) -> FakeXM5 {
        let headset = FakeXM5()
        let base = headset.replies
        headset.replies = { message in
            if let payload = overrides(message.payload) {
                return [(MDRFrame.dataMDR, payload)]
            }
            return base(message)
        }
        return headset
    }

    private func connected(_ headset: FakeXM5, name: String) async -> HeadphonesController {
        let controller = HeadphonesController()
        await controller.start(transport: headset, protocolVersion: .v2, name: name, address: "AA:BB:CC:DD:EE:FF",
                               hostAddress: XM5.workMac, polling: false)
        return controller
    }

    private func sent(_ headset: FakeXM5, _ payload: String) -> Bool {
        headset.commands.contains { $0.payload == hex(payload) }
    }

    @Test
    func earbudsReadPerEarbudBatteryBeforeTheSingleLevel() async throws {
        // The fake also answers 22 00 with a single level, which must not hide the per-earbud levels.
        let headset = headset { payload in
            switch payload {
            case hex("22 09"):
                return hex("23 09 64 00 00 00 64 64")   // right earbud docked
            case hex("22 0a"):
                return hex("23 0a 50 01 1e")
            default:
                return nil
            }
        }
        let controller = await connected(headset, name: "WF-1000XM5")

        let battery = try #require(controller.battery)
        #expect(battery.earbuds)
        #expect(battery.left == 100)
        #expect(battery.right == nil)
        #expect(battery.level == 100)
        #expect(battery.caseLevel == 80)
        #expect(battery.caseCharging)
        #expect(BatteryIcon.text(for: battery) == "L 100% · R in case")
        #expect(!sent(headset, "22 00"))
        #expect(!sent(headset, "22 01"))
    }

    @Test
    func earbudsInTheCaseKeepTheLastCaseLevel() async throws {
        var caseLevel: UInt8 = 0x50
        let headset = headset { payload in
            switch payload {
            case hex("22 09"):
                return hex("23 09 00 01 00 01")
            case hex("22 0a"):
                return [0x23, 0x0a, caseLevel, 0x00]
            default:
                return nil
            }
        }
        let controller = await connected(headset, name: "WF-1000XM4")
        // The case reports 0 while it isn't talking to the earbuds.
        caseLevel = 0
        await controller.refreshBattery()

        let battery = try #require(controller.battery)
        #expect(battery.level == nil)
        #expect(battery.charging)
        #expect(battery.caseLevel == 80)
        #expect(BatteryIcon.text(for: battery) == "In the case")
    }

    @Test
    func renamedEarbudsFallBackToThePerEarbudLayout() async throws {
        let headset = headset { payload in
            switch payload {
            case hex("22 00"):
                return hex("23 00")   // no usable single level
            case hex("22 09"):
                return hex("23 09 46 00 3c 01")
            case hex("22 0a"):
                return hex("23 0a 00 00")
            default:
                return nil
            }
        }
        let controller = await connected(headset, name: "Fred's buds")

        let battery = try #require(controller.battery)
        #expect(battery.earbuds)
        #expect(battery.level == 60)
        #expect(BatteryIcon.text(for: battery) == "L 70% · R 60% charging")
    }

    @Test
    func overEarHeadphonesStillReadOneLevel() async {
        let headset = FakeXM5()
        let controller = await connected(headset, name: "WH-1000XM5")

        #expect(controller.battery == BatteryStatus(level: 70, charging: false))
        #expect(!sent(headset, "22 09"))
    }

    @Test
    func xm6ReadsNoiseControlAndTheTenBandEqualizer() async throws {
        let headset = headset { payload in
            switch payload {
            case hex("66 17"):
                return hex("67 17 00 00 00 00 00")
            case hex("66 19"):
                return hex("67 19 01 01 01 00 0a 00 00")
            case hex("56 04"):
                return hex("57 04 a0 0a 06 06 06 06 06 06 06 06 06 0c")
            default:
                return nil
            }
        }
        let controller = await connected(headset, name: "WH-1000XM6")

        #expect(sent(headset, "66 19"))
        #expect(!sent(headset, "66 17"))
        #expect(!sent(headset, "56 00"))
        #expect(controller.ambientMode == .ambientSound)
        #expect(controller.ambientLevel == 10)
        #expect(controller.tenBandEqualizer)
        let equalizer = try #require(controller.equalizer)
        #expect(equalizer.preset == EqualizerPreset.manual.rawValue)
        #expect(equalizer.bands == [6, 6, 6, 6, 6, 6, 6, 6, 6, 12])

        controller.setCustomEqualizer(clearBass: 5, bands: [0, 1, 2, 3, 4, 5, 6, 7, 8, 13])
        controller.setEqualizerPreset(.off)
        while !sent(headset, "58 04 00 00") {
            await Task.yield()
        }

        #expect(sent(headset, "58 04 a0 0a 00 01 02 03 04 05 06 07 08 0c"))
        #expect(!headset.commands.contains { $0.payload.starts(with: [0x58, 0x00]) })
    }

    @Test
    func choosingManualRestoresTheCurveStoredOnTheHeadset() async throws {
        var preset: UInt8 = 0x10
        let headset = headset { payload in
            switch payload.prefix(2) {
            case [0x58, 0x00]:
                preset = payload[2]
                return nil
            case [0x56, 0x00]:
                // Bright's own curve, or the custom curve stored on the headset.
                return preset == 0xa0 ? hex("57 00 a0 06 0a 00 05 0a 0f 14") : hex("57 00 10 06 0a 0a 0a 0a 0a 0a")
            default:
                return nil
            }
        }
        let controller = await connected(headset, name: "WH-1000XM5")
        #expect(controller.equalizer?.bands == [0, 0, 0, 0, 0])

        controller.setEqualizerPreset(.manual)
        while controller.equalizer?.bands != [-10, -5, 0, 5, 10] {
            await Task.yield()
        }

        #expect(controller.equalizer?.preset == EqualizerPreset.manual.rawValue)
        #expect(controller.equalizer?.clearBass == 0)
        // Only the preset is written; the stale sliders never overwrite the stored curve.
        #expect(headset.commands.map(\.payload).filter { $0.first == 0x58 } == [hex("58 00 a0 00")])
    }
}
