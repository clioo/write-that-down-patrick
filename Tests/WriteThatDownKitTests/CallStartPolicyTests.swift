import XCTest
@testable import WriteThatDownKit

final class CallStartPolicyTests: XCTestCase {
    private let policy = CallStartPolicy()

    private func sample(
        bundleID: String?,
        applicationBundleID: String? = nil,
        name: String? = nil,
        title: String? = nil
    ) -> MicActivitySample {
        MicActivitySample(
            isActive: true,
            attribution: .attributed,
            sources: [MicActivitySource(
                pid: 42,
                bundleID: bundleID,
                applicationBundleID: applicationBundleID,
                displayName: name,
                windowTitle: title
            )]
        )
    }

    func testZoomAutoStarts() {
        let decision = policy.decision(for: sample(bundleID: "us.zoom.xos", name: "zoom.us"))
        guard case let .automatic(context) = decision else {
            return XCTFail("Zoom must auto-start")
        }
        XCTAssertEqual(context.kind, .zoom)
    }

    func testTeamsHelperAutoStartsThroughNormalizedOwner() {
        let decision = policy.decision(for: sample(
            bundleID: "com.microsoft.teams2.helper",
            applicationBundleID: "com.microsoft.teams2",
            name: "Microsoft Teams"
        ))
        guard case let .automatic(context) = decision else {
            return XCTFail("Teams must auto-start")
        }
        XCTAssertEqual(context.kind, .teams)
    }

    func testBrowserAutoStartsOnlyWhenWindowTitleIndicatesGoogleMeet() {
        let meet = policy.decision(for: sample(
            bundleID: "com.brave.Browser.helper",
            applicationBundleID: "com.brave.Browser",
            name: "Brave Browser",
            title: "Weekly sync — Google Meet"
        ))
        guard case let .automatic(context) = meet else {
            return XCTFail("verified Google Meet browser window must auto-start")
        }
        XCTAssertEqual(context.kind, .googleMeet)

        let other = policy.decision(for: sample(
            bundleID: "com.brave.Browser.helper",
            applicationBundleID: "com.brave.Browser",
            name: "Brave Browser",
            title: "WhatsApp"
        ))
        guard case let .requiresConfirmation(otherContext) = other else {
            return XCTFail("an unverified browser tab must require confirmation")
        }
        XCTAssertEqual(otherContext.kind, .browser)
    }

    func testMeetHostInWindowTitleAutoStarts() {
        let decision = policy.decision(for: sample(
            bundleID: "com.google.Chrome.helper",
            applicationBundleID: "com.google.Chrome",
            title: "meet.google.com/abc-defg-hij"
        ))
        guard case let .automatic(context) = decision else {
            return XCTFail("Meet hostname evidence must auto-start")
        }
        XCTAssertEqual(context.kind, .googleMeet)
    }

    func testWhatsAppAndUnknownSourcesRequireConfirmation() {
        let whatsApp = policy.decision(for: sample(
            bundleID: "net.whatsapp.WhatsApp",
            name: "WhatsApp"
        ))
        guard case let .requiresConfirmation(context) = whatsApp else {
            return XCTFail("WhatsApp must require confirmation")
        }
        XCTAssertEqual(context.kind, .whatsApp)

        let unknown = policy.decision(for: sample(bundleID: nil))
        guard case let .requiresConfirmation(unknownContext) = unknown else {
            return XCTFail("unknown sources must require confirmation")
        }
        XCTAssertEqual(unknownContext.kind, .unknown)
    }

    func testUnattributedMacOS13SignalRequiresConfirmation() {
        let decision = policy.decision(for: .unattributed(active: true))
        guard case let .requiresConfirmation(context) = decision else {
            return XCTFail("unattributed microphone use must require confirmation")
        }
        XCTAssertEqual(context.kind, .unknown)
    }

    func testLegacyBoolSignalRetainsAutomaticSemantics() {
        let decision = policy.decision(for: .legacy(active: true))
        guard case let .automatic(context) = decision else {
            return XCTFail("legacy Bool tests must remain automatic")
        }
        XCTAssertEqual(context.kind, .legacy)
    }
}
