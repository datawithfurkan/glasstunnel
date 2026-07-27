import XCTest
@testable import GTTransport

@MainActor
final class AsyncLatestStateReconcilerTests: XCTestCase {
    func testStopWaitsForInFlightStartWithoutOverlapping() async {
        var activeReconciles = 0
        var maxActiveReconciles = 0
        var reconciledStates: [String] = []
        var releaseStart: CheckedContinuation<Void, Never>?
        let startBegan = expectation(description: "start reconciliation began")

        let reconciler = AsyncLatestStateReconciler(initialValue: "idle") { state in
            activeReconciles += 1
            maxActiveReconciles = max(maxActiveReconciles, activeReconciles)
            reconciledStates.append(state)
            if state == "start" {
                await withCheckedContinuation { continuation in
                    releaseStart = continuation
                    startBegan.fulfill()
                }
            }
            activeReconciles -= 1
        }

        reconciler.setDesired("start")
        await fulfillment(of: [startBegan], timeout: 1)
        reconciler.setDesired("stop")
        releaseStart?.resume()
        await reconciler.waitUntilSettled()

        XCTAssertEqual(reconciledStates, ["start", "stop"])
        XCTAssertEqual(maxActiveReconciles, 1)
    }

    func testRapidStopRestartReconcilesOnlyLatestPendingState() async {
        var reconciledStates: [String] = []
        var releaseStart: CheckedContinuation<Void, Never>?
        let startBegan = expectation(description: "start reconciliation began")

        let reconciler = AsyncLatestStateReconciler(initialValue: "idle") { state in
            reconciledStates.append(state)
            if reconciledStates.count == 1 {
                await withCheckedContinuation { continuation in
                    releaseStart = continuation
                    startBegan.fulfill()
                }
            }
        }

        reconciler.setDesired("start")
        await fulfillment(of: [startBegan], timeout: 1)
        reconciler.setDesired("stop")
        reconciler.setDesired("restart")
        releaseStart?.resume()
        await reconciler.waitUntilSettled()

        XCTAssertEqual(reconciledStates, ["start", "restart"])
    }
}
