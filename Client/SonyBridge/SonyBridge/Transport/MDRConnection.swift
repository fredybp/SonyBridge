//
//  MDRConnection.swift
//  Request/response over an MDR transport: sequence numbers, ACKs both ways, timeouts, and routing of
//  messages the headset sends on its own (notifications).
//

import Foundation

final class MDRConnection {
    nonisolated static let defaultTimeout: Duration = .milliseconds(2500)

    // Data frames that didn't answer a pending request: notifications, or late replies.
    var onNotification: ((MDRMessage) -> Void)?

    private let transport: MDRTransport
    private var parser = MDRFrameParser()
    private var sequence: UInt8 = 0

    private struct Waiter {
        let id: UInt64
        let matches: (MDRMessage) -> Bool
        let continuation: CheckedContinuation<MDRMessage, Error>
    }
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0
    private var queueTail: Task<Void, Never>?

    var isOpen: Bool { transport.isOpen }

    init(transport: MDRTransport) {
        self.transport = transport
        transport.onReceive = { [weak self] bytes in
            self?.receive(bytes)
        }
    }

    // Sends a command and returns the payload of the first reply on the same table whose opcode (and
    // subtype, when given) matches. Throws MDRError.timeout if none arrives.
    func request(_ payload: [UInt8], table: CommandTable = .one, expect command: UInt8, subType: UInt8? = nil,
                 timeout: Duration = defaultTimeout) async throws -> [UInt8] {
        let dataType = table.dataType
        return try await serialized {
            let reply = try await self.send(payload, dataType: dataType, timeout: timeout) { message in
                message.dataType == dataType && message.command == command && (subType == nil || message.subType == subType)
            }
            return reply.payload
        }
    }

    // Sends a command and waits only for the headset's ACK of it (sequence 1 - the one sent).
    func command(_ payload: [UInt8], table: CommandTable = .one, timeout: Duration = defaultTimeout) async throws {
        let dataType = table.dataType
        _ = try await serialized {
            let expected = 1 &- self.sequence
            return try await self.send(payload, dataType: dataType, timeout: timeout) { $0.isAck && $0.sequence == expected }
        }
    }

    func close() {
        transport.onReceive = nil
        transport.close()
        failAll(MDRError.notConnected)
    }

    // MARK: - Internals

    // One exchange at a time, in call order, like the single connector mutex of the C++ client.
    private func serialized<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = queueTail
        let task = Task { () async throws -> T in
            await previous?.value
            return try await operation()
        }
        queueTail = Task { _ = try? await task.value }
        return try await task.value
    }

    private func send(_ payload: [UInt8], dataType: UInt8, timeout: Duration,
                      until matches: @escaping (MDRMessage) -> Bool) async throws -> MDRMessage {
        let frame = MDRFrame.encode(payload, dataType: dataType, sequence: sequence)
        // Alternate even if the ACK gets lost, so the next frame isn't taken for a retransmission.
        sequence = 1 &- sequence
        let id = nextWaiterID
        nextWaiterID += 1
        return try await withCheckedThrowingContinuation { continuation in
            // Register before writing so a fast reply can't slip past.
            waiters.append(Waiter(id: id, matches: matches, continuation: continuation))
            do {
                try transport.write(frame)
            } catch {
                fail(id, error)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.fail(id, MDRError.timeout)
            }
        }
    }

    private func receive(_ bytes: [UInt8]) {
        for message in parser.append(bytes) {
            if message.isAck {
                sequence = message.sequence
            } else if message.isData {
                // The headset resends any data frame until it is ACKed, with the toggled sequence number.
                try? transport.write(MDRFrame.encode([], dataType: MDRFrame.ack, sequence: 1 &- message.sequence))
            }
            if let index = waiters.firstIndex(where: { $0.matches(message) }) {
                let waiter = waiters.remove(at: index)
                waiter.continuation.resume(returning: message)
            } else if message.isData {
                onNotification?(message)
            }
        }
    }

    private func fail(_ id: UInt64, _ error: Error) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiters.remove(at: index).continuation.resume(throwing: error)
    }

    private func failAll(_ error: Error) {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.continuation.resume(throwing: error) }
    }
}
