//
//  MDRFrame.swift
//  Sony's MDR framing: 3e | escape( type | seq | length u32 BE | payload | sum8 ) | 3c.
//

import Foundation

// The two command tables are separate command spaces: the same opcode means different things in each
// (in table 1, 0x30-0x3f are the firmware-update commands; in table 2 they are multipoint/peripheral).
nonisolated enum CommandTable: Sendable {
    case one
    case two

    var dataType: UInt8 {
        switch self {
        case .one:
            return MDRFrame.dataMDR
        case .two:
            return MDRFrame.dataMDRNo2
        }
    }
}

nonisolated struct MDRMessage: Equatable, Sendable {
    let dataType: UInt8
    let sequence: UInt8
    let payload: [UInt8]

    var isAck: Bool { dataType == MDRFrame.ack }
    var isData: Bool { dataType == MDRFrame.dataMDR || dataType == MDRFrame.dataMDRNo2 }
    var command: UInt8? { payload.first }
    var subType: UInt8? { payload.count > 1 ? payload[1] : nil }
}

nonisolated enum MDRError: LocalizedError, Equatable {
    case malformedFrame(String)
    case timeout
    case notConnected
    case transport(String)
    case unsupported(String)
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .malformedFrame(let reason):
            return "Malformed message from the headset: \(reason)"
        case .timeout:
            return "The headset didn't answer."
        case .notConnected:
            return "Not connected."
        case .transport(let reason):
            return reason
        case .unsupported(let reason):
            return reason
        case .refused(let reason):
            return reason
        }
    }
}

nonisolated enum MDRFrame {
    static let startMarker: UInt8 = 0x3e
    static let endMarker: UInt8 = 0x3c
    static let escapeMarker: UInt8 = 0x3d

    static let ack: UInt8 = 0x01
    static let dataMDR: UInt8 = 0x0c
    static let dataMDRNo2: UInt8 = 0x0e

    static func encode(_ payload: [UInt8], dataType: UInt8, sequence: UInt8) -> [UInt8] {
        let length = UInt32(payload.count)
        var body: [UInt8] = [dataType, sequence]
        body += [UInt8(length >> 24 & 0xff), UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff), UInt8(length & 0xff)]
        body += payload
        body.append(checksum(body))
        return [startMarker] + escape(body) + [endMarker]
    }

    // Decodes the bytes between the start and end markers (still escaped).
    static func decode(body escaped: [UInt8]) throws -> MDRMessage {
        let body = try unescape(escaped)
        guard body.count >= 7 else {
            throw MDRError.malformedFrame("shorter than the minimum frame")
        }
        let length = Int(body[2]) << 24 | Int(body[3]) << 16 | Int(body[4]) << 8 | Int(body[5])
        guard body.count >= 6 + length + 1 else {
            throw MDRError.malformedFrame("declared length exceeds the data")
        }
        guard body[6 + length] == checksum(Array(body[0..<(6 + length)])) else {
            throw MDRError.malformedFrame("bad checksum")
        }
        return MDRMessage(dataType: body[0], sequence: body[1], payload: Array(body[6..<(6 + length)]))
    }

    static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(UInt8(0)) { $0 &+ $1 }
    }

    // 3c -> 3d 2c, 3d -> 3d 2d, 3e -> 3d 2e
    static func escape(_ bytes: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        for byte in bytes {
            if byte == endMarker || byte == escapeMarker || byte == startMarker {
                out += [escapeMarker, byte - 0x10]
            } else {
                out.append(byte)
            }
        }
        return out
    }

    static func unescape(_ bytes: [UInt8]) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == escapeMarker {
                guard index + 1 < bytes.count else {
                    throw MDRError.malformedFrame("escape at the end of the frame")
                }
                let escaped = bytes[index + 1] &+ 0x10
                guard escaped == endMarker || escaped == escapeMarker || escaped == startMarker else {
                    throw MDRError.malformedFrame("unexpected escaped byte")
                }
                out.append(escaped)
                index += 2
            } else {
                out.append(byte)
                index += 1
            }
        }
        return out
    }
}

// Reassembles frames from RFCOMM reads, which can split a frame or carry several back to back.
nonisolated struct MDRFrameParser {
    private var buffer: [UInt8] = []

    // Returns every complete, valid frame received so far. Malformed frames are dropped.
    mutating func append(_ bytes: [UInt8]) -> [MDRMessage] {
        buffer += bytes
        var messages = [MDRMessage]()
        while true {
            guard let start = buffer.firstIndex(of: MDRFrame.startMarker) else {
                buffer.removeAll()
                break
            }
            if start > 0 {
                buffer.removeFirst(start)
            }
            guard let end = buffer.dropFirst().firstIndex(of: MDRFrame.endMarker) else {
                break
            }
            // Markers never appear escaped inside a frame, so a second start before the end means the
            // first one was a fragment: frame from the last start.
            let frameStart = buffer[..<end].lastIndex(of: MDRFrame.startMarker) ?? 0
            let body = Array(buffer[(frameStart + 1)..<end])
            buffer.removeFirst(end + 1)
            if let message = try? MDRFrame.decode(body: body) {
                messages.append(message)
            }
        }
        return messages
    }
}
