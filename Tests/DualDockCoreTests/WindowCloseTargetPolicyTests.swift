import XCTest
@testable import DualDockCore

final class WindowCloseTargetPolicyTests: XCTestCase {
    private let frame = CGRect(x: 20, y: 40, width: 600, height: 400)
    private let app = AppReference(id: "test.app", name: "App", path: "/Applications/App.app")

    private func candidate(_ id: UInt32?, title: String? = "Document", frame: CGRect? = nil) -> WindowCloseTargetPolicy.Candidate {
        .init(windowID: id, title: title, frame: frame ?? self.frame)
    }

    func testExactIDWinsWhenTwoWindowsShareTheirTitleAndFrame() {
        XCTAssertEqual(WindowCloseTargetPolicy.candidateIndex(windowID: 11, rawTitle: "Document", frame: frame,
                                                              candidates: [candidate(12), candidate(11)]), 1)
    }

    func testStaleIDNeverFallsBackToSameTitleReplacement() {
        XCTAssertNil(WindowCloseTargetPolicy.candidateIndex(windowID: 11, rawTitle: "Document", frame: frame,
                                                            candidates: [candidate(12), candidate(nil)]))
    }

    func testExactIDAllowsWindowTitleOrGeometryChanges() {
        XCTAssertEqual(WindowCloseTargetPolicy.candidateIndex(windowID: 11, rawTitle: "Document", frame: frame,
                                                              candidates: [candidate(11, title: "Renamed", frame: frame.offsetBy(dx: 200, dy: 20))]), 0)
    }

    func testFallbackNeedsTheOriginalLiveCGWindowAsUniqueMatch() {
        XCTAssertTrue(WindowCloseTargetPolicy.fallbackSourceIsUnique(windowID: 11, rawTitle: "Document", frame: frame,
                                                                     windows: [candidate(11), candidate(12, title: "Another")]))
        XCTAssertFalse(WindowCloseTargetPolicy.fallbackSourceIsUnique(windowID: 11, rawTitle: "Document", frame: frame,
                                                                      windows: [candidate(11), candidate(12)]))
    }

    func testFallbackRejectsOriginalMovedAndReplacementAtOldPosition() {
        let moved = candidate(11, frame: frame.offsetBy(dx: 50, dy: 0))
        XCTAssertFalse(WindowCloseTargetPolicy.fallbackSourceIsUnique(windowID: 11, rawTitle: "Document", frame: frame,
                                                                      windows: [moved, candidate(12)]))
        XCTAssertFalse(WindowCloseTargetPolicy.fallbackSourceIsUnique(windowID: 11, rawTitle: "Document", frame: frame,
                                                                      windows: [candidate(11, title: "Renamed")]))
    }

    func testFallbackRejectsIncompleteWindowServerEvidence() {
        for incomplete in [candidate(11, title: nil), .init(windowID: 11, title: "Document", frame: nil)] {
            XCTAssertFalse(WindowCloseTargetPolicy.fallbackSourceIsUnique(windowID: 11, rawTitle: "Document", frame: frame,
                                                                          windows: [incomplete]))
        }
        XCTAssertFalse(WindowCloseTargetPolicy.fallbackSourceIsUnique(windowID: 11, rawTitle: "Document", frame: frame,
                                                                      windows: [candidate(11), candidate(12, title: nil)]))
        XCTAssertTrue(WindowCloseTargetPolicy.fallbackSourceIsUnique(windowID: 11, rawTitle: "Document", frame: frame,
                                                                     windows: [candidate(11), candidate(12, title: nil, frame: frame.offsetBy(dx: 50, dy: 0))]))
    }

