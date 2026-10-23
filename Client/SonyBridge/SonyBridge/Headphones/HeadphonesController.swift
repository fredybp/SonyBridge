//
//  HeadphonesController.swift
//  The app's model: one connected headset, its state, and every command the UI can send.
//  Shared by the window and the menu-bar item.
//

import Foundation
import IOBluetooth
import Observation

@Observable
final class HeadphonesController {
    enum ConnectionState {
        case disconnected
        case connecting
        case connected
    }

    var state: ConnectionState = .disconnected
    var deviceName = ""
    var deviceAddress = ""
    var protocolVersion: SonyProtocolVersion?
    var errorMessage: String?
    var bluetoothDenied = false

    // Ambient sound / noise cancelling. On v2 the controls stay disabled until the headset answered the
    // ambient GET (ambientKnown); v1 never reads it back, so v1 is always writable.
    var ambientMode: AmbientMode = .off
    var ambientLevel = 10
    var focusOnVoice = false
    var ambientKnown = false

    // Status and sound (v2 only). nil = not read yet, or the headset doesn't support it; the matching SET
    // is only ever sent when the GET was answered.
    var battery: BatteryStatus?
    var equalizer: EqualizerState?
    var dsee: Bool?
    var firmware: String?
    var codec: String?
    var autoPowerOff: AutoPowerOff?
    var speakToChat: Bool?
    var adaptiveVolume: Bool?

    // Multipoint (see HeadphonesController+Multipoint.swift)
    var pairedDevices: [PairedDevice]?
    var playbackFixed: Bool?
    var multipointEnabled: Bool?
    var multipointLoaded = false
    var multipointBusy = false
    var refreshingMultipoint = false
    var multipointDiagnostics = ""
    var hostAddress = ""

    var isConnected: Bool { state == .connected }
    var isV2: Bool { protocolVersion == .v2 }
    var maxAmbientLevel: Int { isV2 ? 20 : 19 }
    var focusOnVoiceAvailable: Bool { ambientMode == .ambientSound && ambientLevel > 2 }
    var ambientWritable: Bool { isConnected && (!isV2 || ambientKnown) }

    @ObservationIgnored var connection: MDRConnection?
    // Bumped on every connect and disconnect; async work from an older connection stops at its next check.
    @ObservationIgnored var generation = 0
    @ObservationIgnored var initialized = false
    @ObservationIgnored var initReply: [UInt8] = []
    @ObservationIgnored var lastOnMode: AmbientMode = .noiseCancelling
    @ObservationIgnored var table2Functions: Set<UInt8>?
    @ObservationIgnored var multipointSlot: UInt8?
    @ObservationIgnored var multipointSlotSearched = false
    @ObservationIgnored var multipointDiscoveryLog = ""
    @ObservationIgnored var multipointWriteLog = ""
    @ObservationIgnored var multipointQueue: Task<Void, Never>?
    // Writes get longer than reads: the headset may push device-list notifications before it answers.
    @ObservationIgnored var multipointWriteTimeout: Duration = .seconds(5)
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var autoConnectTried = false
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private weak var transport: MDRTransport?

