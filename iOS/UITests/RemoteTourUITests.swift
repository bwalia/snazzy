import XCTest

/// Taps through every feature of the remote, against a Mac running Snazzy Pro
/// (`SnazzyPro --self-test --remote-tour`). Pass the pairing link with
/// `TEST_RUNNER_TOUR_PAIR_URL=snazzypro://pair?...` to xcodebuild. Screenshots
/// are attached at each step; on a simulator the run can be filmed for tours.
@MainActor
final class RemoteTourUITests: XCTestCase {
    func testRemoteTour() throws {
        continueAfterFailure = false
        let pairURL = try XCTUnwrap(ProcessInfo.processInfo.environment["TOUR_PAIR_URL"], "Set TEST_RUNNER_TOUR_PAIR_URL")
        let app = XCUIApplication()
        app.launchArguments += ["-debugPairURL", pairURL]
        app.launch()

        // Paired and connected: the Mac's status and the open deck appear.
        let record = app.buttons["Record"]
        XCTAssertTrue(record.waitForExistence(timeout: 40), "Didn't connect to the Mac")
        XCTAssertTrue(app.staticTexts["Ready"].exists)
        snap(app, "1 Connected")
        pause(2.5)

        // Slides
        let next = app.buttons["Next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap(); pause(2)
        next.tap(); pause(2)
        snap(app, "2 Slide 3 with notes")
        app.buttons["Previous"].tap(); pause(2)

        // Teleprompter text size
        app.buttons["Larger text"].tap(); pause(0.6)
        app.buttons["Larger text"].tap(); pause(1.5)
        snap(app, "3 Larger teleprompter")
        app.buttons["Smaller text"].tap(); app.buttons["Smaller text"].tap(); pause(1)

        // Recording: start (the Mac counts down), pause, resume, stop
        record.tap()
        let pauseButton = app.buttons["Pause"]
        XCTAssertTrue(pauseButton.waitForExistence(timeout: 15), "Recording didn't start")
        snap(app, "4 Recording")
        next.tap(); pause(2.5)
        pauseButton.tap()
        let resume = app.buttons["Resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        snap(app, "5 Paused"); pause(2)
        resume.tap(); pause(2.5)
        next.tap(); pause(2)
        app.buttons["Stop"].tap()
        XCTAssertTrue(record.waitForExistence(timeout: 20), "Recording didn't stop")
        pause(2)

        // Assistant
        app.buttons["Assistant"].tap()
        let field = app.textFields["chatField"].exists ? app.textFields["chatField"] : app.textViews["chatField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Go back to the first slide, please.")
        app.buttons["Send"].tap()
        snap(app, "6 Asked the assistant")
        // The reply comes from the Mac's model; give it time.
        XCTAssertTrue(app.staticTexts["assistantReply"].waitForExistence(timeout: 240), "No reply from the assistant")
        pause(4)
        snap(app, "7 Assistant replied")
    }

    private func pause(_ s: Double) { Thread.sleep(forTimeInterval: s) }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
