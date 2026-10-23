import Foundation

public enum PoseArmSide: String, Codable, Sendable { case left, right, unknown }
public enum PoseDecisionReason: String, Codable, Sendable {
    case waitingForUpper, elbowNotBentEnough, shoulderDropInsufficient
    case elbowNotExtended, shoulderNotReturned, stabilizing, upperConfirmed
    case lowerConfirmed, cycleTooShort, counted, targetReached
    case noPerson, lowConfidence, multiplePeople, trackingLost, invalidSample
}

/// The exact values used by the counter, not a separately calculated UI approximation.
public struct PoseDiagnosticSnapshot: Codable, Sendable {
    public var timestamp: TimeInterval
    public var side: PoseArmSide
    public var people: Int
    public var confidence: Double
    public var rawElbowAngle: Double?
    public var smoothedElbowAngle: Double?
    public var rawShoulderY: Double?
    public var smoothedShoulderY: Double?
    public var topShoulderY: Double?
    public var armScale: Double?
    public var shoulderDropInArmLengths: Double?
    public var shoulderRiseInArmLengths: Double?
    public var lowestElbowAngle: Double?
    public var phase: PoseCounter.Phase
    public var evaluationPhase: PoseCounter.Phase
    public var count: Int
    public var target: Int
    public var stableElapsed: Double
    public var cycleElapsed: Double
    public var trackingLossElapsed: Double
    public var tracked: Bool
    public var reason: PoseDecisionReason
    public var configuration: PoseConfiguration
}

public struct PoseSample: Sendable {
    public var timestamp: TimeInterval
    public var elbowAngle: Double
    /// Shoulder position in normalized top-left image coordinates (0...1).
    public var shoulderY: Double
    /// Shoulder-to-elbow distance in the same normalized image coordinates.
    public var upperArmLength: Double
    public var confidence: Double
    public var people: Int
    public var side: PoseArmSide
    public init(timestamp: TimeInterval, elbowAngle: Double, shoulderY: Double = 0.5,
                upperArmLength: Double = 0.2, confidence: Double = 1, people: Int = 1,
                side: PoseArmSide = .unknown) {
        self.timestamp = timestamp; self.elbowAngle = elbowAngle
        self.shoulderY = shoulderY; self.upperArmLength = upperArmLength
        self.confidence = confidence; self.people = people; self.side = side
    }
}

public struct PoseConfiguration: Codable, Sendable {
    public var upperAngle = 140.0
    public var lowerAngle = 90.0
    /// The first extended pose establishes tracking. Later returns are measured
    /// against each repetition's bottom, which tolerates camera perspective drift.
    public var returnAngle = 120.0
    public var minimumShoulderDropInArmLengths = 0.52
    public var minimumReturnRiseInArmLengths = 0.45
    public var minimumConfidence = 0.20
    public var stableSeconds = 0.12
    public var minimumCycleSeconds = 0.65
    public var trackingLossGraceSeconds = 0.75
    public init() {}
}

public struct PoseCounter: Sendable {
    public enum Phase: String, Codable, Sendable { case ready, upper, lower }
    public private(set) var phase: Phase = .ready
    public private(set) var count: Int
    public private(set) var lastMotionAt: TimeInterval?
    public private(set) var tracking = false
    public private(set) var diagnostics: PoseDiagnosticSnapshot?
    public let target: Int
    public var configuration: PoseConfiguration
    private var candidateSince: TimeInterval?
    private var cycleStarted: TimeInterval?
    private var lastAngle: Double?
    private var smoothedAngle: Double?
    private var smoothedShoulderY: Double?
    private var lastSampleAt: TimeInterval?
    private var lastValidAt: TimeInterval?
    private var topShoulderY: Double?
    private var topArmLength: Double?
    private var bottomShoulderY: Double?
    private var lowestElbowAngle: Double?
    public private(set) var shoulderDropInArmLengths = 0.0
    public private(set) var shoulderRiseInArmLengths = 0.0

