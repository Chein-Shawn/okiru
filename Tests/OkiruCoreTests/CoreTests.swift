import XCTest
@testable import OkiruCore

final class CoreTests: XCTestCase {
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    func testEmergencyHoldIsLongerDuringActiveRestriction() {
        XCTAssertEqual(EmergencyHoldPolicy.duration(hasActiveRestriction:false),3)
        XCTAssertEqual(EmergencyHoldPolicy.duration(hasActiveRestriction:true),30)
    }
    func event(_ offset: TimeInterval = 0) -> AlarmOccurrence {
        AlarmOccurrence(alarm: AlarmDefinition(createdAt: epoch.addingTimeInterval(-86400)), scheduledAt: epoch.addingTimeInterval(offset), calendar: calendar)
    }
    func testThreeHundredSecondBoundaryAndIdempotence() {
        var exact = event(); exact.confirm(repetitions: 10, at: epoch.addingTimeInterval(300))
        XCTAssertEqual(exact.outcome(at: epoch.addingTimeInterval(900)), .onTime)
        exact.confirm(repetitions: 10, at: epoch.addingTimeInterval(999))
        XCTAssertEqual(exact.completedAt, epoch.addingTimeInterval(300))
        var late = event(); late.confirm(repetitions: 10, at: epoch.addingTimeInterval(300.01))
        XCTAssertEqual(late.outcome(at: epoch.addingTimeInterval(900)), .late)
    }
    func testCannotCompleteBeforeScheduledOrWithPartialReps() {
        var e = event(); e.confirm(repetitions: 10, at: epoch.addingTimeInterval(-1))
        XCTAssertNil(e.completedAt)
        e.confirm(repetitions: 9, at: epoch.addingTimeInterval(50))
        XCTAssertNil(e.completedAt)
    }
    func testDismissalDoesNotChangeDeadlineOrResolution() {
        let e = event()
        XCTAssertFalse(e.resolved)
        XCTAssertEqual(e.deadline, epoch.addingTimeInterval(300))
        XCTAssertEqual(e.outcome(at: epoch.addingTimeInterval(301)), .missed)
    }
    func testCapacityReservesPrimaryAndOrdersChronologically() {
        let first = event(), second = event(1)
        let plan = ReminderPlanner.plan(occurrences: [second, first], now: epoch, primaryCount: 7)
        XCTAssertEqual(plan.reminders.count, 41)
        XCTAssertTrue(plan.capacityLimited)
        XCTAssertEqual(plan.reminders.first?.occurrenceID, first.id)
        XCTAssertEqual(plan.reminders[1].occurrenceID, second.id)
        XCTAssertEqual(Set(plan.reminders.map(\.id)).count, 41)
    }
    func testNoRemindersAfterThreeHoursOrCompletion() {
        XCTAssertTrue(ReminderPlanner.plan(occurrences: [event()], now: epoch.addingTimeInterval(10800), primaryCount: 0).reminders.isEmpty)
        var done = event(); done.confirm(repetitions: 10, at: epoch.addingTimeInterval(30))
        XCTAssertTrue(ReminderPlanner.plan(occurrences: [done], now: epoch, primaryCount: 0).reminders.isEmpty)
        XCTAssertEqual(ReminderPlanner.plan(occurrences: [event()], now: epoch, primaryCount: 60).reminders.count, 0)
    }
    func testLegacyDisabledSettingCannotSuppressUnfinishedWakeReminders() {
        var alarm = AlarmDefinition(createdAt:epoch.addingTimeInterval(-86400),remindersEnabled:false)
        alarm.enabled = true
        let unfinished = AlarmOccurrence(alarm:alarm,scheduledAt:epoch,calendar:calendar)
        let plan = ReminderPlanner.plan(occurrences:[unfinished],now:epoch,primaryCount:0)
        XCTAssertFalse(plan.reminders.isEmpty)
        XCTAssertEqual(plan.reminders.first?.at,epoch.addingTimeInterval(3))
    }
    func testDailyFirstAndExcludedFutureDenominator() {
        var first = event(); first.confirm(repetitions: 10, at: epoch.addingTimeInterval(100))
        let later = event(1000)
        let stats = WakeStatistics.calculate([later,first,event(86400)], now: epoch.addingTimeInterval(5000))
        XCTAssertEqual(stats.eligibleDays, 1)
        XCTAssertEqual(stats.successRate, 1)
    }
    func testCrossMidnightRestrictionRequiresTimeAndCompletion() {
        var e = event()
        e.alarm.restriction.enabled = true
        e.alarm.restriction.startMinute = 1320
        e.alarm.restriction.releaseDelayMinutes = 30
        var w = RestrictionWindow(occurrence: e, calendar: calendar)
        XCTAssertEqual(w.start, calendar.date(byAdding:.day,value:-1,to:calendar.startOfDay(for:e.scheduledAt))!.addingTimeInterval(22*3600))
        XCTAssertTrue(w.isActive(at:e.scheduledAt.addingTimeInterval(3600)))
        e.confirm(repetitions:10,at:e.scheduledAt.addingTimeInterval(60))
        w = RestrictionWindow(occurrence:e,calendar:calendar)
        XCTAssertEqual(w.releaseAt,e.scheduledAt.addingTimeInterval(31*60))
        XCTAssertTrue(w.isActive(at:w.releaseAt!.addingTimeInterval(-1)))
        XCTAssertFalse(w.isActive(at:w.releaseAt!))
        w.completedAt = nil; w.emergencyAt = w.start
        XCTAssertFalse(w.isActive(at: w.start.addingTimeInterval(1)))
    }
    func testWeeklyCalendarAndOneShotCosts() {
        let alarm = AlarmDefinition(createdAt: epoch.addingTimeInterval(-86400), weekdays: [2,3,4,5,6])
        let dates = ScheduleCalculator.dates(for: alarm, from: calendar.startOfDay(for: epoch), through: epoch.addingTimeInterval(7 * 86400), calendar: calendar)
        XCTAssertTrue(dates.allSatisfy { [2,3,4,5,6].contains(calendar.component(.weekday, from: $0)) })
        XCTAssertEqual(alarm.legacyNotificationCost, 5)
        var daily = alarm; daily.weekdays = Set(1...7)
        XCTAssertEqual(daily.legacyNotificationCost, 1)
    }
    func testDSTProducesOneOccurrencePerDay() {
        var c = calendar; c.timeZone = TimeZone(identifier: "America/New_York")!
        let start = c.date(from: DateComponents(year: 2026, month: 3, day: 7))!
        let end = c.date(from: DateComponents(year: 2026, month: 3, day: 10))!
        let alarm = AlarmDefinition(createdAt: start, hour: 2, minute: 30, weekdays: Set(1...7))
        let dates = ScheduleCalculator.dates(for: alarm, from: start, through: end, calendar: c)
        XCTAssertEqual(dates.count, 3)
        XCTAssertEqual(Set(dates.map { c.startOfDay(for:$0) }).count, 3)
    }
    func testPoseRequiresWholeCycleAndRejectsMultiplePeople() {
        var counter = PoseCounter()
        var t: Double = 0
        func hold(_ angle: Double, _ shoulderY: Double, frames: Int = 10, people: Int = 1) {
            for _ in 0..<frames { t += 0.05; counter.ingest(.init(timestamp: t, elbowAngle: angle, shoulderY: shoulderY, people: people)) }
        }
        hold(170,0.50); hold(80,0.70)
        XCTAssertEqual(counter.count, 0)
        hold(170,0.50)
        XCTAssertEqual(counter.count, 1)
        hold(170,0.50,frames: 50)
        XCTAssertEqual(counter.count, 1)
        hold(80,0.70)
        hold(80,0.70,people:2)
        hold(170,0.50)
        XCTAssertEqual(counter.count, 1)
    }
    func testElbowBendWithoutShoulderDropDoesNotCount() {
        var counter = PoseCounter()
        for i in 0..<100 {
            counter.ingest(.init(timestamp: Double(i)*0.05, elbowAngle: i % 20 < 10 ? 170 : 55, shoulderY:0.50))
        }
        XCTAssertEqual(counter.count, 0)
    }
    func testShoulderDropWithoutElbowBendDoesNotCount() {
        var counter = PoseCounter()
        for i in 0..<100 {
            counter.ingest(.init(timestamp:Double(i)*0.05,elbowAngle:170,shoulderY:i%20<10 ? 0.50 : 0.70))
        }
        XCTAssertEqual(counter.count,0)
    }
    func testStandingStraightBodyNeverCountsPushups() {
        var counter = PoseCounter()
        for i in 0..<120 { counter.ingest(.init(timestamp:Double(i)*0.05,elbowAngle:i%20<10 ? 170:55,shoulderY:0.50)) }
        XCTAssertEqual(counter.count,0)
    }
    func testLowConfidenceAndBackgroundResetLoseHalfRepOnly() {
        var counter = PoseCounter(count:4)
        var t = 0.0
        for (angle,y) in [(170.0,0.50),(80,0.70)] { for _ in 0..<15 { t += 0.05; counter.ingest(.init(timestamp:t,elbowAngle:angle,shoulderY:y)) } }
        counter.resetTracking()
        for _ in 0..<20 { t += 0.05; counter.ingest(.init(timestamp:t,elbowAngle:170,confidence:0.1)) }
        XCTAssertEqual(counter.count,4)
        for _ in 0..<20 { t += 0.05; counter.ingest(.init(timestamp:t,elbowAngle:170,shoulderY:0.50)) }
        XCTAssertEqual(counter.count,4)
    }
    func testTypicalVisionConfidenceCanCompleteARepetition() {
        var counter = PoseCounter()
        var t = 0.0
        for (angle,y) in [(170.0,0.50),(80,0.70),(170,0.50)] {
            for _ in 0..<12 {
                t += 0.05
                counter.ingest(.init(timestamp:t,elbowAngle:angle,shoulderY:y,confidence:0.32))
            }
        }
        XCTAssertEqual(counter.count,1)
        XCTAssertTrue(counter.tracking)
    }
    func testBriefTrackingLossAtBottomPreservesRepetition() {
        for gap in [0.2, 0.5, 0.75] {
            var counter = PoseCounter()
            var t = 0.0
            for (angle,y) in [(170.0,0.50),(80,0.70)] {
                for _ in 0..<8 { t += 0.05; counter.ingest(.init(timestamp:t,elbowAngle:angle,shoulderY:y)) }
            }
            t += gap - 0.05
            counter.trackingLost(at:t)
            for _ in 0..<8 { t += 0.05; counter.ingest(.init(timestamp:t,elbowAngle:170,shoulderY:0.50)) }
            XCTAssertEqual(counter.count,1,"Expected a \(gap)s dropout to preserve the confirmed lower phase")
        }
    }
    func testProlongedTrackingLossDiscardsPartialRepetition() {
        var counter = PoseCounter()
        var t = 0.0
        for (angle,y) in [(170.0,0.50),(80,0.70)] {
            for _ in 0..<8 { t += 0.05; counter.ingest(.init(timestamp:t,elbowAngle:angle,shoulderY:y)) }
        }
        t += 0.75
        counter.trackingLost(at:t)
        for _ in 0..<8 { t += 0.05; counter.ingest(.init(timestamp:t,elbowAngle:170,shoulderY:0.50)) }
        XCTAssertEqual(counter.count,0)
        XCTAssertEqual(counter.phase,.upper)
    }
    func testConfiguredNinetyDegreeAndNinetyPercentBottomCompletesFullCycle() {
        var counter = PoseCounter()
        var t = 0.0
        for (angle,y) in [(170.0,0.50),(80,0.70),(170,0.50)] {
            for _ in 0..<12 { t += 0.05; counter.ingest(.init(timestamp:t,elbowAngle:angle,shoulderY:y)) }
        }
        XCTAssertEqual(counter.count,1)
    }
    func testBottomRelativeReturnToleratesPerspectiveShift() {
        var counter = PoseCounter()
        var t = 0.0
        func hold(_ angle: Double, _ shoulderY: Double, frames: Int = 8) {
            for _ in 0..<frames {
                t += 0.05
                counter.ingest(.init(timestamp:t,elbowAngle:angle,shoulderY:shoulderY,upperArmLength:0.20))
            }
        }
        hold(170,0.40)
        for _ in 0..<10 {
            hold(75,0.63)
            // The camera view never returns to the original 0.40 baseline, but
            // the shoulder rises by 0.10 (half an upper-arm length) each cycle.
            hold(125,0.52)
        }
        XCTAssertEqual(counter.count,10)
    }
    func testBottomRelativeReturnStillRejectsArmOnlyAndShoulderOnlyMotion() {
        var armOnly = PoseCounter(), shoulderOnly = PoseCounter()
        var t = 0.0
        for _ in 0..<8 {
            t += 0.05
            armOnly.ingest(.init(timestamp:t,elbowAngle:170,shoulderY:0.50))
            shoulderOnly.ingest(.init(timestamp:t,elbowAngle:170,shoulderY:0.50))
        }
        for _ in 0..<10 {
            for _ in 0..<8 {
                t += 0.05
                armOnly.ingest(.init(timestamp:t,elbowAngle:75,shoulderY:0.50))
                shoulderOnly.ingest(.init(timestamp:t,elbowAngle:170,shoulderY:0.70))
            }
            for _ in 0..<8 {
                t += 0.05
                armOnly.ingest(.init(timestamp:t,elbowAngle:130,shoulderY:0.50))
                shoulderOnly.ingest(.init(timestamp:t,elbowAngle:170,shoulderY:0.50))
            }
        }
        XCTAssertEqual(armOnly.count,0)
        XCTAssertEqual(shoulderOnly.count,0)
    }
    func testEditingScheduleCannotInventPastOccurrences() {
        var alarm = AlarmDefinition(createdAt:epoch.addingTimeInterval(-7*86400),weekdays:Set(1...7))
        alarm.effectiveFrom = epoch
        let dates = ScheduleCalculator.dates(for:alarm,from:epoch.addingTimeInterval(-7*86400),through:epoch.addingTimeInterval(86400),calendar:calendar)
        XCTAssertTrue(dates.allSatisfy { $0 >= epoch })
    }
    func testSameTimeUsesCreationOrderForDailyBaseline() {
        var a = event(); var b = event()
        a.alarm.createdAt = epoch.addingTimeInterval(-100)
        b.alarm.createdAt = epoch.addingTimeInterval(-200)
        XCTAssertEqual(WakeStatistics.dailyFirst([a,b]).first?.id,b.id)
    }
    func testSnapshotsRoundTripWithoutChangingTimeZoneOrSchedule() throws {
        let original = event()
        let restored = try JSONDecoder().decode(AlarmOccurrence.self,from:JSONEncoder().encode(original))
        XCTAssertEqual(restored.id,original.id)
        XCTAssertEqual(restored.timeZoneID,original.timeZoneID)
        XCTAssertEqual(restored.dayKey,original.dayKey)
    }
    func testOverlappingExceptionsRequireEveryPolicy() {
        XCTAssertEqual(RestrictionRules.commonExceptions([Set(["spotify","maps"]),Set(["spotify","books"])]),Set(["spotify"]))
        XCTAssertEqual(RestrictionRules.commonExceptions([Set(["spotify"]),Set<String>()]),Set<String>())
    }
    func testFinishingOneWindowDoesNotReleaseAnother() {
        var a = event(), b = event(60)
        a.alarm.restriction.enabled = true; b.alarm.restriction.enabled = true
        let completed = epoch.addingTimeInterval(60)
        a.confirm(repetitions:10,at:completed)
        let released = completed.addingTimeInterval(15*60)
        XCTAssertFalse(RestrictionWindow(occurrence:a,calendar:calendar).isActive(at:released))
        XCTAssertTrue(RestrictionWindow(occurrence:b,calendar:calendar).isActive(at:released))
    }
    func testTargetsAndDeadlinesAreSnapshotted() {
        var alarm = AlarmDefinition(targetReps:50)
        var occurrence = AlarmOccurrence(alarm:alarm,scheduledAt:epoch,calendar:calendar)
        alarm.targetReps = 5
        XCTAssertEqual(occurrence.deadline,epoch.addingTimeInterval(600))
        occurrence.confirm(repetitions:49,at:epoch.addingTimeInterval(600))
        XCTAssertNil(occurrence.completedAt)
        occurrence.confirm(repetitions:50,at:epoch.addingTimeInterval(600))
        XCTAssertEqual(occurrence.outcome(at:epoch.addingTimeInterval(601)),.onTime)
        var small = AlarmOccurrence(alarm:alarm,scheduledAt:epoch,calendar:calendar)
        XCTAssertEqual(small.deadline,epoch.addingTimeInterval(300))
        small.confirm(repetitions:5,at:epoch.addingTimeInterval(301))
        XCTAssertEqual(small.outcome(at:epoch.addingTimeInterval(302)),.late)
    }
    func testLegacyPoliciesAndTargetsDecodeWithoutUnlockingEarly() throws {
        let old = #"{"enabled":true,"startMinute":1320,"endMinute":420}"#.data(using:.utf8)!
        let policy = try JSONDecoder().decode(RestrictionPolicy.self,from:old)
        XCTAssertEqual(policy.legacyEndMinute,420)
        var alarm = AlarmDefinition(targetReps:10,restriction:policy)
        let oldAlarm = try JSONEncoder().encode(alarm)
        let object = try JSONSerialization.jsonObject(with:oldAlarm) as! [String:Any]
        var withoutTarget = object; withoutTarget.removeValue(forKey:"targetReps")
        let restored = try JSONDecoder().decode(AlarmDefinition.self,from:JSONSerialization.data(withJSONObject:withoutTarget))
        XCTAssertEqual(restored.targetReps,10)
        alarm = restored
        var occurrence = AlarmOccurrence(alarm:alarm,scheduledAt:epoch,calendar:calendar)
        occurrence.confirm(repetitions:10,at:epoch.addingTimeInterval(30))
        let window = RestrictionWindow(occurrence:occurrence,calendar:calendar)
        let oldEnd = calendar.date(bySettingHour:7,minute:0,second:0,of:epoch)!
        XCTAssertGreaterThanOrEqual(window.releaseAt!,oldEnd)
    }
    func testRestrictionDelayAndStartDayRemainPerOccurrence() {
        var alarm = AlarmDefinition(createdAt:epoch.addingTimeInterval(-86400),hour:7,minute:0)
        alarm.restriction.enabled = true
        alarm.restriction.startMinute = 22 * 60
        alarm.restriction.releaseDelayMinutes = 120
        var occurrence = AlarmOccurrence(alarm:alarm,scheduledAt:epoch,calendar:calendar)
        let start = RestrictionWindow(occurrence:occurrence,calendar:calendar).start
        XCTAssertLessThan(start,occurrence.scheduledAt)
        alarm.restriction.releaseDelayMinutes = 15
        occurrence.confirm(repetitions:10,at:epoch.addingTimeInterval(20))
        let window = RestrictionWindow(occurrence:occurrence,calendar:calendar)
        XCTAssertEqual(window.releaseAt,epoch.addingTimeInterval(20 + 120*60))
        XCTAssertTrue(window.isActive(at:epoch.addingTimeInterval(20 + 120*60 - 1)))
        XCTAssertFalse(window.isActive(at:epoch.addingTimeInterval(20 + 120*60)))
    }
    func testRestrictionOnlyEmergencyKeepsCompletedOutcome() throws {
        var occurrence = event()
        occurrence.alarm.restriction.enabled = true
        occurrence.confirm(repetitions:10,at:epoch.addingTimeInterval(100))
        XCTAssertEqual(occurrence.outcome(at:epoch.addingTimeInterval(200)),.onTime)
        occurrence.restrictionEmergencyAt = epoch.addingTimeInterval(200)
        XCTAssertFalse(RestrictionWindow(occurrence:occurrence,calendar:calendar).isActive(at:epoch.addingTimeInterval(201)))
        XCTAssertEqual(occurrence.outcome(at:epoch.addingTimeInterval(201)),.onTime)
        let old = event()
        let restored = try JSONDecoder().decode(AlarmOccurrence.self,from:JSONEncoder().encode(old))
        XCTAssertNil(restored.restrictionEmergencyAt)
    }
    func testDeactivatingAlarmKeepsFiredMissionButCancelsFutureSchedule() {
        var alarm = AlarmDefinition(createdAt:epoch.addingTimeInterval(-86400))
        alarm.restriction.enabled = true
        var active = AlarmOccurrence(alarm:alarm,scheduledAt:epoch,calendar:calendar)
        active.startedAt = epoch
        let future = AlarmOccurrence(alarm:alarm,scheduledAt:epoch.addingTimeInterval(86400),calendar:calendar)
        var completed = AlarmOccurrence(alarm:alarm,scheduledAt:epoch.addingTimeInterval(-60),calendar:calendar)
        completed.confirm(repetitions:10,at:epoch.addingTimeInterval(-30))
        var events = [active,future,completed]
        let affected = AlarmDeactivation.apply(alarmID:alarm.id,to:&events,at:epoch.addingTimeInterval(30))
        XCTAssertEqual(Set(affected),Set([future.id,completed.id]))
        XCTAssertFalse(events.contains(where: { $0.id == future.id }))
        XCTAssertFalse(events.first(where: { $0.id == active.id })!.resolved)
        XCTAssertTrue(RestrictionWindow(occurrence:events.first(where: { $0.id == active.id })!,calendar:calendar).isActive(at:epoch.addingTimeInterval(31)))
        let savedCompletion = events.first(where: { $0.id == completed.id })!
        XCTAssertEqual(savedCompletion.outcome(at:epoch.addingTimeInterval(31)),.onTime)
        XCTAssertFalse(RestrictionWindow(occurrence:savedCompletion,calendar:calendar).isActive(at:epoch.addingTimeInterval(31)))
        XCTAssertFalse(ReminderPlanner.plan(occurrences:events,now:epoch.addingTimeInterval(31),primaryCount:0).reminders.isEmpty)
    }
    func testReenablingAlarmRestoresCancelledFutureOvernightRestriction() {
        let scheduled = calendar.date(from:DateComponents(year:2026,month:10,day:24,hour:6,minute:30))!
        let cancelledAt = calendar.date(from:DateComponents(year:2026,month:10,day:23,hour:18,minute:53))!
        let reopenedAt = calendar.date(from:DateComponents(year:2026,month:10,day:23,hour:21))!
        var alarm = AlarmDefinition(createdAt:cancelledAt.addingTimeInterval(-86400),hour:6,minute:30,weekdays:[7])
        alarm.restriction.enabled = true
        alarm.restriction.startMinute = 18 * 60
        var occurrences = [AlarmOccurrence(alarm:alarm,scheduledAt:scheduled,calendar:calendar)]
        XCTAssertTrue(RestrictionWindow(occurrence:occurrences[0],calendar:calendar).isActive(at:cancelledAt))
        AlarmDeactivation.apply(alarmID:alarm.id,to:&occurrences,at:cancelledAt)
        XCTAssertEqual(occurrences.first?.cancelledAt,cancelledAt)
        alarm.enabled = false
        XCTAssertTrue(AlarmReactivation.restoreFuture(definitions:[alarm],occurrences:&occurrences,at:reopenedAt,calendar:calendar).isEmpty)
        alarm.enabled = true
        alarm.effectiveFrom = reopenedAt
        XCTAssertEqual(AlarmReactivation.restoreFuture(definitions:[alarm],occurrences:&occurrences,at:reopenedAt,calendar:calendar),Set(["\(alarm.id.uuidString).\(Int(scheduled.timeIntervalSince1970))"]))
        XCTAssertTrue(occurrences.isEmpty)
        let restored = ScheduleCalculator.dates(for:alarm,from:reopenedAt,through:scheduled,calendar:calendar)
        XCTAssertEqual(restored,[scheduled])
        XCTAssertTrue(RestrictionWindow(occurrence:AlarmOccurrence(alarm:alarm,scheduledAt:scheduled,calendar:calendar),calendar:calendar).isActive(at:reopenedAt))
    }
    func testReactivationNeverRewritesPastOrMismatchedSchedule() {
        let now = epoch
        var alarm = AlarmDefinition(createdAt:now.addingTimeInterval(-86400),weekdays:[],oneShotDate:now.addingTimeInterval(2*86400))
        alarm.effectiveFrom = now
        var past = AlarmOccurrence(alarm:alarm,scheduledAt:now.addingTimeInterval(-3600),calendar:calendar)
        past.cancelledAt = now.addingTimeInterval(-7200)
        var future = AlarmOccurrence(alarm:alarm,scheduledAt:now.addingTimeInterval(86400),calendar:calendar)
        future.cancelledAt = now.addingTimeInterval(-7200)
        let original = [past,future]
        var occurrences = original
        XCTAssertTrue(AlarmReactivation.restoreFuture(definitions:[alarm],occurrences:&occurrences,at:now,calendar:calendar).isEmpty)
        XCTAssertEqual(occurrences,original)
    }
    func testWakeTaskPolicyUsesOldestUnfinishedRegardlessOfLaunchSource() {
        let older = event(-300), newer = event(-30), future = event(60)
        XCTAssertEqual(WakeTaskPolicy.firstUnfinished([newer,future,older],at:epoch)?.id,older.id)
        XCTAssertTrue(WakeTaskPolicy.hasFiredUnfinished([older,newer],alarmID:older.alarm.id,at:epoch))
        var completed = older
        completed.confirm(repetitions:10,at:epoch)
        XCTAssertEqual(WakeTaskPolicy.firstUnfinished([newer,completed,future],at:epoch)?.id,newer.id)
        var emergency = newer
        emergency.emergencyAt = epoch
        XCTAssertNil(WakeTaskPolicy.firstUnfinished([emergency,completed,future],at:epoch))
    }
    func testCancelledAlarmDoesNotReplaceLaterDailyBaseline() {
        var first = event(), second = event(600)
        first.cancelledAt = epoch.addingTimeInterval(60)
        second.confirm(repetitions:10,at:epoch.addingTimeInterval(700))
        XCTAssertEqual(WakeStatistics.dailyFirst([first,second]).first?.id,second.id)
    }
    func testPoseDiagnosticsMatchCountingInputsAndAreEphemeral() throws {
        var counter = PoseCounter(target:5)
        var log = PracticeDiagnosticLog(startedAt:epoch,uptime:0,appVersion:"test")
        var t = 0.0
        for (angle,y) in [(170.0,0.50),(80,0.70),(170,0.50)] {
            for _ in 0..<12 {
                t += 0.05
                counter.ingest(.init(timestamp:t,elbowAngle:angle,shoulderY:y,side:.left))
                XCTAssertTrue(log.append(counter.diagnostics!))
            }
        }
        XCTAssertEqual(counter.count,1)
        XCTAssertEqual(counter.diagnostics?.side,.left)
        XCTAssertEqual(counter.diagnostics?.smoothedElbowAngle ?? -1,170,accuracy:0.1)
        XCTAssertEqual(log.records.last?.timestamp ?? -1,t,accuracy:0.001)
        let text = String(data:try log.jsonData(),encoding:.utf8)!
        XCTAssertTrue(text.contains("pose-shoulder-arm-v2"))
        XCTAssertFalse(text.contains("image"))
        counter.trackingLost(at:t+0.2,reason:.noPerson)
        XCTAssertNil(counter.diagnostics?.smoothedElbowAngle)
        XCTAssertEqual(counter.diagnostics?.trackingLossElapsed ?? -1,0.2,accuracy:0.001)
    }
    func testPoseTargetTenAndDiagnosticPhases() {
        var counter = PoseCounter(target:10)
        var t = 0.0
        for repetition in 1...10 {
            for (angle,y) in [(170.0,0.50),(80,0.70),(170,0.50)] {
                for _ in 0..<12 {
                    t += 0.05
                    counter.ingest(.init(timestamp:t,elbowAngle:angle,shoulderY:y))
                }
            }
            XCTAssertEqual(counter.count,repetition)
            XCTAssertEqual(counter.diagnostics?.reason,repetition == 10 ? .targetReached : .elbowNotBentEnough)
        }
        counter.ingest(.init(timestamp:t+0.05,elbowAngle:170,shoulderY:0.50))
        XCTAssertEqual(counter.diagnostics?.reason,.targetReached)
        XCTAssertEqual(counter.count,10)
    }
    func testPracticeLogIsBoundedAndOnlyContainsRelativeMeasurements() {
        var counter = PoseCounter()
        counter.ingest(.init(timestamp:10,elbowAngle:170))
        var log = PracticeDiagnosticLog(startedAt:epoch,uptime:10,appVersion:"test")
        XCTAssertTrue(log.append(counter.diagnostics!))
        XCTAssertEqual(log.records.first?.timestamp,0)
        var late = counter.diagnostics!
        late.timestamp = 10 + PracticeDiagnosticLog.maximumSeconds + 0.01
        XCTAssertFalse(log.append(late))
        XCTAssertTrue(log.capped)
        XCTAssertEqual(log.finishedReason,"limitReached")
        XCTAssertEqual(log.records.count,1)
    }
    func testRecentDaysKeepsEntireBaselineDay() {
        let start = calendar.startOfDay(for:epoch)
        let now = start.addingTimeInterval(6*86400+20*3600)
        let early = AlarmOccurrence(alarm:AlarmDefinition(createdAt:start.addingTimeInterval(-86400)),scheduledAt:start.addingTimeInterval(7*3600),calendar:calendar)
        let later = AlarmOccurrence(alarm:AlarmDefinition(createdAt:start.addingTimeInterval(-86400)),scheduledAt:start.addingTimeInterval(22*3600),calendar:calendar)
        XCTAssertEqual(WakeStatistics.dailyFirst(WakeStatistics.inRecentDays([early,later],days:7,now:now,calendar:calendar)).first?.id,early.id)
        XCTAssertTrue(WakeStatistics.inRecentDays([early],days:6,now:now,calendar:calendar).isEmpty)
    }
}
