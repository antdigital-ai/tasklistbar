import AppKit
import SwiftUI

struct CalendarPanelRoot: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var viewModel: TaskbarViewModel

    var body: some View {
        CalendarPreviewView(
            clock: viewModel.clockModel,
            store: viewModel.calendarStore,
            weather: viewModel.weatherStore,
            viewModel: viewModel,
            isMonthExpanded: viewModel.isCalendarExpanded,
            isAgendaExpanded: viewModel.isCalendarAgendaExpanded
        )
        .environment(\.colorScheme, .dark)
        .environment(\.taskbarAccent, settings.accent)
        .environmentObject(settings)
        .animation(TaskbarMotion.hover, value: settings.accent)
    }
}

struct CalendarPreviewView: View {
    @ObservedObject var clock: ClockModel
    @ObservedObject var store: CalendarStore
    @ObservedObject var weather: WeatherStore
    @ObservedObject var viewModel: TaskbarViewModel
    let isMonthExpanded: Bool
    let isAgendaExpanded: Bool

    @State private var displayedMonth: Date = Date()
    @State private var selectedDay: Date = Date()
    @State private var monthForward = true

    private let calendar = Calendar.current
    private let weekendPink = Color(red: 1.00, green: 0.48, blue: 0.50)
    private let restMint = Color(red: 0.42, green: 0.98, blue: 0.70)
    private let todayInk = Color(red: 0.10, green: 0.34, blue: 0.68)

    enum Metrics {
        static let width: CGFloat = 448
        static let weatherWidth: CGFloat = 148
        static let weekHeight: CGFloat = 154
        static let monthHeight: CGFloat = 424
        static let agendaHeight: CGFloat = 240
        static let agendaPopupWidth: CGFloat = 400
        static let height: CGFloat = monthHeight
        static let corner: CGFloat = 18
        static let padX: CGFloat = 10
        static let dayCell: CGFloat = 48
        static let todayRing: CGFloat = 22
        static let monthRows = 6
        static let rowSpacing: CGFloat = 4

        static var weekGridHeight: CGFloat { dayCell }
        static var monthGridHeight: CGFloat {
            dayCell * CGFloat(monthRows) + rowSpacing * CGFloat(monthRows - 1)
        }

        static func panelHeight(monthExpanded: Bool, agendaExpanded: Bool) -> CGFloat {
            let base = monthExpanded ? monthHeight : weekHeight
            if agendaExpanded {
                return max(base, 300)
            }
            return base
        }
    }

    var body: some View {
        ZStack {
            weatherSky
            WeatherAtmosphereView(
                kind: heroKind,
                isNight: isNight,
                isActive: viewModel.isCalendarOpen
            )

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    hero
                    forecastCard
                }
            }

