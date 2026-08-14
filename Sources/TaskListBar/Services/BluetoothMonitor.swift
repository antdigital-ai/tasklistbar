import AppKit
import Combine
import Foundation
import IOBluetooth

@_silgen_name("IOBluetoothPreferenceGetControllerPowerState")
private func IOBluetoothPreferenceGetControllerPowerState() -> Int32

@_silgen_name("IOBluetoothPreferenceSetControllerPowerState")
private func IOBluetoothPreferenceSetControllerPowerState(_ state: Int32)

struct BluetoothDeviceItem: Identifiable, Equatable {
    let id: String
    let name: String
    let isConnected: Bool
}

@MainActor
final class BluetoothMonitor: NSObject, ObservableObject {
    @Published private(set) var isPoweredOn = false
    @Published private(set) var devices: [BluetoothDeviceItem] = []

    var connectedCount: Int { devices.filter(\.isConnected).count }
    var connectedNames: String {
        let names = devices.filter(\.isConnected).map(\.name)
        return names.isEmpty ? "未连接设备" : names.joined(separator: "、")
    }

    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    func start() {
        installObservers()
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let names = [
            "IOBluetoothHostControllerPoweredOnNotification",
            "IOBluetoothHostControllerPoweredOffNotification",
            "IOBluetoothDeviceConnectedNotification",
            "IOBluetoothDeviceDisconnectedNotification"
        ]
        for name in names {
            observers.append(
                center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.refresh()
                    }
                }
            )
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        timer?.tolerance = 15
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        observers.removeAll()
    }

    func refresh() {
        let powered = Self.readPoweredOn()
        if powered != isPoweredOn {
            isPoweredOn = powered
            AppLog.info(powered ? "蓝牙已开启" : "蓝牙已关闭", category: "bluetooth")
        }
        let next = powered ? Self.readDevices() : []
        if next != devices {
            devices = next
            if powered {
                AppLog.info("已连接 \(connectedCount) 台：\(connectedNames)", category: "bluetooth")
            }
        }
    }

    func togglePower() {
        setPoweredOn(!isPoweredOn)
    }

    func setPoweredOn(_ on: Bool) {
        IOBluetoothPreferenceSetControllerPowerState(on ? 1 : 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.refresh()
        }
    }

    func toggleDevice(_ item: BluetoothDeviceItem) {
        guard let device = Self.device(address: item.id) else { return }
        if item.isConnected {
            device.closeConnection()
        } else {
            device.openConnection()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.refresh()
        }
    }

    func openBluetoothSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.BluetoothSettings",
            "x-apple.systempreferences:com.apple.preference.bluetooth"
        ]
        for raw in urls {
            if let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    nonisolated private static func readPoweredOn() -> Bool {
        if IOBluetoothPreferenceGetControllerPowerState() != 0 {
            return true
        }
        guard let controller = IOBluetoothHostController.default() else { return false }
        return controller.powerState == kBluetoothHCIPowerStateON
    }

    nonisolated private static func readDevices() -> [BluetoothDeviceItem] {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        return paired.compactMap { device in
            let address = device.addressString ?? device.name ?? UUID().uuidString
            let name = device.nameOrAddress ?? "蓝牙设备"
            return BluetoothDeviceItem(
                id: address,
                name: name,
                isConnected: device.isConnected()
            )
        }
        .sorted { lhs, rhs in
            if lhs.isConnected != rhs.isConnected { return lhs.isConnected && !rhs.isConnected }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    nonisolated private static func device(address: String) -> IOBluetoothDevice? {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return nil }
        return paired.first { $0.addressString == address || $0.name == address }
    }
}
