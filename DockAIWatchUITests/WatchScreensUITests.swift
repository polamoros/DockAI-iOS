import XCTest

/// The watch app's screens against the test server: Needs you, Ask,
/// Projects, Usage, and a project opened.
final class WatchScreensUITests: XCTestCase {
    private var app: XCUIApplication!
    private var n = 0

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["DOCKAI_TEST_SERVER"] = ProcessInfo.processInfo.environment["DOCKAI_TEST_SERVER"] ?? "http://127.0.0.1:8787"
        // Live runs (the workflow's `live` input) pass the test user's token
        // from a repository secret, as TEST_RUNNER_DOCKAI_TEST_TOKEN.
        app.launchEnvironment["DOCKAI_TEST_TOKEN"] = ProcessInfo.processInfo.environment["DOCKAI_TEST_TOKEN"] ?? "dka_test"
        app.launch()
    }

    private func shot(_ name: String) {
        n += 1
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = String(format: "watch-%02d-%@", n, name)
        a.lifetime = .keepAlways
        add(a)
    }

    func testTabs() {
        sleep(4); shot("first")
        // The tabs page vertically on watchOS; swipe through them.
        for i in 1...4 {
            app.swipeUp(); sleep(2); shot("page-\(i)")
        }
        // A project opened from the Projects page, if one is on screen.
        let row = app.buttons.element(boundBy: 0)
        if row.exists && row.isHittable { row.tap(); sleep(3); shot("opened") }
    }
}
