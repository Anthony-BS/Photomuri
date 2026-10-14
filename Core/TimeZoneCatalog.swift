import Foundation

struct TimeZoneCity: Codable, Identifiable {
    let english: String
    let korean: String
    let aliases: [String]
    let country: String
    let identifier: String
    let representative: Bool
    var id: String { "\(identifier)|\(country)|\(english)" }

    func matches(_ query: String) -> Bool {
        ([english, korean, identifier] + aliases).contains {
            TimeZoneCatalog.normalized($0).contains(query)
        }
    }
}

struct TimeZoneCatalogEntry: Identifiable {
    let identifier: String
    let locations: [TimeZoneCity]
    var id: String { identifier }

    func policy(applyDST: Bool) -> CaptureTimeZonePolicy? {
        CaptureTimeZonePolicy(identifier: identifier, applyDaylightSavingTime: applyDST)
    }

    func offset(on date: Date, applyDST: Bool) -> Int {
        policy(applyDST: applyDST)?.offsetSeconds(on: date) ?? 0
    }

    func displayName(on date: Date, applyDST: Bool = true) -> String {
        let seconds = offset(on: date, applyDST: applyDST)
        let marker = policy(applyDST: applyDST)?.isDSTApplied(on: date) == true ? "*" : ""
        let cities = locations.prefix(4).map { $0.english + marker }.joined(separator: ", ")
        return String(format: "UTC %@%02d:%02d (%@)", seconds < 0 ? "−" : "+",
                      abs(seconds) / 3600, abs(seconds) % 3600 / 60, cities)
    }
}

/// One visible row per effective UTC offset, without discarding city-specific IANA rules.
struct TimeZoneOffsetGroup: Identifiable {
    let seconds: Int
    let locations: [TimeZoneCity]
    var id: Int { seconds }

    func preferredIdentifier(keeping identifier: String) -> String {
        locations.contains { $0.identifier == identifier } ? identifier : locations[0].identifier
    }

    func contains(identifier: String) -> Bool {
        locations.contains { $0.identifier == identifier }
    }

    func cityName(_ city: TimeZoneCity, on date: Date, applyDST: Bool) -> String {
        let policy = CaptureTimeZonePolicy(identifier: city.identifier, applyDaylightSavingTime: applyDST)
        return city.english + (policy?.isDSTApplied(on: date) == true ? "*" : "")
    }

    func displayName(on date: Date, applyDST: Bool) -> String {
        let names = locations.prefix(4).map { cityName($0, on: date, applyDST: applyDST) }.joined(separator: ", ")
        return String(format: "UTC %@%02d:%02d (%@)", seconds < 0 ? "−" : "+",
                      abs(seconds) / 3600, abs(seconds) % 3600 / 60, names)
    }
}

