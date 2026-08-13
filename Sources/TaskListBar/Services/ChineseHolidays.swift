import Foundation

enum ChineseHolidays {
    struct Holiday: Equatable {
        let name: String
        let isOfficial: Bool
    }

    static func holiday(on date: Date, calendar: Calendar = .current) -> Holiday? {
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)

        if month == 1, day == 1 { return Holiday(name: "元旦", isOfficial: true) }
        if month == 3, day == 8 { return Holiday(name: "妇女节", isOfficial: false) }
        if month == 4, day == qingmingDay(in: year) { return Holiday(name: "清明节", isOfficial: true) }
        if month == 5, day == 1 { return Holiday(name: "劳动节", isOfficial: true) }
        if month == 5, day == 4 { return Holiday(name: "青年节", isOfficial: false) }
        if month == 6, day == 1 { return Holiday(name: "儿童节", isOfficial: false) }
        if month == 9, day == 10 { return Holiday(name: "教师节", isOfficial: false) }
        if month == 10, day == 1 { return Holiday(name: "国庆节", isOfficial: true) }

        let lunar = Calendar(identifier: .chinese)
        let lunarComponents = lunar.dateComponents([.month, .day], from: date)
        if lunarComponents.isLeapMonth != true, let lunarMonth = lunarComponents.month, let lunarDay = lunarComponents.day {
            switch (lunarMonth, lunarDay) {
            case (1, 1): return Holiday(name: "春节", isOfficial: true)
            case (1, 15): return Holiday(name: "元宵节", isOfficial: false)
            case (5, 5): return Holiday(name: "端午节", isOfficial: true)
            case (7, 7): return Holiday(name: "七夕", isOfficial: false)
            case (8, 15): return Holiday(name: "中秋节", isOfficial: true)
            case (9, 9): return Holiday(name: "重阳节", isOfficial: false)
            default: break
            }
        }

        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) {
            let next = lunar.dateComponents([.month, .day], from: tomorrow)
            if next.isLeapMonth != true, next.month == 1, next.day == 1 {
                return Holiday(name: "除夕", isOfficial: true)
            }
        }

        return nil
    }

    private static func qingmingDay(in year: Int) -> Int {
        let y = year % 100
        return Int(Double(y) * 0.2422 + 4.81) - y / 4
    }
}
