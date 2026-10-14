import Foundation

@main
struct TimeZoneFeatureTests {
    static func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let cities = try JSONDecoder().decode([TimeZoneCity].self, from: data)
        precondition(cities.count >= 250)
        precondition(cities.allSatisfy { !$0.korean.isEmpty && TimeZone(identifier: $0.identifier) != nil })
        precondition(TimeZoneCatalog.search("평양", in: cities).isEmpty)
        precondition(TimeZoneCatalog.search("Pyongyang", in: cities).isEmpty)
        for (english,korean,identifier) in [
            ("Amsterdam","암스테르담","Europe/Amsterdam"),
            ("Bern","베른","Europe/Zurich"),
            ("Nairobi","나이로비","Africa/Nairobi"),
            ("Canberra","캔버라","Australia/Sydney"),
            ("Gitega","기테가","Africa/Bujumbura"),
            ("Seoul","서울","Asia/Seoul")
        ] {
            for query in [english, korean, english.uppercased()] {
                precondition(TimeZoneCatalog.search(query, in: cities).contains { $0.identifier == identifier }, query)
            }
        }
        let summer = date("2026-07-01T12:00:00Z")
        let winter = date("2026-01-01T12:00:00Z")
        for (queries, code) in [
            (["한국", "대한민국", "Korea", "South Korea", "KR"], "KR"),
            (["미국", "United States", "USA", "U.S.A.", "US"], "US"),
            (["영국", "United Kingdom", "UK", "Britain"], "GB"),
            (["호주", "오스트레일리아", "Australia", "AUS"], "AU"),
            (["포르투갈", "Portugal", "PT"], "PT"),
            (["일본", "Japan", "JP"], "JP"),
            (["프랑스", "France", "FR"], "FR")
        ] {
            let expected = Set(cities.filter { $0.country == code }.map(\.id))
            precondition(!expected.isEmpty)
            for query in queries {
                let groups = TimeZoneCatalog.offsetGroups(matching: query, on: summer, applyDST: true, in: cities)
                precondition(Set(groups.flatMap(\.locations).map(\.id)) == expected, query)
                precondition(groups.count == Set(groups.map(\.seconds)).count)
            }
        }
        let america = TimeZoneCatalog.offsetGroups(matching: "미국", on: summer, applyDST: true, in: cities)
        precondition(america.count > 1 && america.allSatisfy { $0.locations.allSatisfy { $0.country == "US" } })
        let australia = TimeZoneCatalog.offsetGroups(matching: "호주", on: summer, applyDST: true, in: cities)
        precondition(australia.count > 1)
        precondition(TimeZoneCatalog.offsetGroups(matching: "대한 민국", on: summer, applyDST: true, in: cities)
            .flatMap(\.locations).allSatisfy { $0.country == "KR" })
        precondition(!TimeZoneCatalog.offsetGroups(matching: "프랑", on: summer, applyDST: true, in: cities).isEmpty)
        for code in Set(cities.map(\.country)) {
            for language in ["en", "ko"] {
                if let name = Locale(identifier: language).localizedString(forRegionCode: code) {
                    let found = TimeZoneCatalog.offsetGroups(matching: name, on: summer, applyDST: true, in: cities)
                    precondition(Set(found.flatMap(\.locations).map(\.id)) == Set(cities.filter { $0.country == code }.map(\.id)), "\(code): \(name)")
                }
            }
        }
        for useDST in [true, false] {
            let groups = TimeZoneCatalog.offsetGroups(matching: "", on: summer, applyDST: useDST, in: cities)
            precondition(groups.count == Set(groups.map(\.seconds)).count)
            precondition(groups.map(\.seconds) == groups.map(\.seconds).sorted())
            let nine = groups.first { $0.seconds == 32400 }!
            precondition(nine.locations.contains { $0.english == "Seoul" })
            precondition(nine.locations.contains { $0.english == "Tokyo" })
            precondition(nine.displayName(on: summer, applyDST: useDST).contains("Seoul, Tokyo, Osaka"))
            precondition(nine.preferredIdentifier(keeping: "Asia/Tokyo") == "Asia/Tokyo")
            precondition(nine.preferredIdentifier(keeping: "Europe/London") == "Asia/Seoul")
            let amsterdam = TimeZoneCatalog.offsetGroups(matching: "암스테르담", on: summer, applyDST: useDST, in: cities)
            precondition(amsterdam.count == 1 && amsterdam[0].locations[0].identifier == "Europe/Amsterdam")
        }
        let mixedGroup = TimeZoneCatalog.offsetGroups(matching: "", on: summer, applyDST: true, in: cities).first { $0.seconds == 0 }!
        let azores = mixedGroup.locations.first { $0.english == "Azores" }!
        let reykjavik = mixedGroup.locations.first { $0.english == "Reykjavik" }!
        precondition(mixedGroup.cityName(azores, on: summer, applyDST: true).hasSuffix("*"))
        precondition(!mixedGroup.cityName(reykjavik, on: summer, applyDST: true).hasSuffix("*"))
        let london = CaptureTimeZonePolicy(identifier: "Europe/London")!
        let standardLondon = CaptureTimeZonePolicy(identifier: "Europe/London", applyDaylightSavingTime: false)!
        precondition(london.offsetSeconds(on: summer) == 3600 && london.isDSTApplied(on: summer))
        precondition(london.offsetSeconds(on: winter) == 0 && !london.isDSTApplied(on: winter))
        precondition(standardLondon.offsetSeconds(on: summer) == 0 && !standardLondon.isDSTApplied(on: summer))
        let seoul = CaptureTimeZonePolicy(identifier: "Asia/Seoul")!
        precondition(seoul.offsetSeconds(on: summer) == 32400 && !seoul.isDSTApplied(on: summer))
        let lordHowe = CaptureTimeZonePolicy(identifier: "Australia/Lord_Howe")!
        let standardLordHowe = CaptureTimeZonePolicy(identifier: "Australia/Lord_Howe", applyDaylightSavingTime: false)!
        precondition(lordHowe.offsetSeconds(on: winter) - standardLordHowe.offsetSeconds(on: winter) == 1800)
        let londonEntry = TimeZoneCatalog.search("London", in: cities).first { $0.identifier == "Europe/London" }!
        precondition(londonEntry.displayName(on: summer).contains("London*"))
        precondition(!londonEntry.displayName(on: winter).contains("*"))
        precondition(!londonEntry.displayName(on: summer, applyDST: false).contains("*"))
        precondition(londonEntry.displayName(on: summer, applyDST: false).hasPrefix("UTC +00:00"))
        let components = DateComponents(year: 2026, month: 7, day: 1, hour: 13, minute: 34, second: 56)
        precondition(london.absoluteDate(from: components) == date("2026-07-01T12:34:56Z"))
        precondition(standardLondon.absoluteDate(from: components) == date("2026-07-01T13:34:56Z"))
        var settings = PresetSettings.defaults(timeZone: TimeZone(identifier: "Asia/Seoul")!)
        let encoded = try JSONEncoder().encode(settings)
        var oldJSON = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        oldJSON.removeValue(forKey: "applyDaylightSavingTime")
        let legacy = try JSONDecoder().decode(PresetSettings.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        precondition(legacy.usesDaylightSavingTime && legacy == settings)
        settings.applyDaylightSavingTime = false
        precondition(settings != legacy)
        let reloaded = try JSONDecoder().decode(PresetSettings.self, from: JSONEncoder().encode(settings))
        precondition(!reloaded.usesDaylightSavingTime)
        print("PASS: \(cities.count) cities; bilingual country names/aliases/codes, multi-zone country filtering, no US/Australia collision, city search, UTC grouping, DST and preset migration")
    }
}