    func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation && isConnected
    }

    // MARK: - Connecting

    // The "Connect automatically" toggle on the connect screen (on by default).
    static let autoConnectDefaultsKey = "connectAutomatically"

    // On launch, if the toggle is on: connect quietly to a Sony headset macOS already has connected. Never
    // shows the permission prompt or the device picker, and stays quiet if no headset is there. Not when
    // hosting unit tests.
    func connectAutomatically() {
        guard !autoConnectTried, state == .disconnected else {
            return
        }
        autoConnectTried = true
        guard UserDefaults.standard.object(forKey: Self.autoConnectDefaultsKey) as? Bool ?? true,
              BluetoothPermission.isGranted,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        connect(interactive: false)
    }

    // interactive: may ask for Bluetooth permission and show the device picker, and reports when nothing is found.
    func connect(interactive: Bool = true) {
        guard state == .disconnected else {
            return
        }
        errorMessage = nil
        state = .connecting
        connectTask = Task {
            // Before any IOBluetooth call: those block the main thread while the permission prompt is up.
            bluetoothDenied = !(await BluetoothPermission.request())
            guard !bluetoothDenied, !Task.isCancelled else {
                state = .disconnected
                if bluetoothDenied {
                    errorMessage = "SonyBridge doesn't have Bluetooth access. Allow it in System Settings → Privacy & Security → Bluetooth."
                }
                return
            }
            // Let SwiftUI draw "Connecting…" before the modal picker can block the main thread.
            await Task.yield()
            guard let device = interactive ? HeadsetFinder.findHeadset() : HeadsetFinder.connectedHeadset() else {
                state = .disconnected
                return
            }
            do {
                let transport = try await RFCOMMTransport.open(device: device)
                guard !Task.isCancelled else {
                    transport.close()
                    return
                }
                await start(transport: transport, protocolVersion: transport.protocolVersion,
                            name: device.nameOrAddress ?? "Headphones",
                            address: HeadsetFinder.normalizedAddress(device.addressString ?? ""),
                            hostAddress: HeadsetFinder.hostAddress)
            } catch {
                state = .disconnected
                errorMessage = error.localizedDescription
            }
        }
    }

    // Everything after the link is up. Separate from connect() so tests can drive it with a fake transport.
    func start(transport: MDRTransport, protocolVersion: SonyProtocolVersion, name: String, address: String,
               hostAddress: String, polling: Bool = true) async {
        reset()
        generation += 1
        let connection = MDRConnection(transport: transport)
        connection.onNotification = { [weak self] message in
            self?.handleNotification(message)
        }
        transport.onClose = { [weak self] in
            self?.handleLinkLost()
        }
        self.transport = transport
        self.connection = connection
        self.protocolVersion = protocolVersion
        self.deviceName = name
        self.deviceAddress = address
        self.hostAddress = hostAddress
        state = .connected
        // The link can close between opening and wiring up onClose.
        guard transport.isOpen else {
            handleLinkLost()
            return
        }

        await readInitialState(generation)
        if polling && isCurrent(generation) {
            startPolling()
        }
    }

    func disconnect() {
        generation += 1
        connectTask?.cancel()
        connectTask = nil
        pollingTask?.cancel()
        pollingTask = nil
        connection?.close()
        connection = nil
        reset()
    }

    func handleLinkLost() {
        guard state == .connected else {
            return
        }
        disconnect()
        errorMessage = "Headphones disconnected."
    }

    private func reset() {
        state = .disconnected
        deviceName = ""
        deviceAddress = ""
        protocolVersion = nil
        ambientMode = .off
        ambientLevel = 10
        focusOnVoice = false
        ambientKnown = false
        battery = nil
        equalizer = nil
        dsee = nil
        firmware = nil
        codec = nil
        autoPowerOff = nil
        speakToChat = nil
        adaptiveVolume = nil
        pairedDevices = nil
        playbackFixed = nil
        multipointEnabled = nil
        multipointLoaded = false
        multipointBusy = false
        refreshingMultipoint = false
        multipointDiagnostics = ""
        initialized = false
        initReply = []
        lastOnMode = .noiseCancelling
        table2Functions = nil
        multipointSlot = nil
        multipointSlotSearched = false
        multipointDiscoveryLog = ""
        multipointWriteLog = ""
        multipointQueue = nil
    }

    // MARK: - Reading

    // CRITICAL: on v1 only the ambient state is read. Opcode 0x22 is battery on v2 but POWER OFF on v1, and
    // a v1 headset still needs some valid traffic right after connect or it drops the link, so the
    // read-only ambient GET is that traffic.
    private func readInitialState(_ generation: Int) async {
        guard isV2 else {
            await refreshAmbient()
            return
        }
        // Like the C++ client: no answer to the init handshake, no battery/EQ/DSEE/multipoint reads.
        let reply = (try? await request(SonyCommand.initDevice, expect: SonyOpcode.initReply)) ?? []
        guard isCurrent(generation) else {
            return
        }
        initReply = reply
        initialized = !reply.isEmpty
        if initialized {
            await refreshBattery()
            guard isCurrent(generation) else { return }
            await refreshEqualizer()
            guard isCurrent(generation) else { return }
            await refreshDsee()
            guard isCurrent(generation) else { return }
        }
        await refreshAmbient()
        guard isCurrent(generation) else { return }
        // With the fast reads, so the playback device shows up with the battery and not after the probes.
        await readMultipoint()
        guard isCurrent(generation) else { return }
        await probeOptionalFeatures(generation)
    }

    func refreshBattery() async {
        guard isV2, initialized else {
            return
        }
        let generation = self.generation
        let singleReply = await read(SonyCommand.battery(SonySubtype.batterySingle), SonyOpcode.batteryReply, SonySubtype.batterySingle)
        guard isCurrent(generation) else { return }
        if let single = SonyReply.battery(singleReply) {
            battery = BatteryStatus(level: single.level, charging: single.charging)
            return
        }
        // TWS earbuds: left/right and the case.
        let dualReply = await read(SonyCommand.battery(SonySubtype.batteryDual), SonyOpcode.batteryReply, SonySubtype.batteryDual)
        let caseReply = await read(SonyCommand.battery(SonySubtype.batteryCase), SonyOpcode.batteryReply, SonySubtype.batteryCase)
        guard isCurrent(generation), let dual = SonyReply.dualBattery(dualReply) else {
            return
        }
        battery = BatteryStatus(level: min(dual.left, dual.right), charging: false, left: dual.left, right: dual.right,
                                caseLevel: SonyReply.battery(caseReply)?.level)
    }

    func refreshEqualizer() async {
        guard isV2, initialized else {
            return
        }
        let generation = self.generation
        let reply = await read(SonyCommand.equalizer, SonyOpcode.equalizerReply)
        guard isCurrent(generation), let state = SonyReply.equalizer(reply) else {
            return
        }
        equalizer = EqualizerState(preset: state.preset,
                                   clearBass: state.clearBass ?? equalizer?.clearBass ?? 0,
                                   bands: state.bands ?? equalizer?.bands ?? [0, 0, 0, 0, 0])
    }

    func refreshDsee() async {
        guard isV2, initialized else {
            return
        }
        let generation = self.generation
        let reply = await read(SonyCommand.dsee, SonyOpcode.dseeReply)
        guard isCurrent(generation) else { return }
        dsee = SonyReply.dsee(reply) ?? dsee
    }

    func refreshAmbient() async {
        guard isV2 else {
            // v1: the reply layout is unverified, so it is read only to keep the link alive and drained, never
            // parsed back into state (doing so snapped Ambient back to Noise Cancelling on the WH-1000XM4).
            _ = await read(SonyCommand.ambientV1, SonyOpcode.ambientReply)
            return
        }
        let generation = self.generation
        let reply = await read(SonyCommand.ambientV2, SonyOpcode.ambientReply)
        guard isCurrent(generation), let reading = SonyReply.ambientV2(reply) else {
            return
        }
        if !reading.enabled {
            ambientMode = .off
        } else if reading.ambient {
            ambientMode = .ambientSound
        } else {
            ambientMode = .noiseCancelling
        }
        if reading.enabled {
            lastOnMode = ambientMode
        }
        if reading.ambient && reading.level > 0 {
            ambientLevel = min(reading.level, maxAmbientLevel)
        }
        focusOnVoice = reading.focusOnVoice
        ambientKnown = true
    }

    // Each probe is a GET; a feature is only offered if the headset answers it, so its SET is never sent
    // blindly (that is how the WH-1000XM4 got powered off).
    private func probeOptionalFeatures(_ generation: Int) async {
        let firmwareReply = await read(SonyCommand.firmware, SonyOpcode.firmwareReply)
        let codecReply = await read(SonyCommand.codec, SonyOpcode.codecReply)
        let autoPowerOffReply = await read(SonyCommand.autoPowerOff, SonyOpcode.autoPowerOffReply)
        let adaptiveVolumeReply = await read(SonyCommand.buttonMode(SonySubtype.adaptiveVolume), SonyOpcode.buttonModeReply,
                                             SonySubtype.adaptiveVolume)
        let speakToChatReply = await read(SonyCommand.buttonMode(SonySubtype.speakToChat), SonyOpcode.buttonModeReply,
                                          SonySubtype.speakToChat)
        guard isCurrent(generation) else {
            return
        }
        firmware = SonyReply.firmware(firmwareReply)
        codec = SonyReply.codec(codecReply)
        autoPowerOff = SonyReply.autoPowerOff(autoPowerOffReply)
        adaptiveVolume = SonyReply.buttonModeEnabled(adaptiveVolumeReply)
        speakToChat = SonyReply.buttonModeEnabled(speakToChatReply)
    }

    // MARK: - Polling and notifications

    // Every 2 s: link check and ambient state (the headset's button changes it). Every 10 s: which device
    // has playback. Every 30 s: battery. Notifications usually beat the polls; the polls are the fallback.
    private func startPolling() {
        pollingTask?.cancel()
        let generation = self.generation
        pollingTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.isCurrent(generation), !Task.isCancelled else {
                    return
                }
                if self.transport?.isOpen != true {
                    self.handleLinkLost()
                    return
                }
                tick += 1
                await self.refreshAmbient()
                if tick % 5 == 0, self.pairedDevices != nil, !self.multipointBusy {
                    await self.readMultipoint()
                }
                if tick % 15 == 0 {
                    await self.refreshBattery()
                }
            }
        }
    }

    private func handleNotification(_ message: MDRMessage) {
        guard isV2 else {
            return
        }
        let payload = message.payload
        switch (message.dataType, message.command) {
        case (MDRFrame.dataMDR, SonyOpcode.batteryNotify):
            // Same layout as the battery reply.
            if message.subType == SonySubtype.batterySingle, let single = SonyReply.battery(payload) {
                battery = BatteryStatus(level: single.level, charging: single.charging)
            }
        case (MDRFrame.dataMDRNo2, SonyOpcode.peripheralNotify):
            handlePeripheralNotification(payload)
        default:
            break
        }
    }

    // MARK: - Plumbing

    func request(_ payload: [UInt8], table: CommandTable = .one, expect command: UInt8, subType: UInt8? = nil,
                 timeout: Duration = MDRConnection.defaultTimeout) async throws -> [UInt8] {
        guard let connection else {
            throw MDRError.notConnected
        }
        do {
            return try await connection.request(payload, table: table, expect: command, subType: subType, timeout: timeout)
        } catch {
            noteFailure(of: connection)
            throw error
        }
    }

    // A best-effort GET: empty on timeout or when the headset doesn't support it.
    func read(_ payload: [UInt8], _ command: UInt8, _ subType: UInt8? = nil, table: CommandTable = .one) async -> [UInt8] {
        (try? await request(payload, table: table, expect: command, subType: subType)) ?? []
    }

    // SET that waits for the ACK; failures land in errorMessage.
    func send(_ payload: [UInt8], table: CommandTable = .one) async {
        guard let connection else {
            errorMessage = MDRError.notConnected.localizedDescription
            return
        }
        do {
            try await connection.command(payload, table: table)
        } catch {
            noteFailure(of: connection)
            if connection === self.connection {
                errorMessage = error.localizedDescription
            }
        }
    }

    // A failed exchange on a link that is no longer open means the headset is gone, even without a close callback.
    private func noteFailure(of connection: MDRConnection) {
        if connection === self.connection && !connection.isOpen {
            handleLinkLost()
        }
    }
}
