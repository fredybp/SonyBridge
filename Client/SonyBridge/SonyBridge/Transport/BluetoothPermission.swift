//
//  BluetoothPermission.swift
//  Asks for Bluetooth access without freezing the app. IOBluetooth calls block the calling thread while the
//  system permission prompt is up, so the prompt is raised through CoreBluetooth first, which answers
//  asynchronously, and IOBluetooth is only touched once access is decided.
//

import AppKit
import CoreBluetooth

enum BluetoothPermission {
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")

    // True if the app may use Bluetooth. Shows the system prompt (without blocking) when not decided yet.
    static func request() async -> Bool {
        switch CBManager.authorization {
        case .allowedAlways:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await PermissionPrompt().ask()
        @unknown default:
            return true
        }
    }

    static func openSettings() {
        if let settingsURL {
            NSWorkspace.shared.open(settingsURL)
        }
    }
}

// Creating a CBCentralManager raises the prompt; the delegate hears back once the user has answered.
private final class PermissionPrompt: NSObject, CBCentralManagerDelegate {
    private static var pending: PermissionPrompt?
    private var manager: CBCentralManager?
    private var continuation: CheckedContinuation<Bool, Never>?

    func ask() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            Self.pending = self
            manager = CBCentralManager(delegate: self, queue: .main)
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            finishIfDecided()
        }
    }

    private func finishIfDecided() {
        let authorization = CBManager.authorization
        guard authorization != .notDetermined, let continuation else {
            return
        }
        self.continuation = nil
        manager?.delegate = nil
        manager = nil
        Self.pending = nil
        continuation.resume(returning: authorization == .allowedAlways)
    }
}
