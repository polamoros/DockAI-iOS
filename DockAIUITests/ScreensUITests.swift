import XCTest

/// Walks the iPhone app against the test server (ci/mock-server.mjs) and
/// photographs every screen it reaches — the app's equivalent of the web
/// dashboard's design gate. Screenshots are attachments named in order; the
/// workflow exports them. A screen that shows an error is usually a procedure
/// the server listed in ci/out/missing.json.
final class ScreensUITests: XCTestCase {
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
        a.name = String(format: "%02d %@", n, name.replacingOccurrences(of: "/", with: " — "))
        a.lifetime = .keepAlways
        add(a)
    }

    private func settle(_ seconds: UInt32 = 2) { sleep(seconds) }

    private func back() {
        let b = app.navigationBars.buttons.element(boundBy: 0)
        if b.exists && b.isHittable { b.tap(); settle(1) }
    }

    /// Every row of the current list that leads somewhere: open, photograph, come back.
    private func crawl(_ prefix: String, limit: Int = 30) {
        let count = min(app.cells.count, limit)
        for i in 0..<count {
            let cell = app.cells.element(boundBy: i)
            guard cell.exists, cell.isHittable else { continue }
            // Rows that act rather than lead somewhere are never tapped: a
            // live run walks the real server (audit M5).
            if ["Sign out", "Delete", "Remove", "Revoke", "Disconnect", "Unlink", "Restart", "Stop", "Kill", "End"]
                .contains(where: { cell.label.localizedCaseInsensitiveContains($0) }) { continue }
            let label = cell.label.components(separatedBy: ",").first.map { String($0.prefix(40)) } ?? "row \(i)"
            let before = app.navigationBars.firstMatch.identifier
            cell.tap(); settle()
            if app.navigationBars.firstMatch.identifier != before {
                shot("\(prefix)/\(label)")
                back()
            }
        }
    }

    func test1Projects() {
        settle(3); shot("projects/list")
        // The test server's first project, or the live test user's project.
        let name = ProcessInfo.processInfo.environment["DOCKAI_TEST_PROJECT"] ?? "Weather station"
        let project = app.staticTexts[name].firstMatch
        guard project.waitForExistence(timeout: 10) else { XCTFail("no project listed"); return }
        project.tap(); settle(3)
        guard app.buttons["tab-overview"].waitForExistence(timeout: 10) else { XCTFail("the project did not open"); return }
        shot("project/overview")
        for tab in ["conversations", "terminal", "agent", "browser", "services", "logs", "settings"] {
            let b = app.buttons["tab-\(tab)"]
            // The tab strip scrolls sideways; bring the tab into view.
            var tries = 0
            while !b.isHittable && tries < 4 {
                // Drag along the strip's own row: the element being scrolled
                // to is off screen, so it cannot be swiped itself.
                let row = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 0, dy: b.frame.midY))
                row.withOffset(CGVector(dx: 330, dy: 0)).press(forDuration: 0.05, thenDragTo: row.withOffset(CGVector(dx: 60, dy: 0)))
                tries += 1
            }
            guard b.exists, b.isHittable else { XCTFail("the \(tab) tab cannot be reached"); continue }
            b.tap(); settle(3)
            shot("project/\(tab)")
            if tab == "settings" { crawl("project settings") }
        }
    }

    func test2Settings() {
        app.tabBars.buttons["Settings"].tap(); settle(3)
        shot("settings/root")
        crawl("settings")
    }

    func test3Admin() throws {
        let tab = app.tabBars.buttons["Admin"]
        if ProcessInfo.processInfo.environment["DOCKAI_LIVE"] == "1" && !tab.waitForExistence(timeout: 5) {
            throw XCTSkip("The live test user is not an admin; Admin is walked against the test server.")
        }
        guard tab.waitForExistence(timeout: 5) else { XCTFail("no Admin tab — is the test user an admin?"); return }
        tab.tap(); settle(3)
        shot("admin/root")
        crawl("admin")
    }
}
