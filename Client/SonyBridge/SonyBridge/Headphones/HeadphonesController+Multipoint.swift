//
//  HeadphonesController+Multipoint.swift
//  Multipoint: the paired-device list, which device has playback, fixing ("pinning") it, and switching it.
//  Everything here is v2 only and goes over command table 2, except the multipoint on/off general setting.
//  All multipoint work (polls, refreshes, writes) runs one task at a time, in order.
//

import Foundation

extension HeadphonesController {
    var playbackDevice: PairedDevice? {
        pairedDevices?.first { $0.playback }
    }

    var thisMac: PairedDevice? {
        pairedDevices?.first { $0.connected && isThisMac($0) }
    }

    var pinnedToThisMac: Bool {
        playbackFixed == true && thisMac?.playback == true
    }

    var canSwitchPlayback: Bool {
        playbackFixed != nil && table2Functions?.contains(SonySubtype.functionSourceSwitch) == true
    }

    // True from connect until the first multipoint read has finished.
    var multipointLoading: Bool {
        isConnected && isV2 && !multipointLoaded
    }

    func isThisMac(_ device: PairedDevice) -> Bool {
        !hostAddress.isEmpty && HeadsetFinder.normalizedAddress(device.address) == hostAddress
    }

    // MARK: - Reading (GETs only)

    func refreshMultipoint() {
        guard isConnected, isV2, !refreshingMultipoint else {
            return
        }
        refreshingMultipoint = true
        let generation = self.generation
        Task {
            await readMultipoint()
            if generation == self.generation {
                refreshingMultipoint = false
            }
        }
    }

    func readMultipoint() async {
        await enqueueMultipoint { [self] generation in
            await readMultipointNow(generation)
        }
    }

    // Runs multipoint work after whatever multipoint work is already queued, like the C++ client's serial queue.
    func enqueueMultipoint(_ work: @escaping @MainActor (Int) async -> Void) async {
        let generation = self.generation
        let previous = multipointQueue
        let task = Task { @MainActor in
            await previous?.value
            guard self.isCurrent(generation) else {
                return
            }
            await work(generation)
        }
        multipointQueue = task
        await task.value
    }

    // Table 2 reads run only if the init reply advertised table 2, and each read only if the headset
    // listed the matching function. Raw replies are logged for "Copy diagnostics".
    private func readMultipointNow(_ generation: Int) async {
        guard isV2, initialized else {
            multipointLoaded = true
            return
        }
        var log = ""
        var discovery = multipointDiscoveryLog

        if !SonyReply.supportsTable2(initReply: initReply) {
            log += "table 2 not advertised in the init reply; skipped the device list\n"
        } else {
            if table2Functions == nil {
                let reply = await logged(SonyCommand.supportFunctions, SonyOpcode.supportFunctionReply, 0x00, .two, into: &discovery)
                guard isCurrent(generation) else { return }
                table2Functions = SonyReply.supportFunctions(reply)
            }
            let functions = table2Functions ?? []
            let withClassOfDevice = functions.contains(SonySubtype.functionDevicesWithClassOfDevice)
                || functions.contains(SonySubtype.functionDevicesWithClassOfDeviceLE)
            if withClassOfDevice || functions.contains(SonySubtype.functionDevicesClassic) {
                let type = withClassOfDevice ? SonySubtype.devicesWithClassOfDevice : SonySubtype.devicesClassic
                let reply = await logged(SonyCommand.peripheral(type), SonyOpcode.peripheralReply, type, .two, into: &log)
                guard isCurrent(generation) else { return }
                if let devices = SonyReply.pairedDevices(reply, withClassOfDevice: withClassOfDevice) {
                    pairedDevices = devices
                } else if !reply.isEmpty {
                    log += "device list: unexpected layout\n"
                }
            }
            if functions.contains(SonySubtype.functionSourceSwitch) {
                let reply = await logged(SonyCommand.peripheral(SonySubtype.sourceSwitch), SonyOpcode.peripheralReply,
                                         SonySubtype.sourceSwitch, .two, into: &log)
                guard isCurrent(generation) else { return }
                playbackFixed = SonyReply.playbackFixed(reply) ?? playbackFixed
            }
        }

        // The multipoint on/off switch is a table 1 general setting whose slot (D1...D4) differs per model:
        // find it by name once per connection, then just read its value.
        if !multipointSlotSearched {
            for slot in SonySubtype.generalSettingSlots {
                let reply = await logged(SonyCommand.generalSettingCapability(slot: slot),
                                         SonyOpcode.generalSettingCapabilityReply, slot, .one, into: &discovery)
                guard isCurrent(generation) else { return }
                if SonyReply.generalSettingName(reply) == SonySubtype.multipointSettingName {
                    multipointSlot = slot
                    break
                }
            }
            multipointSlotSearched = true
        }
        if let slot = multipointSlot {
            let reply = await logged(SonyCommand.generalSetting(slot: slot), SonyOpcode.generalSettingReply, slot, .one, into: &log)
            guard isCurrent(generation) else { return }
            multipointEnabled = SonyReply.generalSettingEnabled(reply) ?? multipointEnabled
        }

        multipointDiscoveryLog = discovery
        multipointDiagnostics = "init " + (initReply.isEmpty ? "(no reply)" : initReply.hexString) + "\n"
            + discovery + multipointWriteLog + log
        multipointLoaded = true
    }

