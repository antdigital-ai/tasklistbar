import Combine
import Foundation

/// Isolated clock so the whole taskbar does not redraw every tick.
@MainActor
final class ClockModel: ObservableObject {
    @Published private(set) var now = Date()
    @Published private(set) var trayText = ""
    @Published private(set) var weekdayText = ""
    @Published private(set) var dayText = ""
    @Published private(set) var timeText = ""

    private var timer: Timer?

    private static let trayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEE d, HH:mm"
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let helpFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE HH:mm"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter
    }()

    func start() {
        refreshTexts(Date())
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
                self?.timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.tick()
                    }
                }
                self?.timer?.tolerance = 10
            }
        }
        timer?.tolerance = 0.5
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func helpText(for date: Date = Date()) -> String {
        Self.helpFormatter.string(from: date) + "（点击查看日程、节假日和放假安排）"
    }

    func monthTitle(for date: Date) -> String {
        Self.monthFormatter.string(from: date)
    }

    private func tick() {
        refreshTexts(Date())
    }

    private func refreshTexts(_ date: Date) {
        now = date
        trayText = Self.trayFormatter.string(from: date)
        weekdayText = Self.weekdayFormatter.string(from: date)
        dayText = Self.dayFormatter.string(from: date)
        timeText = Self.timeFormatter.string(from: date)
    }
}
