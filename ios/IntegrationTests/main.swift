// Live integration check: the iOS app's real sync code (models, GraphQL client, offline store)
// against a real backend. Run via scripts/test-ios-integration.sh (starts a throwaway server).

import Foundation

@MainActor
func check(_ cond: Bool, _ message: String) {
    if cond { print("  ✓ \(message)") } else { print("  ✗ \(message)"); exit(1) }
}

@MainActor
func run() async {
    let endpoint = ProcessInfo.processInfo.environment["WORKOUT_GRAPHQL_ENDPOINT"] ?? "http://127.0.0.1:8766/graphql"
    print("auth")
    final class Flag: @unchecked Sendable { var fired = false }
    let flag = Flag()
    let signedOut = WorkoutAPI(endpoint: endpoint, onUnauthorized: { flag.fired = true })
    do { _ = try await signedOut.fetchWorkoutPrescription(); check(false, "signed-out request rejected") }
    catch { check((error as? GraphQLClientError).map { if case .unauthorized = $0 { return true } else { return false } } ?? false, "signed out -> unauthorized") }
    check(flag.fired, "onUnauthorized hook fired (shows sign-in sheet)")
    let status = try! await signedOut.fetchAuthStatus()
    check(status.authRequired && !status.signedIn, "authStatus reachable while signed out")
    do { _ = try await signedOut.login(username: "sean", password: "wrong-password"); check(false, "wrong password") }
    catch { check(error.localizedDescription == "Incorrect username or password", "wrong password rejected") }
    let session = try! await signedOut.login(username: "Sean", password: "correct horse")
    check(!session.token.isEmpty && session.username == "sean", "login returns session token")
    let good = WorkoutAPI(endpoint: endpoint, token: session.token)
    let offline = WorkoutAPI(endpoint: "http://127.0.0.1:9/graphql", token: session.token)

    print("prescription")
    let rx = try! await good.fetchWorkoutPrescription()!
    check(rx.workoutName == "A" && rx.entries.first?.sets.count == 5, "prescription decoded (day A, 5 sets)")

    print("offline workout + queued upload")
    let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("harness-\(UUID()).json")
    var current = offline
    let store = OfflineWorkoutStore(fileURL: file)
    store.apiProvider = { current }
    store.cachePrescription(rx)
    store.startWorkout(from: rx)
    store.addExercise(name: "Plank", sets: 1, reps: 1, weightKg: 0)
    store.addSet(entryIndex: 0)
    var t = Date().addingTimeInterval(-600)
    while let pos = store.activeWorkout?.pendingSetPosition() {
        t = t.addingTimeInterval(60)
        store.appendHeartRate(bpm: 120, at: t)
        store.completeSet(at: pos, reps: 3, now: t)
    }
    store.undoLastSet()
    check(store.activeWorkout?.pendingSetPosition() != nil, "undo reopens the last set")
    store.completeSet(at: store.activeWorkout!.pendingSetPosition()!, reps: 4, now: t)
    store.finishActiveWorkout()
    try? await Task.sleep(for: .seconds(2))
    check(store.outbox.count == 1 && !store.outbox[0].needsAttention, "offline: upload stays queued (transient)")
    check(store.outbox[0].attempts >= 1, "offline: an attempt was made and failed")

    print("persistence across app restart")
    let reloaded = OfflineWorkoutStore(fileURL: file)
    check(reloaded.outbox.count == 1, "queue survives relaunch")
    current = good
    reloaded.apiProvider = { current }

    print("back online")
    await reloaded.syncNow()
    check(reloaded.outbox.isEmpty, "queue drained")
    check(reloaded.lastUpload?.workoutName == "A", "upload summary recorded")

    let history = try! await good.fetchWorkoutHistory(limit: 5)
    check(history.count == 1 && history[0].completedSets == 7, "server has the workout: 5 squat + 1 extra + 1 plank")
    check(history[0].exercises.map(\.exerciseName) == ["Squat", "Plank"], "added exercise logged by name")
    check(history[0].heartRateSampleCount == 7, "heart-rate samples uploaded")

    print("idempotent retry")
    var w = LocalWorkout(prescription: rx)
    w.finishedAt = Date()
    let first = try! await good.logWorkout(w)
    let second = try! await good.logWorkout(w)
    check(first.id == second.id, "same clientId returns the same session")

    print("permanent failure needs attention")
    var broken = LocalWorkout(prescription: rx)
    broken.entries[0].planWorkoutExerciseId = 99999
    broken.finishedAt = Date()
    let store2 = OfflineWorkoutStore(fileURL: file.appendingPathExtension("2"))
    store2.apiProvider = { good }
    store2.cachePrescription(rx)
    store2.startWorkout(from: rx)
    store2.discardActiveWorkout()
    check(store2.activeWorkout == nil && store2.outbox.isEmpty, "discarding a local-only workout queues nothing")
    do { _ = try await good.logWorkout(broken); check(false, "server rejects bogus exercise") }
    catch { check(!OfflineWorkoutStore.isTransient(error), "server rejection is not retried blindly: \(error.localizedDescription)") }

    print("resume a workout started on web")
    struct Started: Decodable { struct S: Decodable { struct E: Decodable { struct X: Decodable { let id: Int }; let sets: [X] }; let entries: [E] }; let startWorkout: S }
    let raw = GraphQLClient(endpoint: endpoint, token: session.token)
    let web = try! await raw.execute("mutation { startWorkout { entries { sets { id } } } }", dataType: Started.self)
    struct Done: Decodable { struct C: Decodable { let id: Int }; let completeSet: C }
    _ = try! await raw.execute("mutation($i: Int!) { completeSet(sessionSetId: $i, repsCompleted: 10) { id } }", variables: ["i": web.startWorkout.entries[0].sets[0].id], dataType: Done.self)
    let started = try! await good.fetchActiveSession()
    check(started != nil, "server-started session decoded")
    let store3 = OfflineWorkoutStore(fileURL: file.appendingPathExtension("3"))
    store3.apiProvider = { good }
    store3.resumeServerWorkout(started!, planName: "H")
    check(store3.activeWorkout?.completedSetCount == 1, "set already logged on web is kept")
    while let pos = store3.activeWorkout?.pendingSetPosition() { store3.completeSet(at: pos, reps: 10) }
    store3.finishActiveWorkout()
    try? await Task.sleep(for: .seconds(2))
    check(store3.outbox.isEmpty, "resumed workout uploaded")
    let after = try! await good.fetchActiveSession()
    check(after == nil, "server session is now completed")
    print("empty workout + skip")
    let store4 = OfflineWorkoutStore(fileURL: file.appendingPathExtension("4"))
    store4.apiProvider = { good }
    store4.startEmptyWorkout(name: "Hotel gym")
    store4.addExercise(name: "Push-up", sets: 2, reps: 10, weightKg: 0)
    store4.addExercise(name: "Dip", sets: 2, reps: 8, weightKg: 0)
    store4.completeSet(at: store4.activeWorkout!.pendingSetPosition()!, reps: 10)
    store4.skipExercise(entryIndex: 1)
    store4.finishActiveWorkout()
    _ = await { () async -> Bool in for _ in 0..<100 { if store4.outbox.isEmpty { return true }; try? await Task.sleep(for: .milliseconds(50)) }; return false }()
    check(store4.outbox.isEmpty, "empty workout uploaded")
    let latest = try! await good.fetchWorkoutHistory(limit: 1)[0]
    check(latest.planWorkoutName == "Hotel gym" && latest.planRunId == nil, "logged as ad-hoc, outside the plan")
    check(latest.completedSets == 1 && latest.totalSets == 4, "1 done, 1 open, 2 skipped")
    print("\nALL CHECKS PASSED")
}

Task { await run(); exit(0) }
RunLoop.main.run()
