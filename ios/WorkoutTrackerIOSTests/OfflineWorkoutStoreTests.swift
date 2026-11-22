import XCTest
@testable import WorkoutTrackerIOS

/// Upload queue behaviour against a stubbed server (the real backend contract is covered by the
/// backend's logWorkout tests and the web e2e suite).
@MainActor
final class OfflineWorkoutStoreTests: XCTestCase {
    private var file: URL!
    private var store: OfflineWorkoutStore!

    override func setUp() async throws {
        StubURLProtocol.install()
        file = Fixtures.tempFile()
        store = OfflineWorkoutStore(fileURL: file)
        store.apiProvider = { WorkoutAPI(endpoint: "https://example.test/graphql", token: "session-token") }
    }

    private func finishQuickWorkout() {
        store.startWorkout(from: Fixtures.prescription())
        while let position = store.activeWorkout?.pendingSetPosition() {
            store.completeSet(at: position, reps: 10)
        }
        store.finishActiveWorkout()
    }

    func testOfflineFinishKeepsWorkoutQueued() async {
        StubURLProtocol.handler = { _ in .failure(.notConnectedToInternet) }
        finishQuickWorkout()
        let attempted = await waitUntil { self.store.outbox.first?.attempts == 1 }
        XCTAssertTrue(attempted)
        XCTAssertNil(store.activeWorkout)
        XCTAssertEqual(store.outbox.count, 1)
        XCTAssertFalse(store.outbox[0].needsAttention, "connectivity failures are retried, not flagged")
        XCTAssertNil(store.cachedPrescription, "next workout is unknown until this one uploads")
    }

    func testQueueSurvivesRelaunchAndDrainsWhenOnline() async {
        StubURLProtocol.handler = { _ in .failure(.timedOut) }
        finishQuickWorkout()
        _ = await waitUntil { self.store.outbox.first?.attempts == 1 }

        let relaunched = OfflineWorkoutStore(fileURL: file)
        XCTAssertEqual(relaunched.outbox.count, 1)
        relaunched.apiProvider = { WorkoutAPI(endpoint: "https://example.test/graphql", token: "session-token") }
        let record: [String: Any] = ["exerciseName": "Squat", "kind": "WEIGHT", "valueKg": 100, "reps": 3, "previousKg": 95]
        StubURLProtocol.handler = { _ in .json(["data": ["logWorkout": Fixtures.sessionJSON(records: [record])]]) }

        await relaunched.syncNow()
        XCTAssertTrue(relaunched.outbox.isEmpty)
        XCTAssertEqual(relaunched.lastUpload?.personalRecords.first?.valueKg, 100)
        XCTAssertEqual(relaunched.lastUpload?.wasQueued, true)

        let upload = StubURLProtocol.requests.last { $0.query.contains("logWorkout") }
        XCTAssertEqual(upload?.authorization, "Bearer session-token")
        let input = upload?.variables["input"] as? [String: Any]
        XCTAssertEqual(input?["planWorkoutId"] as? Int, 10)
        XCTAssertNotNil(input?["clientId"] as? String, "uploads carry an idempotency key")
    }

    func testServerRejectionNeedsAttentionAndDoesNotBlockQueue() async {
        StubURLProtocol.handler = { _ in .json(["data": NSNull(), "errors": [["message": "plan_workout_id not found"]]]) }
        finishQuickWorkout()
        let flagged = await waitUntil { self.store.outbox.first?.needsAttention == true }
        XCTAssertTrue(flagged)
        XCTAssertEqual(store.outbox[0].lastError, "plan_workout_id not found")

        // Retry after the problem is fixed server-side.
        StubURLProtocol.handler = { _ in .json(["data": ["logWorkout": Fixtures.sessionJSON()]]) }
        store.retry(store.outbox[0])
        let drained = await waitUntil { self.store.outbox.isEmpty }
        XCTAssertTrue(drained)
    }

    func testSignedOutUploadWaitsAndAsksForSignIn() async {
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        store.apiProvider = { WorkoutAPI(endpoint: "https://example.test/graphql", token: nil) { flag.fired = true } }
        StubURLProtocol.handler = { _ in
            .json(["data": NSNull(), "errors": [["message": "Sign in required", "extensions": ["code": "UNAUTHENTICATED"]]]])
        }
        finishQuickWorkout()
        _ = await waitUntil { self.store.outbox.first?.attempts == 1 }
        XCTAssertTrue(flag.fired, "the app shows the sign-in sheet")
        XCTAssertFalse(store.outbox[0].needsAttention, "kept for after sign-in, not flagged as broken")
    }

    func testDiscardingResumedServerWorkoutCancelsItOnTheServer() async throws {
        let session = try JSONDecoder.iso8601.decode(
            WorkoutSession.self,
            from: JSONSerialization.data(withJSONObject: Fixtures.sessionJSON(id: 42))
        )
        StubURLProtocol.handler = { request in
            request.query.contains("cancelWorkout")
                ? .json(["data": ["cancelWorkout": ["ok": true, "message": "Workout discarded"]]])
                : .failure(.badServerResponse)
        }
        store.resumeServerWorkout(session, planName: "Plan")
        XCTAssertEqual(store.activeWorkout?.serverSessionId, 42)
        store.discardActiveWorkout()
        let sent = await waitUntil { self.store.outbox.isEmpty }
        XCTAssertTrue(sent)
        XCTAssertEqual(StubURLProtocol.requests.last?.variables["sessionId"] as? Int, 42)
    }

    func testDiscardingLocalWorkoutQueuesNothing() {
        store.startWorkout(from: Fixtures.prescription())
        store.discardActiveWorkout()
        XCTAssertNil(store.activeWorkout)
        XCTAssertTrue(store.outbox.isEmpty)
    }
}
