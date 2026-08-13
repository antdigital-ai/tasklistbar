import Foundation

struct HolidayArrangement: Codable {
    var year: Int
    var sourceURL: String
    var fetchedAt: Date
    var restDays: [String: String]
    var workdays: [String: String]

    func restName(on date: Date, calendar: Calendar = .current) -> String? {
        restDays[Self.key(date, calendar: calendar)]
    }

    func workName(on date: Date, calendar: Calendar = .current) -> String? {
        workdays[Self.key(date, calendar: calendar)]
    }

    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

enum HolidayArrangementParser {
    private static let holidayNames = "元旦|春节|清明节|劳动节|端午节|中秋节|国庆节"

    static func parse(htmlOrText: String, fallbackYear: Int, sourceURL: String) -> HolidayArrangement? {
        let text = stripTags(htmlOrText)
        let year = extractYear(from: text) ?? fallbackYear
        guard let regex = try? NSRegularExpression(
            pattern: "[一二三四五六七八]、\\s*(\(holidayNames))[：:](.*?)(?=[一二三四五六七八]、\\s*(?:\(holidayNames))|鼓励单位|国务院办公厅|$)",
            options: [.dotMatchesLineSeparators]
        ) else { return nil }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var rest: [String: String] = [:]
        var work: [String: String] = [:]
        let calendar = Calendar(identifier: .gregorian)

        for match in matches {
            guard match.numberOfRanges >= 3,
                  let name = substring(nsText, match.range(at: 1)),
                  let body = substring(nsText, match.range(at: 2))
            else { continue }
            let compact = body.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            for sentence in compact.components(separatedBy: "。") {
                if sentence.contains("放假") {
                    for day in restRange(in: sentence, year: year, calendar: calendar) {
                        rest[HolidayArrangement.key(day, calendar: calendar)] = name
                    }
                }
                if sentence.contains("上班") {
                    for day in listedDates(in: sentence, year: year, calendar: calendar) {
                        work[HolidayArrangement.key(day, calendar: calendar)] = "\(name)调休上班"
                    }
                }
            }
        }

        guard !rest.isEmpty else { return nil }
        return HolidayArrangement(
            year: year,
            sourceURL: sourceURL,
            fetchedAt: Date(),
            restDays: rest,
            workdays: work
        )
    }

    private static func extractYear(from text: String) -> Int? {
        if let match = text.range(of: "关于([0-9]{4})年", options: .regularExpression) {
            let slice = String(text[match]).filter(\.isNumber)
            return Int(slice)
        }
        return nil
    }

