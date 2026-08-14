import AppKit
import Combine
import EventKit
import Foundation
import SwiftUI

struct CalendarDayItem: Identifiable, Hashable {
    enum Kind {
        case holiday
        case rest
        case workday
        case event
    }

    let id: String
    let title: String
    let kind: Kind
    let isAllDay: Bool
    let start: Date
    let end: Date
    let color: Color?
}

struct HolidaySpan: Identifiable, Hashable {
    let id: String
    let title: String
    let kind: CalendarDayItem.Kind
    let start: Date
    let end: Date

    var dateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        let startText = formatter.string(from: start)
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return startText
        }
        return "\(startText)–\(formatter.string(from: end))"
    }
}

@MainActor
final class CalendarStore: ObservableObject {
    @Published private(set) var itemsByDay: [Date: [CalendarDayItem]] = [:]
    @Published private(set) var canReadEvents = false
    @Published private(set) var needsPermission = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var holidaySourceURL: String?

    private let eventStore = EKEventStore()
    private let calendar = Calendar.current
    private var observer: NSObjectProtocol?
    private var loadedMonth: Date?
    private var arrangements: [Int: HolidayArrangement] = [:]
    private var fetchingYears = Set<Int>()
    private var lastFetchAttempt: [Int: Date] = [:]
    private static let requestedKey = "didRequestCalendarAccess"
    private var didRequestAccess = UserDefaults.standard.bool(forKey: CalendarStore.requestedKey)

