import Foundation

/// Small, deterministic policy that turns computer-use rhythm into sparse
/// companion cues. It deliberately owns no UI, timers, or animation names:
/// AppDelegate supplies observed transitions and decides how each cue speaks.
enum CompanionContextCue: String, Equatable {
    case frequentDistraction
    case rapidSwitching
    case fatigue
}

struct CompanionContextPolicy {
    struct Configuration {
        var rapidWindow: TimeInterval = 3 * 60
        var rapidSwitchCount = 8
        var distractionWindow: TimeInterval = 5 * 60
        var distractionEntryCount = 3
        var nudgeCooldown: TimeInterval = 20 * 60
        var fatigueAfter: TimeInterval = 90 * 60
        var fatigueCooldown: TimeInterval = 90 * 60
    }

    let configuration: Configuration
    private(set) var continuousActivityStartedAt: Date?
    private(set) var recentSwitchTimes: [Date] = []
    private(set) var recentDistractionEntries: [Date] = []
    private(set) var currentKind: String?
    private(set) var currentContextID: String?
    private var lastNudgeAt: Date?
    private var lastFatigueAt: Date?

    init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    mutating func resume(now: Date = Date()) {
        if continuousActivityStartedAt == nil { continuousActivityStartedAt = now }
    }

    /// Away time is a hard boundary. Cooldowns intentionally survive it so a
    /// lock/unlock cycle cannot make the companion repeat the same reminder.
    mutating func suspend() {
        continuousActivityStartedAt = nil
        recentSwitchTimes.removeAll(keepingCapacity: true)
        recentDistractionEntries.removeAll(keepingCapacity: true)
        currentKind = nil
        currentContextID = nil
    }

    /// Records one meaningful app/page transition and, at most, returns one
    /// gentle cue. Re-entering distraction repeatedly is more specific than
    /// raw switching, so it wins when both thresholds are reached together.
    mutating func observeTransition(to rawKind: String,
                                    contextID rawContextID: String = "",
                                    now: Date = Date()) -> CompanionContextCue? {
        resume(now: now)
        let kind = rawKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let contextID = rawContextID.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !contextID.isEmpty, contextID == currentContextID {
            currentKind = kind
            return nil
        }
        trim(now: now)
        recentSwitchTimes.append(now)
        if kind == "distraction", currentKind != "distraction" {
            recentDistractionEntries.append(now)
        }
        currentKind = kind
        currentContextID = contextID.isEmpty ? nil : contextID

        let frequentDistraction = recentDistractionEntries.count
            >= configuration.distractionEntryCount
        let rapidSwitching = recentSwitchTimes.count >= configuration.rapidSwitchCount
        guard frequentDistraction || rapidSwitching,
              lastNudgeAt.map({ now.timeIntervalSince($0) >= configuration.nudgeCooldown }) ?? true
        else { return nil }

        lastNudgeAt = now
        // Retain only the present transition. A fresh pattern, not one extra
        // title change, must accumulate after the cooldown.
        recentSwitchTimes = [now]
        recentDistractionEntries = kind == "distraction" ? [now] : []
        return frequentDistraction ? .frequentDistraction : .rapidSwitching
    }

    mutating func heartbeat(now: Date = Date()) -> CompanionContextCue? {
        guard let startedAt = continuousActivityStartedAt,
              now.timeIntervalSince(startedAt) >= configuration.fatigueAfter,
              lastFatigueAt.map({ now.timeIntervalSince($0) >= configuration.fatigueCooldown }) ?? true
        else { return nil }
        lastFatigueAt = now
        return .fatigue
    }

    private mutating func trim(now: Date) {
        recentSwitchTimes = recentSwitchTimes.filter {
            now.timeIntervalSince($0) < configuration.rapidWindow
        }
        recentDistractionEntries = recentDistractionEntries.filter {
            now.timeIntervalSince($0) < configuration.distractionWindow
        }
    }
}
