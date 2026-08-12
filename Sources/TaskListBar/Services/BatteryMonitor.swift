import Combine
import Foundation
import IOKit.ps

@MainActor
final class BatteryMonitor: ObservableObject {
    struct Status: Equatable {
        var percentage: Int?
        var isCharging: Bool
        var isPluggedIn: Bool
        var isPresent: Bool

        static let unavailable = Status(percentage: nil, isCharging: false, isPluggedIn: false, isPresent: false)
    }

    @Published private(set) var status: Status = .unavailable

    private var timer: Timer?
    private var powerObserver: CFRunLoopSource?

    func start() {
        refresh()
        installPowerSourceObserver()
        // Sparse backup poll — primary updates come from IOPS notification.
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        timer?.tolerance = 15
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let powerObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerObserver, .defaultMode)
            self.powerObserver = nil
        }
    }

    func refresh() {
        let next = Self.readStatus()
        if next != status {
            status = next
        }
    }

    private func installPowerSourceObserver() {
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in
                monitor.refresh()
            }
        }, context)?.takeRetainedValue() else {
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerObserver = source
    }

    nonisolated private static func readStatus() -> Status {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              !list.isEmpty
        else {
            return .unavailable
        }

        for source in list {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            let isPresent = (info[kIOPSIsPresentKey] as? Bool) ?? true
            guard isPresent else { continue }

            let percentage = info[kIOPSCurrentCapacityKey] as? Int
            let max = info[kIOPSMaxCapacityKey] as? Int
            let normalized: Int? = {
                guard let percentage else { return nil }
                if let max, max > 0, max != 100 {
                    return Int((Double(percentage) / Double(max) * 100).rounded())
                }
                return percentage
            }()

            let state = info[kIOPSPowerSourceStateKey] as? String
            let isPluggedIn = state == kIOPSACPowerValue
            let isCharging = (info[kIOPSIsChargingKey] as? Bool) ?? false

            return Status(
                percentage: normalized,
                isCharging: isCharging,
                isPluggedIn: isPluggedIn,
                isPresent: true
            )
        }

        return .unavailable
    }
}
