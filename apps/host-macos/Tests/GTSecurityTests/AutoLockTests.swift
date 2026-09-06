import XCTest
@testable import GTSecurity

@MainActor
final class AutoLockTests: XCTestCase {
    func testStartsLocked() {
        let lock = AutoLock(idleTimeout: 60)
        XCTAssertTrue(lock.isLocked)
    }

    func testHeartbeatUnlocks() {
        let lock = AutoLock(idleTimeout: 60)
        let expectation = XCTestExpectation(description: "onUnlock fires")
        lock.onUnlock = { expectation.fulfill() }
        lock.heartbeat()
        wait(for: [expectation], timeout: 1.0)
        XCTAssertFalse(lock.isLocked)
    }

    func testForceLockAfterUnlock() {
        let lock = AutoLock(idleTimeout: 60)
        lock.heartbeat()
        XCTAssertFalse(lock.isLocked)
        let expectation = XCTestExpectation(description: "onLock fires")
        lock.onLock = { expectation.fulfill() }
        lock.forceLock()
        wait(for: [expectation], timeout: 1.0)
        XCTAssertTrue(lock.isLocked)
    }

    func testReadOnlyToggle() {
        let lock = AutoLock()
        XCTAssertFalse(lock.isReadOnly)
        lock.setReadOnly(true)
        XCTAssertTrue(lock.isReadOnly)
        lock.setReadOnly(false)
        XCTAssertFalse(lock.isReadOnly)
    }

    func testOnlyHostPolicyChangesPublishAndDoNotEraseBrowserRestrictions() {
        let lock = AutoLock()
        var changes = 0
        lock.onReadOnlyChange = { changes += 1 }
        lock.setClientReadOnly(true, deviceID: "first")
        XCTAssertEqual(changes, 0)
        XCTAssertTrue(lock.isReadOnly(for: "first"))
        XCTAssertFalse(lock.isReadOnly(for: "second"))
        lock.setReadOnly(true)
        lock.setReadOnly(true)
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(lock.isReadOnly(for: "second"))
        lock.setReadOnly(false)
        XCTAssertEqual(changes, 2)
        XCTAssertTrue(lock.isReadOnly(for: "first"))
        XCTAssertFalse(lock.isReadOnly(for: "second"))
    }
}