    func start() {
        refreshAuthorization()
        let year = calendar.component(.year, from: Date())
        seedArrangement(year: year)
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: eventStore,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let month = self.loadedMonth else { return }
                    self.load(month: month)
                }
            }
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    func prepare() {
        refreshAuthorization()
        if needsPermission {
            requestAccess()
        } else if canReadEvents, let month = loadedMonth {
            load(month: month)
        }
    }

    func load(month: Date) {
        loadedMonth = month
        refreshAuthorization()

        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month
        let monthEnd = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: monthStart) ?? monthStart
        let rangeStart = calendar.date(byAdding: .day, value: -7, to: monthStart) ?? monthStart
        let rangeEnd = calendar.date(byAdding: .day, value: 14, to: monthEnd) ?? monthEnd

        var grouped: [Date: [CalendarDayItem]] = [:]
        let years = Set([
            calendar.component(.year, from: rangeStart),
            calendar.component(.year, from: rangeEnd)
        ])
        for year in years {
            seedArrangement(year: year)
            refreshArrangement(year: year)
        }

        var cursor = rangeStart
        while cursor <= rangeEnd {
            let key = calendar.startOfDay(for: cursor)
            let year = calendar.component(.year, from: cursor)
            let arrangement = arrangements[year]
            if let restName = arrangement?.restName(on: cursor, calendar: calendar) {
                grouped[key, default: []].append(
                    CalendarDayItem(
                        id: "rest-\(key.timeIntervalSince1970)-\(restName)",
                        title: "\(restName)放假",
                        kind: .rest,
                        isAllDay: true,
                        start: key,
                        end: calendar.date(byAdding: .day, value: 1, to: key) ?? key,
                        color: nil
                    )
                )
            } else if let holiday = ChineseHolidays.holiday(on: cursor, calendar: calendar) {
                grouped[key, default: []].append(
                    CalendarDayItem(
                        id: "holiday-\(key.timeIntervalSince1970)-\(holiday.name)",
                        title: holiday.name,
                        kind: .holiday,
                        isAllDay: true,
                        start: key,
                        end: calendar.date(byAdding: .day, value: 1, to: key) ?? key,
                        color: nil
                    )
                )
            }
            if let workName = arrangement?.workName(on: cursor, calendar: calendar) {
                grouped[key, default: []].append(
                    CalendarDayItem(
                        id: "work-\(key.timeIntervalSince1970)",
                        title: workName,
                        kind: .workday,
                        isAllDay: true,
                        start: key,
                        end: calendar.date(byAdding: .day, value: 1, to: key) ?? key,
                        color: nil
                    )
                )
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        if canReadEvents {
            let predicate = eventStore.predicateForEvents(withStart: rangeStart, end: rangeEnd, calendars: nil)
            let events = eventStore.events(matching: predicate)
            for event in events {
                let isHolidayCalendar = Self.isHolidayCalendar(event.calendar)
                let color = Color(nsColor: event.calendar.color)
                let title = event.title ?? "未命名日程"
                var day = calendar.startOfDay(for: event.startDate)
                let lastDay = calendar.startOfDay(for: event.endDate.addingTimeInterval(-1))
                while day <= lastDay {
                    if isHolidayCalendar,
                       grouped[day]?.contains(where: { $0.kind == .holiday && $0.title == title }) == true {
                        guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                        day = next
                        continue
                    }
                    grouped[day, default: []].append(
                        CalendarDayItem(
                            id: "\(event.eventIdentifier ?? "event")-\(day.timeIntervalSince1970)",
                            title: title,
                            kind: isHolidayCalendar ? .holiday : .event,
                            isAllDay: event.isAllDay,
                            start: event.startDate,
                            end: event.endDate,
                            color: color
                        )
                    )
                    guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                    day = next
                }
            }
        }

        for key in grouped.keys {
            grouped[key]?.sort { lhs, rhs in
                let order: [CalendarDayItem.Kind] = [.rest, .holiday, .workday, .event]
                let l = order.firstIndex(of: lhs.kind) ?? 9
                let r = order.firstIndex(of: rhs.kind) ?? 9
                if l != r { return l < r }
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return lhs.start < rhs.start
            }
        }
        itemsByDay = grouped
        if let year = years.max() {
            holidaySourceURL = arrangements[year]?.sourceURL
        }
    }

    func items(on day: Date) -> [CalendarDayItem] {
        itemsByDay[calendar.startOfDay(for: day)] ?? []
    }

    func hasHoliday(on day: Date) -> Bool {
        items(on: day).contains { $0.kind == .holiday || $0.kind == .rest }
    }

    func isRestDay(on day: Date) -> Bool {
        items(on: day).contains { $0.kind == .rest }
    }

    func isMakeupWorkday(on day: Date) -> Bool {
        items(on: day).contains { $0.kind == .workday }
    }

    func hasEvents(on day: Date) -> Bool {
        items(on: day).contains { $0.kind == .event }
    }

    func holidayName(on day: Date) -> String? {
        let dayItems = items(on: day)
        if let rest = dayItems.first(where: { $0.kind == .rest }) {
            return rest.title.replacingOccurrences(of: "放假", with: "")
        }
        return dayItems.first(where: { $0.kind == .holiday })?.title
    }

    func monthArrangements(for month: Date) -> [HolidaySpan] {
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month
        guard let monthEnd = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: monthStart) else {
            return []
        }

        var result: [HolidaySpan] = []
        var restName: String?
        var restStart: Date?
        var restEnd: Date?

        func flushRest() {
            guard let name = restName, let start = restStart, let end = restEnd else { return }
            result.append(
                HolidaySpan(
                    id: "span-\(start.timeIntervalSince1970)-\(name)",
                    title: "\(name)放假",
                    kind: .rest,
                    start: start,
                    end: end
                )
            )
            restName = nil
            restStart = nil
            restEnd = nil
        }

        var cursor = monthStart
        while cursor <= monthEnd {
            let dayItems = items(on: cursor)
            if let rest = dayItems.first(where: { $0.kind == .rest }) {
                let name = rest.title.replacingOccurrences(of: "放假", with: "")
                if restName == name,
                   let end = restEnd,
                   let next = calendar.date(byAdding: .day, value: 1, to: end),
                   calendar.isDate(cursor, inSameDayAs: next) {
                    restEnd = cursor
                } else {
                    flushRest()
                    restName = name
                    restStart = cursor
                    restEnd = cursor
                }
            } else {
                flushRest()
            }
            if let work = dayItems.first(where: { $0.kind == .workday }) {
                result.append(
                    HolidaySpan(
                        id: work.id,
                        title: work.title,
                        kind: .workday,
                        start: cursor,
                        end: cursor
                    )
                )
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        flushRest()
        return result.sorted { $0.start < $1.start }
    }

    func requestAccessFromUser() {
        didRequestAccess = false
        requestAccess()
    }

    func openPrivacySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars",
            "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?Privacy_Calendars"
        ]
        for raw in urls {
            if let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    private func requestAccess() {
        guard !didRequestAccess else { return }
        didRequestAccess = true
        UserDefaults.standard.set(true, forKey: Self.requestedKey)
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { [weak self] granted, _ in
                Task { @MainActor in
                    self?.handleAccessResult(granted)
                }
            }
        } else {
            eventStore.requestAccess(to: .event) { [weak self] granted, _ in
                Task { @MainActor in
                    self?.handleAccessResult(granted)
                }
            }
        }
    }

    private func handleAccessResult(_ granted: Bool) {
        refreshAuthorization()
        if granted, let month = loadedMonth {
            load(month: month)
        }
    }

    private func seedArrangement(year: Int) {
        guard arrangements[year] == nil else { return }
        if let cached = GovHolidayFetcher.cached(year: year) ?? GovHolidayFetcher.fallback(year: year) {
            arrangements[year] = cached
            holidaySourceURL = cached.sourceURL
        }
    }

    private func refreshArrangement(year: Int) {
        guard !fetchingYears.contains(year) else { return }
        if let last = lastFetchAttempt[year], last.timeIntervalSinceNow > -6 * 60 * 60 {
            return
        }
        if let cached = GovHolidayFetcher.cached(year: year),
           cached.fetchedAt.timeIntervalSinceNow > -6 * 60 * 60 {
            arrangements[year] = cached
            holidaySourceURL = cached.sourceURL
            lastFetchAttempt[year] = cached.fetchedAt
            return
        }
        fetchingYears.insert(year)
        lastFetchAttempt[year] = Date()
        Task { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await GovHolidayFetcher.fetch(year: year)
                self.arrangements[year] = fetched
                self.holidaySourceURL = fetched.sourceURL
                self.fetchingYears.remove(year)
                if let month = self.loadedMonth {
                    self.load(month: month)
                }
            } catch {
                self.fetchingYears.remove(year)
                AppLog.error("节假日拉取失败 \(year): \(error.localizedDescription)", category: "calendar")
            }
        }
    }

    private func refreshAuthorization() {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess:
            canReadEvents = true
            needsPermission = false
            permissionDenied = false
        case .notDetermined:
            canReadEvents = false
            needsPermission = true
            permissionDenied = false
        default:
            canReadEvents = false
            needsPermission = false
            permissionDenied = true
        }
    }

    private static func isHolidayCalendar(_ calendar: EKCalendar?) -> Bool {
        guard let title = calendar?.title.lowercased() else { return false }
        return title.contains("holiday")
            || title.contains("节假日")
            || title.contains("节日")
            || title.contains("中国大陆节假日")
    }
}