    public init(count: Int = 0, target: Int = 10, configuration: PoseConfiguration = .init()) {
        self.target = max(1,target)
        self.count = min(self.target, max(0,count)); self.configuration = configuration
    }
    public mutating func resetTracking() {
        phase = .ready; candidateSince = nil; cycleStarted = nil
        lastAngle = nil; smoothedAngle = nil; smoothedShoulderY = nil; tracking = false
        lastSampleAt = nil; lastValidAt = nil
        topShoulderY = nil; topArmLength = nil; shoulderDropInArmLengths = 0
        bottomShoulderY = nil; lowestElbowAngle = nil; shoulderRiseInArmLengths = 0
        lastMotionAt = nil
        diagnostics = nil
    }
    /// Pauses recognition for a short, low-confidence gap without discarding a
    /// confirmed upper/lower phase. Candidate stability never advances while
    /// tracking is lost, and a prolonged gap starts a fresh repetition.
    public mutating func trackingLost(at timestamp: TimeInterval, reason: PoseDecisionReason = .trackingLost,
                                      people: Int = 0, confidence: Double = 0) {
        guard timestamp.isFinite else { resetTracking(); return }
        if let lastSampleAt, timestamp <= lastSampleAt { return }
        lastSampleAt = timestamp
        tracking = false
        candidateSince = nil
        let loss = lastValidAt.map { max(0,timestamp - $0) } ?? 0
        if loss > configuration.trackingLossGraceSeconds {
            resetTracking()
        }
        diagnostics = snapshot(at:timestamp, sample:nil, tracked:false, people:people,
                               confidence:confidence, reason:reason, loss:loss)
    }
    @discardableResult public mutating func ingest(_ sample: PoseSample) -> Int {
        guard sample.timestamp.isFinite, sample.elbowAngle.isFinite, sample.confidence.isFinite,
              sample.shoulderY.isFinite, sample.upperArmLength.isFinite,
              sample.upperArmLength > 0 else {
            let safeTime = sample.timestamp.isFinite ? sample.timestamp : (lastSampleAt ?? 0)
            resetTracking()
            diagnostics = snapshot(at:safeTime,sample:nil,tracked:false,people:sample.people,
                                   confidence:sample.confidence.isFinite ? sample.confidence : 0,
                                   reason:.invalidSample)
            return count
        }
        if let lastSampleAt, sample.timestamp <= lastSampleAt { return count }
        if sample.people == 0 || sample.confidence < configuration.minimumConfidence {
            trackingLost(at:sample.timestamp,reason:sample.people == 0 ? .noPerson : .lowConfidence,
                         people:sample.people,confidence:sample.confidence)
            return count
        }
        guard sample.people == 1 else {
            resetTracking()
            diagnostics = snapshot(at:sample.timestamp,sample:nil,tracked:false,people:sample.people,
                                   confidence:sample.confidence,reason:.multiplePeople)
            return count
        }
        if let lastValidAt,
           sample.timestamp - lastValidAt > configuration.trackingLossGraceSeconds {
            resetTracking()
        }
        lastSampleAt = sample.timestamp
        lastValidAt = sample.timestamp
        tracking = true
        if let previous = lastAngle, abs(previous - sample.elbowAngle) > 2 {
            lastMotionAt = sample.timestamp
        }
        lastAngle = sample.elbowAngle
        let angle = smoothedAngle.map { $0 * 0.35 + sample.elbowAngle * 0.65 } ?? sample.elbowAngle
        smoothedAngle = angle
        let shoulderY = smoothedShoulderY.map { $0 * 0.35 + sample.shoulderY * 0.65 } ?? sample.shoulderY
        smoothedShoulderY = shoulderY
        if phase == .ready, angle >= configuration.upperAngle {
            // Calibrate the shoulder's top position when the user first reaches
            // the extended-arm pose. Arm length makes displacement resolution-independent.
            topShoulderY = shoulderY
            topArmLength = sample.upperArmLength
        }
        let armScale = max(topArmLength ?? sample.upperArmLength, 0.001)
        let shoulderDrop = (shoulderY - (topShoulderY ?? shoulderY)) / armScale
        shoulderDropInArmLengths = shoulderDrop
        if phase == .lower {
            bottomShoulderY = max(bottomShoulderY ?? shoulderY, shoulderY)
            lowestElbowAngle = min(lowestElbowAngle ?? angle, angle)
        }
        shoulderRiseInArmLengths = ((bottomShoulderY ?? shoulderY) - shoulderY) / armScale
        guard count < target else {
            diagnostics = snapshot(at:sample.timestamp,sample:sample,tracked:true,people:sample.people,
                                   confidence:sample.confidence,reason:.targetReached)
            return count
        }
        let condition: Bool
        let failure: PoseDecisionReason
        let evaluationPhase = phase
        switch phase {
        case .ready:
            condition = angle >= configuration.upperAngle
            failure = .waitingForUpper
        case .upper:
            condition = angle <= configuration.lowerAngle && shoulderDrop >= configuration.minimumShoulderDropInArmLengths
            failure = angle > configuration.lowerAngle ? .elbowNotBentEnough : .shoulderDropInsufficient
        case .lower:
            condition = angle >= configuration.returnAngle && shoulderRiseInArmLengths >= configuration.minimumReturnRiseInArmLengths
            failure = angle < configuration.returnAngle ? .elbowNotExtended : .shoulderNotReturned
        }
        guard condition else {
            candidateSince = nil
            diagnostics = snapshot(at:sample.timestamp,sample:sample,tracked:true,people:sample.people,
                                   confidence:sample.confidence,reason:failure)
            return count
        }
        candidateSince = candidateSince ?? sample.timestamp
        guard sample.timestamp - candidateSince! >= configuration.stableSeconds else {
            diagnostics = snapshot(at:sample.timestamp,sample:sample,tracked:true,people:sample.people,
                                   confidence:sample.confidence,reason:.stabilizing)
            return count
        }
        let confirmedStable = sample.timestamp - candidateSince!
        candidateSince = nil
        var reason: PoseDecisionReason
        var completedCycle: Double?
        let evaluatedTopY = topShoulderY
        let evaluatedArmScale = topArmLength
        let evaluatedRise = shoulderRiseInArmLengths
        let evaluatedLowestAngle = lowestElbowAngle
        switch phase {
        case .ready:
            phase = .upper; cycleStarted = sample.timestamp
            reason = .upperConfirmed
        case .upper:
            phase = .lower
            bottomShoulderY = shoulderY
            lowestElbowAngle = angle
            reason = .lowerConfirmed
        case .lower:
            completedCycle = sample.timestamp - (cycleStarted ?? sample.timestamp)
            let longEnough = completedCycle! >= configuration.minimumCycleSeconds
            if longEnough { count += 1 }
            reason = longEnough ? .counted : .cycleTooShort
            phase = .upper; cycleStarted = sample.timestamp
            topShoulderY = shoulderY; topArmLength = sample.upperArmLength
            bottomShoulderY = nil; lowestElbowAngle = nil; shoulderRiseInArmLengths = 0
        }
        diagnostics = snapshot(at:sample.timestamp,sample:sample,tracked:true,people:sample.people,
                               confidence:sample.confidence,reason:reason,cycleOverride:completedCycle,
                               evaluationPhase:evaluationPhase,topOverride:evaluatedTopY,
                               armScaleOverride:evaluatedArmScale,stableOverride:confirmedStable,
                               riseOverride:evaluatedRise,lowestAngleOverride:evaluatedLowestAngle)
        return count
    }