    func testUnavailableIDMappingRequiresUniqueTitleAndFrameTogether() {
        XCTAssertEqual(WindowCloseTargetPolicy.candidateIndex(windowID: 11, rawTitle: "Document", frame: frame,
                                                              candidates: [candidate(nil), candidate(nil, frame: frame.offsetBy(dx: 200, dy: 0))]), 0)
        XCTAssertNil(WindowCloseTargetPolicy.candidateIndex(windowID: 11, rawTitle: "Document", frame: frame,
                                                            candidates: [candidate(nil), candidate(nil)]))
        XCTAssertNil(WindowCloseTargetPolicy.candidateIndex(windowID: 11, rawTitle: "Document", frame: frame,
                                                            candidates: [candidate(nil, frame: frame.offsetBy(dx: 20, dy: 0))]))
    }

    func testFallbackDisplayNameIsNotAWindowIdentity() {
        for title: String? in [nil, "", "  "] {
            XCTAssertNil(WindowCloseTargetPolicy.candidateIndex(windowID: 11, rawTitle: title, frame: frame,
                                                                candidates: [candidate(nil, title: "App")]))
        }
    }

    func testMissingOrInvalidGeometryDoesNotAuthorizeFallback() {
        XCTAssertNil(WindowCloseTargetPolicy.candidateIndex(windowID: 11, rawTitle: "Document", frame: .zero,
                                                            candidates: [candidate(nil)]))
        XCTAssertNil(WindowCloseTargetPolicy.candidateIndex(windowID: 11, rawTitle: "Document", frame: frame,
                                                            candidates: [.init(windowID: nil, title: "Document", frame: nil)]))
        XCTAssertNil(WindowCloseTargetPolicy.candidateIndex(windowID: 0, rawTitle: "Document", frame: frame,
                                                            candidates: [candidate(nil)]))
    }

    func testAmbiguousExactIDsAreNotClosed() {
        XCTAssertNil(WindowCloseTargetPolicy.candidateIndex(windowID: 11, rawTitle: "Document", frame: frame,
                                                            candidates: [candidate(11), candidate(11)]))
    }

    func testProcessIdentityRejectsDifferentApplicationOrRestart() {
        let captured = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(WindowCloseTargetPolicy.matchesApplication(expected: app, capturedPath: app.path, capturedLaunchDate: captured,
                                                                  liveBundleID: app.id, livePath: app.path, liveLaunchDate: captured))
        XCTAssertFalse(WindowCloseTargetPolicy.matchesApplication(expected: app, capturedPath: app.path, capturedLaunchDate: captured,
                                                                   liveBundleID: "another.app", livePath: app.path, liveLaunchDate: captured))
        XCTAssertFalse(WindowCloseTargetPolicy.matchesApplication(expected: app, capturedPath: app.path, capturedLaunchDate: captured,
                                                                   liveBundleID: app.id, livePath: "/Other/App.app", liveLaunchDate: captured))
        XCTAssertFalse(WindowCloseTargetPolicy.matchesApplication(expected: app, capturedPath: app.path, capturedLaunchDate: captured,
                                                                   liveBundleID: app.id, livePath: app.path, liveLaunchDate: captured.addingTimeInterval(1)))
        XCTAssertFalse(WindowCloseTargetPolicy.matchesApplication(expected: app, capturedPath: app.path, capturedLaunchDate: captured,
                                                                   liveBundleID: app.id, livePath: app.path, liveLaunchDate: nil))
    }

    func testCapturedPathSupportsMovedAppWithoutPermittingAnotherProcess() {
        let moved = "/Applications/Folder/App.app"
        XCTAssertTrue(WindowCloseTargetPolicy.matchesApplication(expected: app, capturedPath: moved, capturedLaunchDate: nil,
                                                                  liveBundleID: app.id, livePath: moved, liveLaunchDate: nil))
        XCTAssertFalse(WindowCloseTargetPolicy.matchesApplication(expected: app, capturedPath: moved, capturedLaunchDate: nil,
                                                                   liveBundleID: app.id, livePath: app.path, liveLaunchDate: nil))
        let pathIdentified = AppReference(id: moved, name: "App", path: moved)
        XCTAssertTrue(WindowCloseTargetPolicy.matchesApplication(expected: pathIdentified, capturedPath: moved, capturedLaunchDate: nil,
                                                                  liveBundleID: nil, livePath: moved, liveLaunchDate: nil))
    }
}
