//
//  AnyNotifyUITestsLaunchTests.swift
//  AnyNotifyUITests
//
//  Created by mengfs on 7/22/26.
//

import XCTest

final class AnyNotifyUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-UITestMode")
        app.launch()
        XCTAssertNotEqual(app.state, .notRunning)
    }
}
