import Foundation

/// Shared by preview, filename planning and metadata writing.
struct CaptureTimeZonePolicy {
    let timeZone: TimeZone
    let applyDaylightSavingTime: Bool

    init(timeZone: TimeZone, applyDaylightSavingTime: Bool = true) {
        self.timeZone = timeZone
        self.applyDaylightSavingTime = applyDaylightSavingTime
    }

    init?(identifier: String, applyDaylightSavingTime: Bool = true) {
        guard let zone = TimeZone(identifier: identifier) else { return nil }
        self.init(timeZone: zone, applyDaylightSavingTime: applyDaylightSavingTime)
    }

    func offsetSeconds(on date: Date) -> Int {
        let offset = timeZone.secondsFromGMT(for: date)
        return applyDaylightSavingTime ? offset
            : offset - Int(timeZone.daylightSavingTimeOffset(for: date))
    }

    func effectiveTimeZone(on date: Date) -> TimeZone {
        applyDaylightSavingTime ? timeZone
            : TimeZone(secondsFromGMT: offsetSeconds(on: date)) ?? timeZone
    }

    func isDSTApplied(on date: Date) -> Bool {
        applyDaylightSavingTime && timeZone.isDaylightSavingTime(for: date)
    }

    func absoluteDate(from components: DateComponents) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let approximate = calendar.date(from: components) else { return nil }
        calendar.timeZone = effectiveTimeZone(on: approximate)
        return calendar.date(from: components)
    }
}