    private static func restRange(in sentence: String, year: Int, calendar: Calendar) -> [Date] {
        guard let regex = try? NSRegularExpression(pattern: "([0-9]{1,2})月([0-9]{1,2})日.*?至(?:([0-9]{1,2})月)?([0-9]{1,2})日"),
              let match = regex.firstMatch(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)),
              let startMonth = intValue(sentence, match.range(at: 1)),
              let startDay = intValue(sentence, match.range(at: 2)),
              let endDay = intValue(sentence, match.range(at: 4))
        else { return [] }
        let endMonth = intValue(sentence, match.range(at: 3)) ?? startMonth
        guard let start = date(year: year, month: startMonth, day: startDay, calendar: calendar),
              let end = date(year: year, month: endMonth, day: endDay, calendar: calendar)
        else { return [] }
        var days: [Date] = []
        var cursor = start
        while cursor <= end {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    private static func listedDates(in sentence: String, year: Int, calendar: Calendar) -> [Date] {
        guard let regex = try? NSRegularExpression(pattern: "([0-9]{1,2})月([0-9]{1,2})日") else { return [] }
        let ns = sentence as NSString
        return regex.matches(in: sentence, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let month = intValue(sentence, match.range(at: 1)),
                  let day = intValue(sentence, match.range(at: 2))
            else { return nil }
            return date(year: year, month: month, day: day, calendar: calendar)
        }
    }

    private static func date(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private static func intValue(_ text: String, _ range: NSRange) -> Int? {
        guard range.location != NSNotFound else { return nil }
        return Int((text as NSString).substring(with: range))
    }

    private static func substring(_ text: NSString, _ range: NSRange) -> String? {
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        return text.substring(with: range)
    }

    static func stripTags(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</p>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&emsp;", with: " ")
        text = text.replacingOccurrences(of: "&ldquo;", with: "“")
        text = text.replacingOccurrences(of: "&rdquo;", with: "”")
        return text
    }
}

enum GovHolidayFetcher {
    private static let knownPages: [Int: String] = [
        2026: "https://www.gov.cn/zhengce/content/202511/content_7047090.htm"
    ]

    private static let bundledNotices: [Int: String] = [
        2026: """
        国务院办公厅关于2026年部分节假日安排的通知
        一、元旦：1月1日（周四）至3日（周六）放假调休，共3天。1月4日（周日）上班。
        二、春节：2月15日（农历腊月二十八、周日）至23日（农历正月初七、周一）放假调休，共9天。2月14日（周六）、2月28日（周六）上班。
        三、清明节：4月4日（周六）至6日（周一）放假，共3天。
        四、劳动节：5月1日（周五）至5日（周二）放假调休，共5天。5月9日（周六）上班。
        五、端午节：6月19日（周五）至21日（周日）放假，共3天。
        六、中秋节：9月25日（周五）至27日（周日）放假，共3天。
        七、国庆节：10月1日（周四）至7日（周三）放假调休，共7天。9月20日（周日）、10月10日（周六）上班。
        """
    ]

    static func cached(year: Int) -> HolidayArrangement? {
        guard let url = cacheURL(year: year),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(HolidayArrangement.self, from: data)
    }

    static func fallback(year: Int) -> HolidayArrangement? {
        guard let text = bundledNotices[year] else { return nil }
        return HolidayArrangementParser.parse(
            htmlOrText: text,
            fallbackYear: year,
            sourceURL: knownPages[year] ?? "https://www.gov.cn"
        )
    }

    static func fetch(year: Int) async throws -> HolidayArrangement {
        let pageURL = try await resolveNoticeURL(year: year)
        let html = try await getString(from: pageURL)
        guard let parsed = HolidayArrangementParser.parse(htmlOrText: html, fallbackYear: year, sourceURL: pageURL.absoluteString)
        else {
            throw URLError(.cannotParseResponse)
        }
        saveCache(parsed)
        return parsed
    }

    private static func resolveNoticeURL(year: Int) async throws -> URL {
        if let searchURL = try? await searchNoticeURL(year: year) {
            return searchURL
        }
        if let raw = knownPages[year], let url = URL(string: raw) {
            return url
        }
        throw URLError(.fileDoesNotExist)
    }

    private static func searchNoticeURL(year: Int) async throws -> URL? {
        var components = URLComponents(string: "https://sousuo.www.gov.cn/search-gov/data")
        components?.queryItems = [
            URLQueryItem(name: "t", value: "zhengcelibrary_gw"),
            URLQueryItem(name: "q", value: "部分节假日安排的通知"),
            URLQueryItem(name: "searchfield", value: "title"),
            URLQueryItem(name: "p", value: "1"),
            URLQueryItem(name: "n", value: "20"),
            URLQueryItem(name: "sort", value: "score"),
            URLQueryItem(name: "sortType", value: "1")
        ]
        guard let url = components?.url else { return nil }
        let data = try await getData(from: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let searchVO = root["searchVO"] as? [String: Any],
              let list = searchVO["listVO"] as? [[String: Any]]
        else { return nil }

        let yearToken = "\(year)年"
        for item in list {
            let title = HolidayArrangementParser.stripTags(item["title"] as? String ?? "")
            guard title.contains(yearToken), title.contains("节假日安排"),
                  let raw = item["url"] as? String, let found = URL(string: raw)
            else { continue }
            return found
        }
        return nil
    }

    private static func getString(from url: URL) async throws -> String {
        let data = try await getData(from: url)
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .ascii)
            ?? ""
    }

    private static func getData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func cacheURL(year: Int) -> URL? {
        let fm = FileManager.default
        guard let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = root.appendingPathComponent("TaskListBar", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("holiday-\(year).json")
    }

    private static func saveCache(_ arrangement: HolidayArrangement) {
        guard let url = cacheURL(year: arrangement.year),
              let data = try? JSONEncoder().encode(arrangement)
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
