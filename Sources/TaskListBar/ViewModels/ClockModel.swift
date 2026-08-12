import Combine
import Foundation

/// Isolated clock so the whole taskbar does not redraw every tick.
@MainActor
final class ClockModel: ObservableObject {
    @Published private(set) var now = Date()

    private var timer: Timer?

    func start() {
        now = Date()
        // Align to the next minute boundary, then tick every 30s as backup.
        let calendar = Calendar.current
        let nextMinute = calendar.nextDate(
            after: Date(),
            matching: DateComponents(second: 0),
            matchingPolicy: .nextTime
        ) ?? Date().addingTimeInterval(60)

        let delay = max(0.5, nextMinute.timeIntervalSinceNow)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
                self?.timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.tick()
                    }
                }
                self?.timer?.tolerance = 5
            }
        }
        timer?.tolerance = 0.5
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        now = Date()
    }
}
