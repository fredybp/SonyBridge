//
//  MDRFrameTests.swift
//  Framing, escaping, checksums and frame reassembly.
//

@testable import SonyBridge
import Testing

struct MDRFrameTests {
    @Test
    func encodesTable2DeviceListRequest() {
        let frame = MDRFrame.encode([0x36, 0x02], dataType: MDRFrame.dataMDRNo2, sequence: 0)
        #expect(frame == [0x3e, 0x0e, 0x00, 0x00, 0x00, 0x00, 0x02, 0x36, 0x02, 0x48, 0x3c])
    }

    @Test
    func escapesMarkerBytesInsideTheFrame() {
        // 0x3c is the switch-playback opcode and also the end marker.
        let frame = MDRFrame.encode([0x3c, 0x01], dataType: MDRFrame.dataMDRNo2, sequence: 0)
        #expect(Array(frame[7...8]) == [0x3d, 0x2c])
        #expect(frame.dropFirst().dropLast().contains(0x3c) == false)
    }

    @Test
    func roundTripsThroughDecode() throws {
        let payload: [UInt8] = [0x3c, 0x3d, 0x3e, 0x00, 0xff]
        let frame = MDRFrame.encode(payload, dataType: MDRFrame.dataMDR, sequence: 1)
        let message = try MDRFrame.decode(body: Array(frame.dropFirst().dropLast()))
        #expect(message == MDRMessage(dataType: MDRFrame.dataMDR, sequence: 1, payload: payload))
    }

    @Test
    func rejectsBadChecksum() {
        var frame = MDRFrame.encode([0x22, 0x00], dataType: MDRFrame.dataMDR, sequence: 0)
        frame[frame.count - 2] &+= 1
        #expect(throws: MDRError.self) {
            try MDRFrame.decode(body: Array(frame.dropFirst().dropLast()))
        }
    }

    @Test
    func decodesRealWF1000XM5SupportFunctionCapture() throws {
        // Captured by mos9527/SonyHeadphonesClient; contains an escaped 0x3d.
        let capture: [UInt8] = [0x3e, 0x0e, 0x01, 0x00, 0x00, 0x00, 0x19, 0x07, 0x00, 0x0b, 0x42, 0x3d, 0x2d, 0x53, 0xff,
                                0x54, 0xff, 0xf1, 0xff, 0x60, 0xff, 0x61, 0xff, 0xf2, 0xff, 0x63, 0xff, 0xf8, 0x30, 0x32,
                                0x04, 0x31, 0xff, 0xee, 0x3c]
        var parser = MDRFrameParser()
        let messages = parser.append(capture)
        #expect(messages.count == 1)
        #expect(messages.first?.payload.prefix(5) == [0x07, 0x00, 0x0b, 0x42, 0x3d])
    }

    @Test
    func parserHandlesSplitAndBackToBackFrames() {
        let first = MDRFrame.encode([], dataType: MDRFrame.ack, sequence: 1)
        let second = MDRFrame.encode([0x37, 0x01, 0x00], dataType: MDRFrame.dataMDRNo2, sequence: 0)
        let stream = [0x00, 0x42] + first + second
        var parser = MDRFrameParser()
        var messages = [MDRMessage]()
        // Feed it in awkward chunks.
        for chunk in stride(from: 0, to: stream.count, by: 3) {
            messages += parser.append(Array(stream[chunk..<min(chunk + 3, stream.count)]))
        }
        #expect(messages.map(\.dataType) == [MDRFrame.ack, MDRFrame.dataMDRNo2])
        #expect(messages.last?.payload == [0x37, 0x01, 0x00])
    }

    @Test
    func parserRecoversFromATruncatedFragment() {
        let full = MDRFrame.encode([0x23, 0x00, 0x50, 0x00], dataType: MDRFrame.dataMDR, sequence: 0)
        var parser = MDRFrameParser()
        let messages = parser.append([0x3e, 0x0c, 0x00] + full)
        #expect(messages.map(\.payload) == [[0x23, 0x00, 0x50, 0x00]])
    }
}
