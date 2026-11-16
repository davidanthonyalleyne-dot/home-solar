import XCTest

// Drives the Apple TV app with the Siri Remote's buttons, on sample data, and records where
// focus lands after every press (TVTEST lines in the log) with screenshots along the way.

final class TVRemoteTests: XCTestCase {
    let remote = XCUIRemote.shared

    func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-previewTV"] + args
        app.launch()
        sleep(4)
        return app
    }
    func focused(_ app: XCUIApplication) -> String {
        let e = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        guard e.exists else { return "nothing" }
        return e.identifier.isEmpty ? (e.label.isEmpty ? "\(e.elementType)" : e.label) : e.identifier
    }
    func press(_ app: XCUIApplication, _ b: XCUIRemote.Button, _ n: Int = 1, _ note: String) -> [String] {
        var out: [String] = []
        for _ in 0..<n { remote.press(b); usleep(450_000); out.append(focused(app)) }
        print("TVTEST \(note):", out.joined(separator: " → "))
        return out
    }
    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testMonthChartDays() {
        let app = launch(["-month"])
        print("TVTEST month start:", focused(app))
        _ = press(app, .down, 3, "down into the month")
        shot("month-chart")
        let left = press(app, .left, 6, "left along the days")
        shot("month-after-left")
        XCTAssertTrue(left.allSatisfy { $0.hasPrefix("day-") }, "left should stay on the days, not leave the chart: \(left)")
        XCTAssertEqual(Set(left).count, left.count, "each press should land on a different day: \(left)")
        let right = press(app, .right, 3, "right along the days")
        XCTAssertTrue(right.allSatisfy { $0.hasPrefix("day-") })
        _ = press(app, .up, 2, "up to the month buttons")
        shot("month-buttons")
        _ = press(app, .select, 1, "select a month button")
        shot("month-other-month")
    }

    func testEveryTab() {
        let app = launch([])
        print("TVTEST now start:", focused(app))
        shot("now")
        _ = press(app, .down, 2, "now: down to the tiles")
        _ = press(app, .right, 3, "now: along the tiles")
        shot("now-tiles")
        for tab in ["month", "history", "ask", "settings"] {
            _ = press(app, .up, 4, "\(tab): up to the tab bar")
            _ = press(app, .right, 1, "\(tab): next tab")
            sleep(1)
            _ = press(app, .down, 3, "\(tab): down into it")
            shot(tab)
        }
    }
}
