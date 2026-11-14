import Foundation
import Testing
@testable import StewardCore

struct CheckInTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func nextIsTheLaterWindowToday() {
        #expect(CheckInWindows.standard.next(after: date(14, 10), calendar: calendar) == date(14, 13))
    }

    @Test func exactlyOnAWindowMovesToTheNextOne() {
        #expect(CheckInWindows.standard.next(after: date(14, 13), calendar: calendar) == date(14, 18))
    }

    @Test func afterTheLastWindowGoesToTomorrowMorning() {
        #expect(CheckInWindows.standard.next(after: date(14, 21, 30), calendar: calendar) == date(15, 9))
    }

    @Test func hoursAreCleanedAndSorted() {
        #expect(CheckInWindows(hours: [18, 9, 9, 25, -1]).hours == [9, 18])
    }

    @Test func emptyHoursFallBackToStandard() {
        #expect(CheckInWindows(hours: []).next(after: date(14, 7), calendar: calendar) == date(14, 9))
    }

    @Test func messageCountsWithoutSayingWhat() {
        #expect(CheckInSummary.message(waitingOnOwner: 0) == nil)
        #expect(CheckInSummary.message(waitingOnOwner: 1) == "One errand needs you before Steward can carry on.")
        #expect(CheckInSummary.message(waitingOnOwner: 3) == "3 errands need you before Steward can carry on.")
    }
}
