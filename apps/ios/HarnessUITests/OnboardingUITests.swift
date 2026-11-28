import XCTest

@MainActor
final class OnboardingUITests: XCTestCase {
    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-demo", scenario, "-sethomefilter", "", "-phoneSplit", "off"]
        app.launch()
        return app
    }

    private func agent(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)["onboarding-agent-\(id)"]
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNoComputerExplainsWhatToDoAndOffersTheLink() {
        let app = launch("-onboarding-nocomputer")
        XCTAssertTrue(app.staticTexts["Bring in your agent"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Get Harness on your computer"].exists)
        XCTAssertTrue(app.buttons["onboarding-copy-link"].exists)
        XCTAssertTrue(app.buttons["onboarding-share-link"].exists)
        for id in ["graff", "claude-code", "codex"] {
            XCTAssertTrue(agent(app, id).waitForExistence(timeout: 5), id)
            XCTAssertTrue(agent(app, id).label.contains("Needs a computer"), "\(id): \(agent(app, id).label)")
        }
    }

    func testAComputerWithNoAgentReadySaysWhatIsMissingOnIt() {
        let app = launch("-onboarding-noagent")
        XCTAssertTrue(app.staticTexts["Bring in your agent"].waitForExistence(timeout: 10))
        // A computer is online, so there is no download prompt.
        XCTAssertFalse(app.staticTexts["Get Harness on your computer"].exists)
        XCTAssertTrue(agent(app, "graff").waitForExistence(timeout: 5))
        XCTAssertEqual(agent(app, "graff").value as? String, "off")
        XCTAssertTrue(agent(app, "graff").label.contains("Switched off on MacBook Pro"))
        XCTAssertEqual(agent(app, "claude-code").value as? String, "canInstall")
        XCTAssertTrue(agent(app, "claude-code").label.contains("Not installed on MacBook Pro"))
        XCTAssertEqual(agent(app, "codex").value as? String, "missing")
        XCTAssertTrue(agent(app, "codex").label.contains("Not found on MacBook Pro"))
    }

    func testPhoneOnlyCloudStartWaitsForGraffAndOpensTheFirstChat() {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-demo", "-onboarding-nocomputer", "-demo-phone-cloud",
                              "-sethomefilter", "", "-phoneSplit", "off",
                              "-autosend", "-autosendtext", "Reply OK"]
        app.launch()

        let start = app.buttons["onboarding-cloud-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(start.label.contains("$0.10/h"), start.label)
        keep(app, "phone-only-cloud-start")
        start.tap()
        let cancel = app.buttons["onboarding-cloud-cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertFalse(app.staticTexts["onboarding-cloud-status"].exists,
                       "cancel must not create or start a sandbox")

        start.tap()
        let confirm = app.buttons["onboarding-cloud-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let context = app.staticTexts["new-session-context"]
        XCTAssertTrue(context.waitForExistence(timeout: 15))
        XCTAssertTrue(context.label.contains("Harness phone"), context.label)
        let prompt = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Reply OK")).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 20), "first prompt was not sent")
        let reply = app.textViews.containing(NSPredicate(format: "label CONTAINS %@",
            "streamed reply renders on this device")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 30), "the scripted Graff reply did not arrive")
        keep(app, "phone-only-first-reply")
    }

    func testOnceAnAgentIsReadyHomeShowsItsPlainEmptyLine() {
        let app = launch("-onboarding-ready")
        XCTAssertTrue(app.staticTexts["home-empty"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Bring in your agent"].exists)
    }
}
