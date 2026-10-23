//
//  FakeHeadset.swift
//  In-memory transports for tests: a scripted one, and a stateful fake WH-1000XM5 built from real replies.
//

@testable import SonyBridge

@MainActor
class FakeTransport: MDRTransport {
    var isOpen = true
    var onReceive: (([UInt8]) -> Void)?
    var onClose: (() -> Void)?

    // Every frame the app wrote, decoded (ACKs included).
    private(set) var written: [MDRMessage] = []
    var commands: [MDRMessage] { written.filter { !$0.isAck } }

    // Return the replies for a command (payload + table); an ACK is always sent first.
    var replies: (MDRMessage) -> [(dataType: UInt8, payload: [UInt8])] = { _ in [] }
    var acknowledges = true

    func write(_ bytes: [UInt8]) throws {
        guard isOpen else {
            throw MDRError.notConnected
        }
        let message = try MDRFrame.decode(body: Array(bytes.dropFirst().dropLast()))
        written.append(message)
        guard !message.isAck else {
            return
        }
        var stream = [UInt8]()
        if acknowledges {
            stream += MDRFrame.encode([], dataType: MDRFrame.ack, sequence: 1 &- message.sequence)
        }
        for reply in replies(message) {
            stream += MDRFrame.encode(reply.payload, dataType: reply.dataType, sequence: 0)
        }
        deliver(stream)
    }

    // Delivered on a later main-actor turn, like real RFCOMM data.
    func deliver(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else {
            return
        }
        Task { @MainActor in
            self.onReceive?(bytes)
        }
    }

    func push(_ payload: [UInt8], table: CommandTable) {
        deliver(MDRFrame.encode(payload, dataType: table.dataType, sequence: 0))
    }

    func close() {
        isOpen = false
    }
}

// Answers like Fred's WH-1000XM5 (fw 2.5.1). Fixing and switching change its state; inCall makes it refuse
// both the way the real headset does.
@MainActor
final class FakeXM5: FakeTransport {
    struct Device {
        var address: String
        var name: String
        var slot: UInt8
        var classOfDevice: [UInt8]
    }

    var devices = [
        Device(address: XM5.workMac, name: "Fred's Work MacBook Pro", slot: 2, classOfDevice: [0x38, 0x01, 0x0c]),
        Device(address: XM5.iPhone, name: "Frederico's iPhone", slot: 1, classOfDevice: [0x7a, 0x02, 0x0c]),
        Device(address: XM5.nintendoSwitch, name: "Nintendo Switch 2", slot: 0, classOfDevice: [0xff, 0xff, 0xff])
    ]
    var playbackSlot: UInt8 = 2
    var fixed = true
    var inCall = false
    // Opcodes the fake ACKs but never answers (unsupported features, lost notifies).
    var unanswered: Set<UInt8> = []
    // Result code to refuse a switch with (e.g. 0x03, audio not connected), without refusing fixes.
    var switchRefusal: UInt8?

    // Set if a table 2 opcode (0x30-0x3f) ever goes out as table 1, where those are firmware-update commands.
    private(set) var sentFirmwareRangeOnTable1 = false

    override init() {
        super.init()
        replies = { [unowned self] message in self.answer(message) }
    }

    var deviceList: [UInt8] {
        var payload: [UInt8] = [0x37, 0x02, UInt8(devices.count)]
        for device in devices {
            payload += Array(device.address.utf8) + [device.slot] + device.classOfDevice
            payload += [UInt8(device.name.utf8.count)] + Array(device.name.utf8)
        }
        return payload + [playbackSlot]
    }

    private func answer(_ message: MDRMessage) -> [(dataType: UInt8, payload: [UInt8])] {
        let table1 = MDRFrame.dataMDR
        let table2 = MDRFrame.dataMDRNo2
        let payload = message.payload
        let command = payload[0]
        let subType = payload.count > 1 ? payload[1] : 0
        if message.dataType == table1 && (0x30...0x3f).contains(command) {
            sentFirmwareRangeOnTable1 = true
        }
        if unanswered.contains(command) {
            return []
        }
        switch (message.dataType, command, subType) {
        case (table1, 0x00, _):
            return [(table1, XM5.initReply)]
        case (table1, 0x22, 0x00):
            return [(table1, hex("23 00 46 00"))]
        case (table1, 0x56, _):
            return [(table1, hex("57 00 10 06 0a 0a 0a 0a 0a 0a"))]
        case (table1, 0xe6, _):
            return [(table1, hex("e7 01 00"))]
        case (table1, 0x66, 0x17):
            return [(table1, hex("67 17 01 01 00 00 01"))]
        case (table1, 0x04, _):
            return [(table1, hex("05 02 05") + Array("2.5.1".utf8))]
        case (table1, 0x12, _):
            return [(table1, hex("13 02 10"))]
        case (table1, 0x26, _):
            return [(table1, hex("27 05 10 00"))]
        case (table1, 0xf6, 0x0a):
            return [(table1, hex("f7 0a 01"))]
        case (table1, 0xf6, 0x0c):
            return [(table1, hex("f7 0c 00"))]
        case (table1, 0xd0, 0xd1):
            return [(table1, XM5.generalSettingD1)]
        case (table1, 0xd0, 0xd2):
            return [(table1, XM5.generalSettingD2)]
        case (table1, 0xd6, 0xd2):
            return [(table1, XM5.multipointOn)]
        case (table2, 0x06, _):
            return [(table2, XM5.supportFunctions)]
        case (table2, 0x36, 0x02):
            return [(table2, deviceList)]
        case (table2, 0x36, 0x01):
            return [(table2, [0x37, 0x01, fixed ? 0x00 : 0x01])]
        case (table2, 0x38, 0x01):
            if inCall {
                return [(table2, [0x39, 0x01, fixed ? 0x00 : 0x01, 0x02])]
            }
            fixed = payload[2] == 0x00
            return [(table2, [0x39, 0x01, payload[2], 0x00])]
        case (table2, 0x3c, 0x01):
            let address = String(decoding: payload[2...], as: UTF8.self)
            if inCall || switchRefusal != nil {
                return [(table2, [0x3d, 0x01, inCall ? 0x02 : switchRefusal ?? 0x01] + Array(address.utf8))]
            }
            if let device = devices.first(where: { $0.address == address && $0.slot != 0 }) {
                playbackSlot = device.slot
            }
            return [(table2, [0x3d, 0x01, 0x00] + Array(address.utf8))]
        default:
            return []
        }
    }
}
