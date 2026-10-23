//
//  RFCOMMTransport.swift
//  The byte pipe to the headset: an IOBluetooth RFCOMM channel to Sony's vendor SPP service.
//

import Foundation
import IOBluetooth
import IOBluetoothUI

protocol MDRTransport: AnyObject {
    var isOpen: Bool { get }
    var onReceive: (([UInt8]) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    func write(_ bytes: [UInt8]) throws
    func close()
}

final class RFCOMMTransport: NSObject, MDRTransport, IOBluetoothRFCOMMChannelDelegate {
    // Sony's vendor service; the generation is decided by which UUID the headset advertises.
    private static let serviceV1: [UInt8] = [0x96, 0xcc, 0x20, 0x3e, 0x50, 0x68, 0x46, 0xad,
                                             0xb3, 0x2d, 0xe3, 0x16, 0xf5, 0xe0, 0x69, 0xba]
    private static let serviceV2: [UInt8] = [0x95, 0x6c, 0x7b, 0x26, 0xd4, 0x9a, 0x4b, 0xa8,
                                             0xb0, 0x3f, 0xb1, 0x7d, 0x39, 0x3c, 0xb6, 0xe2]

    let protocolVersion: SonyProtocolVersion
    var onReceive: (([UInt8]) -> Void)?
    var onClose: (() -> Void)?

    private var channel: IOBluetoothRFCOMMChannel?
    private var openContinuation: CheckedContinuation<Void, Error>?

    var isOpen: Bool { channel?.isOpen() ?? false }

    private init(protocolVersion: SonyProtocolVersion) {
        self.protocolVersion = protocolVersion
    }

    // Opens the Sony service on a paired device, preferring v1 (the original UUID) like the C++ client.
    static func open(device: IOBluetoothDevice, timeout: Duration = .seconds(8)) async throws -> RFCOMMTransport {
        let candidates: [(SonyProtocolVersion, [UInt8])] = [(.v1, serviceV1), (.v2, serviceV2)]
        var found: (SonyProtocolVersion, IOBluetoothSDPServiceRecord)?
        for (version, bytes) in candidates {
            let uuid = bytes.withUnsafeBytes { IOBluetoothSDPUUID(bytes: $0.baseAddress, length: 16) }
            if let record = device.getServiceRecord(for: uuid) {
                found = (version, record)
                break
            }
        }
        guard let (version, record) = found else {
            throw MDRError.transport("Couldn't find Sony's service on this device. Is it a supported headset?")
        }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
            throw MDRError.transport("Found Sony's service, but it has no RFCOMM channel.")
        }
        if !device.isConnected() {
            device.openConnection()
        }

        let transport = RFCOMMTransport(protocolVersion: version)
        var channel: IOBluetoothRFCOMMChannel?
        guard device.openRFCOMMChannelAsync(&channel, withChannelID: channelID, delegate: transport) == kIOReturnSuccess,
              let channel else {
            throw MDRError.transport("Couldn't open the connection to the headset.")
        }
        transport.channel = channel
        try await transport.waitUntilOpen(timeout: timeout)
        return transport
    }

    private func waitUntilOpen(timeout: Duration) async throws {
        if isOpen {
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            openContinuation = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finishOpening(with: MDRError.transport("Connection timed out."))
            }
        }
    }

    private func finishOpening(with error: Error?) {
        guard let continuation = openContinuation else {
            return
        }
        openContinuation = nil
        if let error {
            close()
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    // Asynchronous so a stalled link can't block the main thread. IOBluetooth doesn't copy the data, so the
    // buffer lives until rfcommChannelWriteComplete hands it back as the refcon.
    func write(_ bytes: [UInt8]) throws {
        guard let channel, channel.isOpen(), !bytes.isEmpty else {
            throw MDRError.notConnected
        }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 1)
        bytes.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        let status = channel.writeAsync(buffer, length: UInt16(bytes.count), refcon: buffer)
        guard status == kIOReturnSuccess else {
            buffer.deallocate()
            throw MDRError.transport("Couldn't send to the headset (0x\(String(status, radix: 16))).")
        }
    }

    func close() {
        channel?.setDelegate(nil)
        channel?.close()
        channel = nil
    }

    // MARK: IOBluetoothRFCOMMChannelDelegate

    // IOBluetooth calls back on the run loop that opened the channel, which is the main one.
    nonisolated func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                                       data dataPointer: UnsafeMutableRawPointer!,
                                       length dataLength: Int) {
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        Self.onMain { $0.onReceive?(bytes) }(self)
    }

    nonisolated func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        Self.onMain { transport in
            transport.finishOpening(with: error == kIOReturnSuccess
                ? nil
                : MDRError.transport("Couldn't open the connection to the headset (0x\(String(error, radix: 16)))."))
        }(self)
    }

    nonisolated func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                                                refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        refcon?.deallocate()
    }

    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        Self.onMain { transport in
            transport.channel = nil
            transport.finishOpening(with: MDRError.transport("The headset closed the connection."))
            transport.onClose?()
        }(self)
    }

    // Runs on the main actor, synchronously when already on the main thread so received bytes keep their order.
    private nonisolated static func onMain(_ body: @escaping @MainActor (RFCOMMTransport) -> Void) -> (RFCOMMTransport) -> Void {
        { transport in
            if Thread.isMainThread {
                MainActor.assumeIsolated { body(transport) }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { body(transport) } }
            }
        }
    }
}

// MARK: - Finding the headset

enum HeadsetFinder {
    // Prefers a Sony headset macOS already has connected (Sound Connect's "My Device" behaviour); otherwise
    // shows the system Bluetooth picker. Returns nil if the user cancels the picker.
    static func findHeadset() -> IOBluetoothDevice? {
        if let connected = connectedHeadset() {
            return connected
        }
        guard let selector = IOBluetoothDeviceSelectorController.deviceSelector(),
              Int(selector.runModal()) == Int(kIOBluetoothUISuccess) else {
            return nil
        }
        return selector.getResults()?.last as? IOBluetoothDevice
    }

    // A Sony headset macOS already has connected, without any UI.
    static func connectedHeadset() -> IOBluetoothDevice? {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.first { $0.isConnected() && looksLikeSonyHeadset($0.name) }
    }

    static var hostAddress: String {
        normalizedAddress(IOBluetoothHostController.default()?.addressAsString() ?? "")
    }

    // IOBluetooth formats addresses as "aa-bb-cc-dd-ee-ff"; the headset reports "AA:BB:CC:DD:EE:FF".
    static func normalizedAddress(_ address: String) -> String {
        address.uppercased().replacingOccurrences(of: "-", with: ":")
    }

    private static func looksLikeSonyHeadset(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else {
            return false
        }
        return ["WH-", "WF-", "WI-", "MDR-", "XB", "LinkBuds", "ULT"].contains { name.contains($0) }
    }
}
