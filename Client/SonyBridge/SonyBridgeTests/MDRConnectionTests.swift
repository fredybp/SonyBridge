//
//  MDRConnectionTests.swift
//  Request/response matching, ACKs, sequence numbers, timeouts and notification routing.
//

@testable import SonyBridge
import Testing

@MainActor
struct MDRConnectionTests {
    @Test
    func returnsTheMatchingReplyAndAcknowledgesIt() async throws {
        let transport = FakeTransport()
        transport.replies = { _ in [(MDRFrame.dataMDR, hex("23 00 50 00"))] }
        let connection = MDRConnection(transport: transport)

        let reply = try await connection.request(hex("22 00"), expect: 0x23, subType: 0x00)

        #expect(reply == hex("23 00 50 00"))
        await Task.yield()
        // The headset's data frame (sequence 0) is ACKed with sequence 1.
        #expect(transport.written.last == MDRMessage(dataType: MDRFrame.ack, sequence: 1, payload: []))
    }

    @Test
    func repliesOnTheOtherTableDoNotMatch() async throws {
        let transport = FakeTransport()
        // Same opcode on table 1 first: it must not satisfy a table 2 request.
        transport.replies = { _ in [(MDRFrame.dataMDR, hex("37 02 00 00")), (MDRFrame.dataMDRNo2, hex("37 02 00 02"))] }
        let connection = MDRConnection(transport: transport)
        var notifications = [MDRMessage]()
        connection.onNotification = { notifications.append($0) }

        let reply = try await connection.request(hex("36 02"), table: .two, expect: 0x37, subType: 0x02)

        #expect(reply == hex("37 02 00 02"))
        #expect(notifications.map(\.dataType) == [MDRFrame.dataMDR])
        #expect(transport.commands.first?.dataType == MDRFrame.dataMDRNo2)
    }

    @Test
    func timesOutWhenTheHeadsetDoesNotAnswer() async {
        let transport = FakeTransport()
        let connection = MDRConnection(transport: transport)

        await #expect(throws: MDRError.timeout) {
            try await connection.request(hex("f6 0a"), expect: 0xf7, timeout: .milliseconds(50))
        }
    }

    @Test
    func commandWaitsForTheAckAndTakesItsSequence() async throws {
        let transport = FakeTransport()
        let connection = MDRConnection(transport: transport)

        try await connection.command(hex("e8 01 01"))
        try await connection.command(hex("e8 01 00"))

        #expect(transport.commands.map(\.sequence) == [0, 1])
    }

    @Test
    func sequenceAlternatesEvenWhenAnAckIsLost() async throws {
        let transport = FakeTransport()
        transport.acknowledges = false
        let connection = MDRConnection(transport: transport)

        await #expect(throws: MDRError.timeout) {
            try await connection.command(hex("e8 01 01"), timeout: .milliseconds(50))
        }
        transport.acknowledges = true
        try await connection.command(hex("e8 01 00"))

        #expect(transport.commands.map(\.sequence) == [0, 1])
    }

    @Test
    func requestsAreSentOneAtATimeInOrder() async throws {
        let transport = FakeTransport()
        transport.replies = { message in [(MDRFrame.dataMDR, [message.payload[0] + 1, message.payload[1]])] }
        let connection = MDRConnection(transport: transport)

        async let first = connection.request(hex("56 00"), expect: 0x57)
        async let second = connection.request(hex("e6 01"), expect: 0xe7)
        let replies = try await [first, second]

        #expect(replies == [hex("57 00"), hex("e7 01")])
        #expect(transport.commands.map(\.payload) == [hex("56 00"), hex("e6 01")])
    }
}
