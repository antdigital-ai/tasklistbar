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
    @State private var pageToken = 0

    private let calendar = Calendar.current
    private let weekendPink = Color(red: 1.00, green: 0.48, blue: 0.50)
    private let restMint = Color(red: 0.42, green: 0.98, blue: 0.70)
    private let todayInk = Color(red: 0.10, green: 0.34, blue: 0.68)

    enum Metrics {
        static let width: CGFloat = 520
        static let sidebarWidth: CGFloat = 154
        static let weekHeight: CGFloat = 154
        static let monthHeight: CGFloat = 392
        static let agendaHeight: CGFloat = 240
        static let agendaPopupWidth: CGFloat = 448
        static let height: CGFloat = monthHeight
        static let corner: CGFloat = 18
        static let padX: CGFloat = 10
        static let dayCell: CGFloat = 47
        static let fiveWeekDayCell: CGFloat = 58
        static let todayRing: CGFloat = 26
        static let monthRows = 6
        static let rowSpacing: CGFloat = 3

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

            HStack(alignment: .top, spacing: 10) {
                hero
                forecastCard
            }
            .padding(10)

            if isAgendaExpanded {
                Color.black.opacity(0.28)
                    .contentShape(Rectangle())
                    .onTapGesture { collapseAgenda() }
                    .transition(.opacity)

                agendaPopup
                    .transition(TaskbarMotion.calendarAgendaTransition())
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
                Text(clock.weekdayText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(calendar.component(.day, from: clock.now))")
                    .font(.system(size: 46, weight: .light, design: .rounded))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(calendar.component(.month, from: clock.now))月")
                    Text("\(calendar.component(.year, from: clock.now))")
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
            }
            .foregroundStyle(.white)
            .padding(.top, 8)

            if weather.currentTemp != nil || todayForecast != nil {
                HStack(spacing: 7) {
                    weatherIcon(heroKind, night: isNight, size: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(heroTemp)° · \(heroKind.label)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        if let todayForecast {
                            Text("\(todayForecast.high)° / \(todayForecast.low)°")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.68))
                                .monospacedDigit()
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding(.top, 8)
            }

            if isMonthExpanded {
                sidebarDivider
                    .padding(.vertical, 12)
                todaySummary
                Spacer(minLength: 12)
                nextArrangement
                Text("点击日期查看详情")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                    .padding(.top, 10)
            }
        }
        .padding(12)
        .frame(width: Metrics.sidebarWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.075))
        )
        .accessibilityElement(children: .contain)
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
    }

    private var sidebarDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(height: 1)
    }

    private var todaySummary: some View {
        let eventItems = store.items(on: clock.now).filter { $0.kind == .event }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                Text("今日日程")
                Spacer(minLength: 0)
                if !eventItems.isEmpty {
                    Text("\(eventItems.count)")
                        .monospacedDigit()
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.72))

            if store.permissionDenied || store.needsPermission {
                Button {
                    if store.needsPermission {
                        store.requestAccessFromUser()
                    } else {
                        store.openPrivacySettings()
                    }
                } label: {
                    Label("允许访问日历", systemImage: "lock.open")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            } else if eventItems.isEmpty {
                Label("暂无日程", systemImage: "checkmark.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
            } else {
                ForEach(Array(eventItems.prefix(2))) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(agendaColor(for: item))
                            .frame(width: 5, height: 5)
                            .padding(.top, 4)
                        Text(item.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var nextArrangement: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("本月安排", systemImage: "calendar.badge.clock")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.56))
            if let arrangement = upcomingArrangement {
                Text(arrangement.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(arrangement.kind == .rest ? restMint : Color.white)
                    .lineLimit(1)
                Text(arrangement.dateText)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
                    .monospacedDigit()
            } else {
                Text("暂无调休安排")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
            }
        }
    }

    private var upcomingArrangement: HolidaySpan? {
        let today = calendar.startOfDay(for: clock.now)
        let arrangements = store.monthArrangements(for: displayedMonth)
        if calendar.isDate(displayedMonth, equalTo: today, toGranularity: .month) {
            return arrangements.first { $0.end >= today }
        }
        return arrangements.first
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

            ZStack {
                Text(toolbarTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .id(toolbarTitle)
                    .transition(TaskbarMotion.calendarPageTransition(forward: monthForward))
            }
            .frame(maxWidth: .infinity)
            .clipped()

            navButton(systemName: "chevron.right") {
                shift(by: 1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 9)
        .padding(.bottom, 7)
        .animation(TaskbarMotion.calendarPage, value: toolbarTitle)
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
                    .frame(height: 22)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    private var dayGrid: some View {
        ZStack {
            calendarPage
                .id(pageToken)
                .transition(TaskbarMotion.calendarPageTransition(forward: monthForward))
        }
        .padding(.horizontal, 5)
        .padding(.bottom, 5)
        .clipped()
        .animation(TaskbarMotion.calendarPage, value: pageToken)
        .animation(TaskbarMotion.calendarExpand, value: isMonthExpanded)
    }

    private var calendarPage: some View {
        let days = monthDays(for: displayedMonth)
        let weekRow = focusedWeekRow(in: days)
        let rowCount = isMonthExpanded ? monthRowCount(for: displayedMonth) : Metrics.monthRows
        let rowHeight = isMonthExpanded && rowCount == 5 ? Metrics.fiveWeekDayCell : Metrics.dayCell
        let rowStride = Metrics.dayCell + Metrics.rowSpacing
        return VStack(spacing: Metrics.rowSpacing) {
            ForEach(0..<rowCount, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        let index = row * 7 + col
                        dayCell(index < days.count ? days[index] : nil, height: rowHeight)
                    }
                }
                .frame(height: rowHeight)
            }
        }
        .offset(y: isMonthExpanded ? 0 : -CGFloat(weekRow) * rowStride)
        .frame(
            height: isMonthExpanded
                ? rowHeight * CGFloat(rowCount) + Metrics.rowSpacing * CGFloat(rowCount - 1)
                : Metrics.weekGridHeight,
            alignment: .top
        )
        .clipped()
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
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(isMonthExpanded ? 180 : 0))
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.22))
                )
        }
        .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.9))
        .animation(TaskbarMotion.calendarExpand, value: isMonthExpanded)
        .help(isMonthExpanded ? "收起" : "展开")
    }

    private func dayCell(_ day: Date?, height: CGFloat) -> some View {
        Group {
            if let day {
                let isCurrentMonth = calendar.isDate(day, equalTo: displayedMonth, toGranularity: .month)
                if isMonthExpanded && !isCurrentMonth {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
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
                                .font(.system(size: 13, weight: isToday || isSelected ? .bold : .medium, design: .rounded))
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
                                        .scaleEffect(isToday || isSelected ? 1 : 0.72)
                                )
                                .animation(TaskbarMotion.calendarDay, value: isSelected)
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
                        .frame(maxWidth: .infinity)
                        .frame(height: height, alignment: .center)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
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
            withAnimation(TaskbarMotion.calendarPage) {
                pageToken += 1
                displayedMonth = startOfMonth(for: next)
                selectedDay = defaultSelectedDay(in: displayedMonth)
            }
        } else {
            guard let next = calendar.date(byAdding: .day, value: value * 7, to: selectedDay) else { return }
            withAnimation(TaskbarMotion.calendarPage) {
                pageToken += 1
                selectedDay = calendar.startOfDay(for: next)
                displayedMonth = startOfMonth(for: selectedDay)
            }
        }
    }

    private func focusedWeekRow(in days: [Date?]) -> Int {
        for (index, day) in days.enumerated() {
            guard let day, calendar.isDate(day, inSameDayAs: selectedDay) else { continue }
            return index / 7
        }
        return 0
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

    private func monthRowCount(for month: Date) -> Int {
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let dayRange = calendar.range(of: .day, in: .month, for: monthStart)
        else {
            return Metrics.monthRows
        }
        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let mondayOffset = (firstWeekday + 5) % 7
        return min(Metrics.monthRows, max(5, (mondayOffset + dayRange.count + 6) / 7))
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