enum TimeZoneCatalog {
    /// Representative rows stay compact; all capital/major-city records are searchable.
    static let cities: [TimeZoneCity] = {
        guard let url = Bundle.main.url(forResource: "TimeZoneCities", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([TimeZoneCity].self, from: data) else {
            return []
        }
        return records
    }()

    static var entries: [TimeZoneCatalogEntry] { group(cities.filter(\.representative)) }
    static var allEntries: [TimeZoneCatalogEntry] { group(cities) }

    static func search(_ text: String, in records: [TimeZoneCity] = cities) -> [TimeZoneCatalogEntry] {
        let query = normalized(text)
        return group(query.isEmpty ? records.filter(\.representative) : matchingCities(query, in: records))
    }

    static func offsetGroups(matching text: String, on date: Date, applyDST: Bool,
                             in records: [TimeZoneCity] = cities) -> [TimeZoneOffsetGroup] {
        let query = normalized(text)
        let matches = query.isEmpty ? records : matchingCities(query, in: records)
        let valid = matches.filter { TimeZone(identifier: $0.identifier) != nil }
        let grouped = Dictionary(grouping: valid) {
            CaptureTimeZonePolicy(identifier: $0.identifier, applyDaylightSavingTime: applyDST)!.offsetSeconds(on: date)
        }
        return grouped.map { seconds, cities in
            TimeZoneOffsetGroup(seconds: seconds, locations: cities.sorted {
                let left = displayPriority.firstIndex(of: $0.english) ?? Int.max
                let right = displayPriority.firstIndex(of: $1.english) ?? Int.max
                if left != right { return left < right }
                if $0.representative != $1.representative { return $0.representative }
                return $0.english < $1.english
            })
        }.sorted { $0.seconds < $1.seconds }
    }

    private static let displayPriority = [
        "Seoul", "Tokyo", "Osaka", "Busan", "Shanghai", "Beijing", "Singapore", "Perth",
        "London", "Lisbon", "Dublin", "Reykjavik", "Paris", "Berlin", "Rome", "Madrid",
        "Sydney", "Melbourne", "Canberra", "Brisbane", "Darwin", "Adelaide",
        "Los Angeles", "Vancouver", "Seattle", "Phoenix", "Denver", "Calgary",
        "Chicago", "Mexico City", "New York", "Toronto", "Lima", "Bogota",
        "Athens", "Helsinki", "Cairo", "Johannesburg", "Istanbul", "Moscow", "Riyadh",
        "Dubai", "Baku", "Tbilisi", "New Delhi", "Mumbai", "Colombo", "Kathmandu"
    ]

    /// English/Korean region names are bundled with macOS; no network lookup.
    /// Common short names are aliases, not additional country/time-zone rules.
    private static let countrySearchTerms: [String: Set<String>] = {
        let english = Locale(identifier: "en")
        let korean = Locale(identifier: "ko")
        let aliases: [String: [String]] = [
            "KR": ["한국", "남한", "대한민국", "Korea", "South Korea", "Republic of Korea", "KOR"],
            "US": ["미국", "미합중국", "USA", "U.S.A.", "America", "United States of America"],
            "GB": ["영국", "UK", "U.K.", "Britain", "Great Britain", "United Kingdom", "GBR"],
            "AU": ["호주", "오스트레일리아", "Australia", "AUS"],
            "CN": ["중국", "중화인민공화국", "China", "PRC", "CHN"],
            "JP": ["일본", "Japan", "JPN"],
            "TR": ["터키", "튀르키예", "Turkey", "Turkiye", "Türkiye"],
            "AE": ["아랍에미리트", "아랍 에미리트", "UAE", "United Arab Emirates"],
            "RU": ["러시아", "Russia", "Russian Federation", "RUS"],
            "CZ": ["체코", "Czechia", "Czech Republic"],
            "NL": ["네덜란드", "Netherlands", "Holland"],
            "PS": ["팔레스타인", "Palestine", "Palestinian Territories"],
            "TL": ["동티모르", "East Timor", "Timor-Leste"]
        ]
        return Dictionary(uniqueKeysWithValues: Locale.Region.isoRegions.map { region in
            let code = region.identifier
            let names = [code, english.localizedString(forRegionCode: code), korean.localizedString(forRegionCode: code)]
                .compactMap { $0 } + (aliases[code] ?? [])
            return (code, Set(names.map(normalized).filter { !$0.isEmpty }))
        })
    }()

    private static func matchingCities(_ query: String, in records: [TimeZoneCity]) -> [TimeZoneCity] {
        // Exact country/abbreviation matches take precedence: "US" must not
        // accidentally also match Australia, Austria or unrelated city aliases.
        let exactCountries = Set(countrySearchTerms.compactMap { code, names in
            names.contains(query) ? code : nil
        })
        if !exactCountries.isEmpty {
            return records.filter { exactCountries.contains($0.country) }
        }
        let partialCountries = query.count >= 2 ? Set(countrySearchTerms.compactMap { code, names in
            names.contains { $0.count > 2 && $0.contains(query) } ? code : nil
        }) : []
        return records.filter { $0.matches(query) || partialCountries.contains($0.country) }
    }

    nonisolated static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    static func group(_ records: [TimeZoneCity]) -> [TimeZoneCatalogEntry] {
        Dictionary(grouping: records, by: \.identifier).map { identifier, cities in
            TimeZoneCatalogEntry(identifier: identifier, locations: cities.sorted {
                if $0.representative != $1.representative { return $0.representative }
                return $0.english < $1.english
            })
        }.sorted { $0.identifier < $1.identifier }
    }

    static func cityExamples(forOffset offset: Int, on date: Date) -> String {
        entries.filter { $0.offset(on: date, applyDST: true) == offset }
            .flatMap { entry in
                let star = entry.policy(applyDST: true)?.isDSTApplied(on: date) == true ? "*" : ""
                return entry.locations.map { $0.english + star }
            }.prefix(4).joined(separator: ", ")
    }
}