    private func snapshot(at timestamp: TimeInterval, sample: PoseSample?, tracked: Bool,
                          people: Int, confidence: Double, reason: PoseDecisionReason,
                          loss: Double = 0, cycleOverride: Double? = nil,
                          evaluationPhase: Phase? = nil, topOverride: Double? = nil,
                          armScaleOverride: Double? = nil, stableOverride: Double? = nil,
                          riseOverride: Double? = nil, lowestAngleOverride: Double? = nil) -> PoseDiagnosticSnapshot {
        PoseDiagnosticSnapshot(timestamp:timestamp,side:sample?.side ?? .unknown,people:people,
            confidence:confidence,rawElbowAngle:sample?.elbowAngle,
            smoothedElbowAngle:tracked ? smoothedAngle : nil,
            rawShoulderY:sample?.shoulderY,smoothedShoulderY:tracked ? smoothedShoulderY : nil,
            topShoulderY:tracked ? topOverride ?? topShoulderY : nil,
            armScale:tracked ? armScaleOverride ?? topArmLength ?? sample?.upperArmLength : nil,
            shoulderDropInArmLengths:tracked ? shoulderDropInArmLengths : nil,
            shoulderRiseInArmLengths:tracked ? riseOverride ?? shoulderRiseInArmLengths : nil,
            lowestElbowAngle:tracked ? lowestAngleOverride ?? lowestElbowAngle : nil,
            phase:phase,evaluationPhase:evaluationPhase ?? phase,count:count,target:target,
            stableElapsed:stableOverride ?? candidateSince.map { max(0,timestamp - $0) } ?? 0,
            cycleElapsed:cycleOverride ?? cycleStarted.map { max(0,timestamp - $0) } ?? 0,
            trackingLossElapsed:loss,tracked:tracked,reason:reason,configuration:configuration)
    }
}
