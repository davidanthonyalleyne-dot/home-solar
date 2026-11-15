import XCTest

// Taps and drags the real tab bar the way a thumb does, on sample data, and fails if the app
// stops running. On iOS 26 the bar is Liquid Glass, which also lets you slide between tabs.
final class TabBarTests: XCTestCase {
    let names = ["Now", "Month", "History", "Ask", "Settings"]

    func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-previewNow"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20) || app.buttons["Month"].waitForExistence(timeout: 5))
        return app
    }

    func button(_ app: XCUIApplication, _ n: String) -> XCUIElement {
        let b = app.tabBars.buttons[n]
        return b.exists ? b : app.buttons[n].firstMatch
    }

    func alive(_ app: XCUIApplication, _ step: String) {
        XCTAssertEqual(app.state, .runningForeground, "Solar stopped after: \(step)")
    }

    func testTapEveryTab() {
        let app = launch()
        for round in 0..<3 {
            for n in names + names.reversed() {
                button(app, n).tap()
                alive(app, "tap \(n) round \(round)")
            }
        }
    }

    func testScrollThenTap() {
        let app = launch()
        for n in names {
            button(app, n).tap()
            app.swipeUp(); app.swipeUp()
            alive(app, "scroll \(n)")
            app.swipeDown()
        }
        for n in names.reversed() { button(app, n).tap(); alive(app, "tap after scroll \(n)") }
    }

    func testFastTaps() {
        let app = launch()
        let pts = names.map { button(app, $0) }
        for i in 0..<40 {
            pts[(i * 3) % 5].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            alive(app, "fast tap \(i) on \(names[(i * 3) % 5])")
        }
    }

    func testSlideAcrossBar() {
        let app = launch()
        let first = button(app, "Now"), last = button(app, "Settings")
        for i in 0..<6 {
            let a = (i % 2 == 0 ? first : last).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let b = (i % 2 == 0 ? last : first).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            a.press(forDuration: 0.4, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0.2)
            alive(app, "slide \(i)")
            let mid = button(app, names[1 + i % 3]).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            a.press(forDuration: 0.2, thenDragTo: mid)
            alive(app, "slide to middle \(i)")
        }
    }

    func testRotateAndTap() {
        let app = launch()
        for o in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = o
            for n in names { button(app, n).tap(); alive(app, "tap \(n) in \(o.rawValue)") }
        }
    }
}