    private func logged(_ command: [UInt8], _ reply: UInt8, _ subType: UInt8, _ table: CommandTable,
                        into log: inout String) async -> [UInt8] {
        let label = table == .two ? "T2 " : "T1 "
        do {
            let payload = try await request(command, table: table, expect: reply, subType: subType)
            log += label + command.hexString + " -> " + payload.hexString + "\n"
            return payload
        } catch {
            log += label + command.hexString + " -> (" + error.localizedDescription + ")\n"
            return []
        }
    }

    // Notifications the headset pushes when the list or the fixed state changes (same layouts as the replies).
    func handlePeripheralNotification(_ payload: [UInt8]) {
        guard payload.count >= 2 else {
            return
        }
        switch payload[1] {
        case SonySubtype.devicesWithClassOfDevice, SonySubtype.devicesClassic:
            if let devices = SonyReply.pairedDevices(payload, withClassOfDevice: payload[1] == SonySubtype.devicesWithClassOfDevice) {
                pairedDevices = devices
            }
        case SonySubtype.sourceSwitch:
            if payload.count >= 3 {
                playbackFixed = payload[2] == 0x00
            }
        default:
            break
        }
    }

    // MARK: - Writes

    // Sound Connect's "Switch playback device and fix" (fix = true), or a plain switch that ends unfixed.
    // fix = true: unfix if fixed, switch (skipped if it already plays), fix - re-fixing the previous device
    // if the switch is refused or unconfirmed (e.g. mid-call). fix = false: switch, then unfix if it was
    // fixed, since the headset carries "fixed" across a switch.
    func switchPlayback(to device: PairedDevice, fix: Bool) {
        runMultipointWrite { [self] in
            let wasFixed = playbackFixed == true
            let alreadyPlaying = device.playback
            guard fix else {
                let result = try await switchPlaybackDevice(device)
                guard result == .success, wasFixed else {
                    return result
                }
                return try await setPlaybackFixedOnce(false)
            }
            var unfixed = false
            if wasFixed && !alreadyPlaying {
                let result = try await setPlaybackFixedOnce(false)
                guard result == .success else {
                    return result
                }
                unfixed = true
            }
            if !alreadyPlaying {
                let result = try await switchPlaybackDevice(device)
                guard result == .success else {
                    if unfixed {
                        _ = try? await setPlaybackFixedOnce(true)
                    }
                    return result
                }
            }
            return try await setPlaybackFixedOnce(true)
        }
    }

    func setPlaybackFixed(_ fixed: Bool) {
        runMultipointWrite { [self] in
            try await setPlaybackFixedOnce(fixed)
        }
    }

    func pinPlaybackToThisMac() {
        guard let thisMac else {
            return
        }
        switchPlayback(to: thisMac, fix: true)
    }

    private func runMultipointWrite(_ write: @escaping @MainActor () async throws -> SourceSwitchResult) {
        guard isConnected, isV2, initialized, !multipointBusy else {
            return
        }
        multipointBusy = true
        errorMessage = nil
        let generation = self.generation
        Task {
            await enqueueMultipoint { [self] generation in
                let message: String?
                do {
                    message = try await write().message
                } catch {
                    message = error.localizedDescription
                }
                guard isCurrent(generation) else { return }
                errorMessage = message
                await readMultipointNow(generation)
            }
            if generation == self.generation {
                multipointBusy = false
            }
        }
    }

    // 3c 01 <address> -> 3d 01 <result> <address>. Only to a device the headset lists as connected.
    private func switchPlaybackDevice(_ device: PairedDevice) async throws -> SourceSwitchResult {
        guard canSwitchPlayback else {
            throw MDRError.unsupported("This headset doesn't support switching the playback device.")
        }
        guard let target = pairedDevices?.first(where: { $0.connected && $0.address.caseInsensitiveCompare(device.address) == .orderedSame }),
              target.address.utf8.count == SonyReply.bluetoothAddressLength else {
            throw MDRError.unsupported("That device isn't connected to the headset.")
        }
        let command = SonyCommand.switchPlayback(to: target.address)
        return await loggedWrite(command, expect: SonyOpcode.peripheralNotifyExtended) {
            SonyReply.switchResult($0)
        }
    }

    // 38 01 <00 fixed / 01 free> -> 39 01 <value> <result>
    private func setPlaybackFixedOnce(_ fixed: Bool) async throws -> SourceSwitchResult {
        guard playbackFixed != nil else {
            throw MDRError.unsupported("This headset doesn't support fixing the playback device.")
        }
        let command = SonyCommand.setPlaybackFixed(fixed)
        return await loggedWrite(command, expect: SonyOpcode.peripheralNotify) {
            SonyReply.fixResult($0, requested: command[2])
        }
    }

    // A missing notify isn't fatal: it returns .noConfirmation, and the state is re-read afterwards.
    private func loggedWrite(_ command: [UInt8], expect notify: UInt8,
                             result parse: ([UInt8]) -> SourceSwitchResult?) async -> SourceSwitchResult {
        var line = "W T2 " + command.hexString + " -> "
        defer { multipointWriteLog += line + "\n" }
        do {
            let reply = try await request(command, table: .two, expect: notify, subType: SonySubtype.sourceSwitch,
                                          timeout: multipointWriteTimeout)
            line += reply.hexString
            return parse(reply) ?? .failed
        } catch {
            line += "(" + error.localizedDescription + ")"
            return .noConfirmation
        }
    }
}