            if isAgendaExpanded {
                Color.black.opacity(0.32)
                    .contentShape(Rectangle())
                    .onTapGesture { collapseAgenda() }
                    .transition(.opacity)

                agendaPopup
                    .transition(
                        .scale(scale: 0.88, anchor: .center)
                            .combined(with: .opacity)
                    )
            }
        }
        .frame(
            width: Metrics.width,
            height: Metrics.panelHeight(
                monthExpanded: isMonthExpanded,
                agendaExpanded: isAgendaExpanded
            ),
            alignment: .top
        )
        .animation(TaskbarMotion.calendarExpand, value: isMonthExpanded)
        .animation(TaskbarMotion.calendarAgenda, value: isAgendaExpanded)
        .clipped()
        .animation(TaskbarMotion.calendarExpand, value: heroKind)
        .onAppear {
            displayedMonth = startOfMonth(for: clock.now)
            selectedDay = calendar.startOfDay(for: clock.now)
            store.load(month: displayedMonth)
        }
        .onChange(of: viewModel.isCalendarOpen) { open in
            guard open else { return }
            displayedMonth = startOfMonth(for: clock.now)
            selectedDay = calendar.startOfDay(for: clock.now)
            store.load(month: displayedMonth)
        }
        .onChange(of: displayedMonth) { month in
            store.load(month: month)
        }
        .onChange(of: viewModel.calendarNavigate.generation) { _ in
            let delta = viewModel.calendarNavigate.delta
            if delta != 0 {
                shift(by: delta)
            }
        }
        .onChange(of: isMonthExpanded) { expanded in
            if expanded {
                displayedMonth = startOfMonth(for: selectedDay)
            }
        }
    }

    private var isNight: Bool {
        let hour = calendar.component(.hour, from: clock.now)
        return hour < 6 || hour >= 19
    }

    private var heroKind: WeatherKind {
        weather.currentKind
            ?? weather.weather(on: clock.now)?.kind
            ?? .sunny
    }

    private var heroTemp: Int {
        weather.currentTemp
            ?? weather.weather(on: clock.now)?.high
            ?? 0
    }

    private var todayForecast: DayWeather? {
        weather.weather(on: clock.now)
    }

    private var cardFill: Color {
        Color.white.opacity((heroKind.isDarkSky || isNight) ? 0.08 : 0.1)
    }

    private var weatherSky: some View {
        let palette = heroKind.palette(night: isNight)
        return LinearGradient(
            colors: [palette.top, palette.bottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                expandCornerButton
                Text(weather.placeName ?? clock.weekdayText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            if weather.currentTemp != nil || todayForecast != nil {
                HStack(alignment: .top, spacing: 1) {
                    Text("\(heroTemp)")
                        .font(.system(size: 44, weight: .ultraLight, design: .rounded))
                        .monospacedDigit()
                    Text("°")
                        .font(.system(size: 22, weight: .ultraLight, design: .rounded))
                        .padding(.top, 6)
                }
                .foregroundStyle(.white)
                .padding(.top, 6)

                HStack(spacing: 5) {
                    weatherIcon(heroKind, night: isNight, size: 14)
                        .modifier(WeatherIconPulse(kind: heroKind, isNight: isNight))
                    Text(heroKind.label)
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.top, 2)

                if let todayForecast {
                    Text("最高 \(todayForecast.high)°  最低 \(todayForecast.low)°")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                        .monospacedDigit()
                        .padding(.top, 6)
                }
            } else {
                Text(clock.dayText)
                    .font(.system(size: 26, weight: .light, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.top, 8)
            }
        }
        .frame(width: Metrics.weatherWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 10)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(heroKind.label) \(heroTemp)度")
    }

    private var forecastCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            monthToolbar
            weekdayRow
            dayGrid
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardFill)
        )
        .padding(.top, 10)
        .padding(.trailing, 10)
        .padding(.bottom, 10)
        .padding(.leading, 4)
    }

    private var agendaPopup: some View {
        dayAgenda
            .frame(width: Metrics.agendaPopupWidth)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.black.opacity(0.28))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.4), radius: 22, y: 8)
    }

    private func weatherIcon(_ kind: WeatherKind, night: Bool, size: CGFloat) -> some View {
        Image(systemName: kind.symbolName(night: night))
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(kind.iconPrimary(night: night), kind.iconSecondary(night: night))
    }

    private var monthToolbar: some View {
        HStack(spacing: 8) {
            navButton(systemName: "chevron.left") {
                shift(by: -1)
            }

            Text(toolbarTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .contentTransition(.opacity)
                .id(toolbarTitle)
                .transition(TaskbarMotion.pushTransition(forward: monthForward))

            navButton(systemName: "chevron.right") {
                shift(by: 1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .animation(TaskbarMotion.contentPush, value: displayedMonth)
        .animation(TaskbarMotion.contentPush, value: selectedDay)
    }

    private var toolbarTitle: String {
        if isMonthExpanded {
            return clock.monthTitle(for: displayedMonth)
        }
        return weekTitle(containing: selectedDay)
    }

    private func navButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.16))
                )
        }
        .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.9))
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(["一", "二", "三", "四", "五", "六", "日"].enumerated()), id: \.offset) { index, symbol in
                Text(symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(index >= 5 ? weekendPink : Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 18)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    private var dayGrid: some View {
        Group {
            if isMonthExpanded {
                monthGrid
            } else {
                weekGrid
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
        .animation(TaskbarMotion.calendarExpand, value: isMonthExpanded)
        .animation(TaskbarMotion.contentPush, value: displayedMonth)
        .animation(TaskbarMotion.contentPush, value: selectedDay)
    }

    private var weekGrid: some View {
        let days = weekDays(containing: selectedDay)
        return HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                dayCell(day)
            }
        }
        .frame(height: Metrics.weekGridHeight)
    }

    private var monthGrid: some View {
        let days = monthDays(for: displayedMonth)
        return VStack(spacing: Metrics.rowSpacing) {
            ForEach(0..<Metrics.monthRows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        let index = row * 7 + col
                        dayCell(index < days.count ? days[index] : nil)
                    }
                }
            }
        }
        .frame(height: Metrics.monthGridHeight, alignment: .top)
    }

    private var expandCornerButton: some View {
        Button {
            withAnimation(TaskbarMotion.calendarExpand) {
                viewModel.isCalendarExpanded.toggle()
                if viewModel.isCalendarExpanded {
                    displayedMonth = startOfMonth(for: selectedDay)
                }
            }
        } label: {
            Image(systemName: isMonthExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.22))
                )
        }
        .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.9))
        .help(isMonthExpanded ? "收起" : "展开")
    }

    private func dayCell(_ day: Date?) -> some View {
        Group {
            if let day {
                let isCurrentMonth = calendar.isDate(day, equalTo: displayedMonth, toGranularity: .month)
                if isMonthExpanded && !isCurrentMonth {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: Metrics.dayCell)
                } else {
                    let isToday = calendar.isDateInToday(day)
                    let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
                    let isRest = store.isRestDay(on: day)
                    let isWork = store.isMakeupWorkday(on: day)
                    let isHoliday = store.hasHoliday(on: day)
                    let hasEvents = store.hasEvents(on: day)
                    let weekday = calendar.component(.weekday, from: day)
                    let isWeekend = weekday == 1 || weekday == 7
                    let dayWeather = weather.weather(on: day)
                    Button {
                        selectDay(day)
                    } label: {
                        VStack(spacing: 3) {
                            Text("\(calendar.component(.day, from: day))")
                                .font(.system(size: 12, weight: isToday || isSelected ? .bold : .regular, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(dayForeground(
                                    isToday: isToday,
                                    isCurrentMonth: isCurrentMonth,
                                    isRest: isRest,
                                    isWork: isWork,
                                    isHoliday: isHoliday,
                                    isWeekend: isWeekend
                                ))
                                .frame(width: Metrics.todayRing, height: Metrics.todayRing)
                                .background(
                                    Circle()
                                        .fill(isToday ? Color.white : (isSelected ? Color.white.opacity(0.28) : Color.clear))
                                )
                                .overlay(alignment: .topTrailing) {
                                    if isRest {
                                        Text("休")
                                            .font(.system(size: 7, weight: .heavy))
                                            .foregroundStyle(isToday ? todayInk : restMint)
                                            .offset(x: 5, y: -1)
                                    } else if isWork {
                                        Text("班")
                                            .font(.system(size: 7, weight: .heavy))
                                            .foregroundStyle(isToday ? todayInk : Color.white.opacity(0.82))
                                            .offset(x: 5, y: -1)
                                    }
                                }
                            dayWeatherChip(
                                dayWeather: dayWeather,
                                isCurrentMonth: isCurrentMonth,
                                isHoliday: isHoliday,
                                isRest: isRest,
                                hasEvents: hasEvents
                            )
                        }
                        .padding(.top, 1)
                        .frame(maxWidth: .infinity)
                        .frame(height: Metrics.dayCell, alignment: .top)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.dayCell)
            }
        }
    }

    private func dayWeatherChip(
        dayWeather: DayWeather?,
        isCurrentMonth: Bool,
        isHoliday: Bool,
        isRest: Bool,
        hasEvents: Bool
    ) -> some View {
        Group {
            if let dayWeather {
                VStack(spacing: 0) {
                    weatherIcon(dayWeather.kind, night: false, size: 10)
                    Text("\(dayWeather.high)°")
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
                .frame(height: 20)
            } else {
                HStack(spacing: 2) {
                    if isHoliday && !isRest {
                        Circle().fill(weekendPink).frame(width: 4, height: 4)
                    }
                    if hasEvents {
                        Circle().fill(Color.white.opacity(0.9)).frame(width: 4, height: 4)
                    }
                }
                .frame(height: 16)
            }
        }
    }

    private func dayForeground(
        isToday: Bool,
        isCurrentMonth: Bool,
        isRest: Bool,
        isWork: Bool,
        isHoliday: Bool,
        isWeekend: Bool
    ) -> Color {
        if isToday { return todayInk }
        if !isCurrentMonth { return Color.white.opacity(0.7) }
        if isWork { return .white }
        if isRest { return restMint }
        if isHoliday || isWeekend { return weekendPink }
        return .white
    }

    private var dayAgenda: some View {
        let items = store.items(on: selectedDay)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(selectedDayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                if store.isMakeupWorkday(on: selectedDay) {
                    dayBadge("调休上班", color: Color.white.opacity(0.72))
                } else if store.isRestDay(on: selectedDay), let holiday = store.holidayName(on: selectedDay) {
                    dayBadge(holiday, color: restMint)
                } else if let holiday = store.holidayName(on: selectedDay) {
                    dayBadge(holiday, color: weekendPink)
                }
                Spacer(minLength: 0)
                if let dayWeather = weather.weather(on: selectedDay) {
                    HStack(spacing: 4) {
                        weatherIcon(dayWeather.kind, night: false, size: 12)
                        Text("\(dayWeather.label)  \(dayWeather.high)° / \(dayWeather.low)°")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                    }
                }
            }

            if store.permissionDenied || store.needsPermission {
                Button {
                    if store.needsPermission {
                        store.requestAccessFromUser()
                    } else {
                        store.openPrivacySettings()
                    }
                } label: {
                    Label("允许日历权限以查看日程", systemImage: "calendar.badge.exclamationmark")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        agendaRow(item)
                    }
                }
            }
            .frame(maxHeight: 176)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 18)
        .frame(maxHeight: Metrics.agendaHeight, alignment: .top)
    }

    private var selectedDayTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: selectedDay)
    }

    private func dayBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous).fill(color.opacity(0.18))
            )
    }

    private func agendaRow(_ item: CalendarDayItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(agendaColor(for: item))
                .frame(width: 6, height: 6)
                .padding(.top, 4)
            Text(item.title)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.12))
        )
    }

    private func agendaColor(for item: CalendarDayItem) -> Color {
        switch item.kind {
        case .rest: return restMint
        case .holiday: return weekendPink
        case .workday: return Color.white.opacity(0.55)
        case .event: return item.color ?? Color.white
        }
    }

    private func selectDay(_ day: Date) {
        let start = calendar.startOfDay(for: day)
        if isAgendaExpanded, calendar.isDate(selectedDay, inSameDayAs: start) {
            collapseAgenda()
            return
        }
        selectedDay = start
        displayedMonth = startOfMonth(for: start)
        let hasItems = !store.items(on: start).isEmpty
        withAnimation(TaskbarMotion.calendarAgenda) {
            viewModel.isCalendarAgendaExpanded = hasItems
        }
    }

    private func collapseAgenda() {
        withAnimation(TaskbarMotion.contentPop) {
            viewModel.isCalendarAgendaExpanded = false
        }
    }

    private func shift(by value: Int) {
        monthForward = value > 0
        collapseAgenda()
        if isMonthExpanded {
            guard let next = calendar.date(byAdding: .month, value: value, to: displayedMonth) else { return }
            withAnimation(TaskbarMotion.contentPush) {
                displayedMonth = startOfMonth(for: next)
                selectedDay = defaultSelectedDay(in: displayedMonth)
            }
        } else {
            guard let next = calendar.date(byAdding: .day, value: value * 7, to: selectedDay) else { return }
            withAnimation(TaskbarMotion.contentPush) {
                selectedDay = calendar.startOfDay(for: next)
                displayedMonth = startOfMonth(for: selectedDay)
            }
        }
    }

    private func defaultSelectedDay(in month: Date) -> Date {
        if calendar.isDate(clock.now, equalTo: month, toGranularity: .month) {
            return calendar.startOfDay(for: clock.now)
        }
        return month
    }

    private func startOfMonth(for date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    private func weekTitle(containing day: Date) -> String {
        let days = weekDays(containing: day)
        guard let start = days.first, let end = days.last else {
            return clock.monthTitle(for: day)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    private func weekDays(containing day: Date) -> [Date] {
        let startOfDay = calendar.startOfDay(for: day)
        let weekday = calendar.component(.weekday, from: startOfDay)
        let mondayOffset = (weekday + 5) % 7
        guard let weekStart = calendar.date(byAdding: .day, value: -mondayOffset, to: startOfDay) else {
            return [startOfDay]
        }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private func monthDays(for month: Date) -> [Date?] {
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let firstWeekday = calendar.dateComponents([.weekday], from: monthStart).weekday
        else {
            return Array(repeating: nil, count: Metrics.monthRows * 7)
        }

        let mondayOffset = (firstWeekday + 5) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -mondayOffset, to: monthStart) else {
            return Array(repeating: nil, count: Metrics.monthRows * 7)
        }

        return (0..<(Metrics.monthRows * 7)).map { offset in
            calendar.date(byAdding: .day, value: offset, to: gridStart)
        }
    }
}
