// sources: companion_context_policy.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct CompanionContextPolicyTests {
    static let origin = Date(timeIntervalSince1970: 1_800_000_000)
    static func at(_ seconds: TimeInterval) -> Date {
        origin.addingTimeInterval(seconds)
    }

    static func compactPolicy() -> CompanionContextPolicy {
        CompanionContextPolicy(configuration: .init(
            rapidWindow: 180, rapidSwitchCount: 8,
            distractionWindow: 300, distractionEntryCount: 3,
            nudgeCooldown: 1_200, fatigueAfter: 5_400, fatigueCooldown: 5_400))
    }

    static func testRapidSwitchingNeedsARealBurst() {
        var policy = compactPolicy()
        for index in 0..<7 {
            expect(policy.observeTransition(to: "code", now: at(Double(index * 20))) == nil,
                   "seven switches should remain quiet")
        }
        expect(policy.observeTransition(to: "paper", now: at(140)) == .rapidSwitching,
               "the eighth switch inside three minutes should produce one quiet cue")
        expect(policy.observeTransition(to: "code", now: at(160)) == nil,
               "one more switch must not immediately repeat the cue")
    }

    static func testRepeatedDistractionIsRecognizedBeforeGenericThrashing() {
        var policy = compactPolicy()
        expect(policy.observeTransition(to: "distraction", now: at(0)) == nil, "first visit")
        expect(policy.observeTransition(to: "code", now: at(30)) == nil, "return to work")
        expect(policy.observeTransition(to: "distraction", now: at(60)) == nil, "second visit")
        expect(policy.observeTransition(to: "paper", now: at(90)) == nil, "return again")
        expect(policy.observeTransition(to: "distraction", now: at(120)) == .frequentDistraction,
               "three re-entries should be understood as frequent distraction")
    }

    static func testChangingTitlesInsideOnePlaceDoesNotInventSwitches() {
        var policy = compactPolicy()
        for index in 0..<12 {
            expect(policy.observeTransition(
                to: "paper", contextID: "com.browser|arxiv.org",
                now: at(Double(index * 10))) == nil,
                   "a dynamic title on one site must not look like context thrashing")
        }
        expect(policy.recentSwitchTimes.count == 1,
               "one stable semantic place should contribute one transition")
    }

    static func testNudgeCooldownRequiresANewPattern() {
        var policy = compactPolicy()
        for index in 0..<8 {
            _ = policy.observeTransition(to: "code", now: at(Double(index * 20)))
        }
        for index in 0..<8 {
            expect(policy.observeTransition(to: "paper", now: at(200 + Double(index * 20))) == nil,
                   "the twenty-minute cooldown should suppress another burst")
        }
        for index in 0..<7 {
            expect(policy.observeTransition(to: "code", now: at(1_400 + Double(index * 20))) == nil,
                   "a new post-cooldown burst should still accumulate normally")
        }
        expect(policy.observeTransition(to: "paper", now: at(1_540)) == .rapidSwitching,
               "a fresh full burst may gently cue again after cooldown")
    }

    static func testFatigueUsesContinuousActiveTimeAndAHardIdleBoundary() {
        var policy = compactPolicy()
        policy.resume(now: at(0))
        expect(policy.heartbeat(now: at(5_399)) == nil, "fatigue must not fire early")
        expect(policy.heartbeat(now: at(5_400)) == .fatigue, "ninety active minutes should cue rest")
        expect(policy.heartbeat(now: at(5_401)) == nil, "fatigue must not repeat immediately")
        policy.suspend()
        policy.resume(now: at(6_000))
        expect(policy.heartbeat(now: at(10_000)) == nil,
               "away time must break the continuous-work interval")
        expect(policy.heartbeat(now: at(11_400)) == .fatigue,
               "a new uninterrupted interval can cue after its own boundary")
    }

    static func testIdleClearsAttentionWindowsButKeepsReminderCooldown() {
        var policy = compactPolicy()
        for index in 0..<8 {
            _ = policy.observeTransition(to: "code", now: at(Double(index * 20)))
        }
        policy.suspend()
        expect(policy.recentSwitchTimes.isEmpty && policy.recentDistractionEntries.isEmpty,
               "idle should clear incomplete attention patterns")
        policy.resume(now: at(200))
        for index in 0..<8 {
            expect(policy.observeTransition(to: "paper", now: at(200 + Double(index * 20))) == nil,
                   "unlocking should not bypass the earlier nudge cooldown")
        }
    }

    static func main() {
        testRapidSwitchingNeedsARealBurst()
        testRepeatedDistractionIsRecognizedBeforeGenericThrashing()
        testChangingTitlesInsideOnePlaceDoesNotInventSwitches()
        testNudgeCooldownRequiresANewPattern()
        testFatigueUsesContinuousActiveTimeAndAHardIdleBoundary()
        testIdleClearsAttentionWindowsButKeepsReminderCooldown()
        print("companion context policy: all assertions passed")
    }
}
