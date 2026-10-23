import SwiftUI
import Charts
import OkiruCore

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dynamicTypeSize) private var textSize
    @Binding var selectedTab: Int
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                let headerLayout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment:.leading,spacing:12)) : AnyLayout(HStackLayout())
                headerLayout {
                    VStack(alignment:.leading,spacing:6) {
                        Text(tr("home.tagline")).font(.subheadline).foregroundStyle(.secondary)
                        Text("Okiru").font(.system(size:38,weight:.bold,design:.rounded))
                    }
                    if !textSize.isAccessibilitySize { Spacer() }
                    Image(systemName:"sunrise.fill").font(.system(size:40)).foregroundStyle(.orange)
                }.padding(.top,12)
                weekStrip
                Surface {
                    VStack(alignment:.leading,spacing:12) {
                        Label(tr("nextAlarm"),systemImage:"alarm").font(.subheadline).foregroundStyle(.secondary)
                        if let next = model.nextAlarm {
                            Text(next.scheduledAt,format:.dateTime.hour().minute()).font(.system(size:60,weight:.bold,design:.rounded)).minimumScaleFactor(0.5)
                            Text(next.scheduledAt,format:.dateTime.weekday(.wide).month().day()).foregroundStyle(.secondary)
                            Text(tf("task.reps",next.alarm.targetReps)).font(.subheadline)
                        } else {
                            Text(tr("home.empty")).font(.title2.bold())
                            Button(tr("alarm.create")) { selectedTab = 1 }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                if let event = model.pending.first {
                    Surface {
                        VStack(alignment:.leading,spacing:12) {
                            Label(tr("task.pending"),systemImage:"figure.strengthtraining.traditional").font(.headline)
                            Text(event.scheduledAt,format:.dateTime.month().day().hour().minute()).foregroundStyle(.secondary)
                            Button(tr("challenge.start")) { model.start(event) }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                if !model.activeWindows.isEmpty {
                    Surface {
                        VStack(alignment:.leading,spacing:12) {
                            Label(tr("restriction.active"),systemImage:"lock.shield.fill").font(.headline)
                            Text(tr("restriction.unlockRule.dynamic")).font(.subheadline).foregroundStyle(.secondary)
                            EmergencyButton()
                        }
                    }
                }
                let stats = WakeStatistics.calculate(WakeStatistics.inRecentDays(model.occurrences,days:30,now:Date()),now:Date())
                let streak = WakeStatistics.calculate(model.occurrences,now:Date()).currentStreak
                let statsLayout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment:.leading,spacing:12)) : AnyLayout(HStackLayout(alignment:.top,spacing:12))
                statsLayout {
                    Surface { VStack(alignment:.leading,spacing:8) { Text(tr("successRate")).font(.caption).foregroundStyle(.secondary); Text(stats.successRate.map { Int(($0*100).rounded()).formatted()+"%" } ?? "—").font(.largeTitle.bold()) } }
                    Surface { VStack(alignment:.leading,spacing:8) { Text(tr("streak")).font(.caption).foregroundStyle(.secondary); Text(tf("days.format",streak)).font(.title.bold()) } }
                }
                NavigationLink { HistoryView() } label: {
                    Surface { HStack { Label(tr("history"),systemImage:"chart.bar.xaxis"); Spacer(); Image(systemName:"chevron.right") } }
                }.buttonStyle(.plain)
            }.padding(20)
        }.background(Color(uiColor:.systemGroupedBackground)).toolbar(.hidden,for:.navigationBar)
    }
    private var weekStrip: some View {
        let first = WakeStatistics.dailyFirst(model.occurrences)
        let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment:.leading,spacing:8)) : AnyLayout(HStackLayout(spacing:4))
        return layout {
            ForEach(-5...1,id:\.self) { offset in
                let date = Calendar.current.date(byAdding:.day,value:offset,to:Date())!
                let event = first.first { $0.dayKey == WakeStatistics.dayKey(date) }
                let cell = textSize.isAccessibilitySize ? AnyLayout(HStackLayout(spacing:12)) : AnyLayout(VStackLayout(spacing:10))
                cell {
                    if textSize.isAccessibilitySize {
                        Text(displayDate(date,date:.abbreviated,time:.omitted)).font(.headline)
                        Spacer(minLength:8)
                    } else {
                        Text(date,format:.dateTime.weekday(.narrow)).font(.caption).foregroundStyle(.secondary)
                        Text(date,format:.dateTime.day()).font(.headline)
                    }
                    Image(systemName:event.map { outcomeIcon($0.outcome(at:Date())) } ?? "minus.circle").foregroundStyle(event.map { outcomeColor($0.outcome(at:Date())) } ?? .secondary)
                }.frame(maxWidth:.infinity).padding(.vertical,14).padding(.horizontal,textSize.isAccessibilitySize ? 12 : 0)
                    .background(offset == 0 ? Color.orange.opacity(0.14) : .clear,in:RoundedRectangle(cornerRadius:16))
                    .accessibilityElement(children:.combine)
                    .accessibilityLabel(displayDate(date,date:.complete,time:.omitted)+", "+(event.map { tr("outcome."+$0.outcome(at:Date()).rawValue) } ?? tr("noAlarm")))
            }
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var days = 30
    var filtered: [AlarmOccurrence] {
        WakeStatistics.inRecentDays(model.occurrences,days:days,now:Date()).filter { $0.scheduledAt <= Date() }
    }
    var body: some View {
        let stats = WakeStatistics.calculate(filtered,now:Date())
        List {
            Picker(tr("period"),selection:$days) { Text(tf("days.format",7)).tag(7); Text(tf("days.format",30)).tag(30); Text(tr("all")).tag(0) }.pickerStyle(.segmented)
            Section(tr("statistics")) {
                LabeledContent(tr("successRate"),value:stats.successRate.map { Int(($0*100).rounded()).formatted()+"%" } ?? "—")
                LabeledContent(tr("averageDelay"),value:stats.averageDelaySeconds.map { Duration.seconds($0).formatted(.time(pattern:.minuteSecond)) } ?? "—")
                LabeledContent(tr("completionTime"),value:stats.averageCompletionMinute.map { String(format:"%02d:%02d",Int($0)%1440/60,Int($0)%60) } ?? "—")
                LabeledContent(tr("streak"),value:tf("days.format",stats.currentStreak))
                Text(tr("statistics.note")).font(.caption).foregroundStyle(.secondary)
            }
            if !filtered.isEmpty {
                Section(tr("delay")) {
                    Chart(WakeStatistics.dailyFirst(filtered).filter { $0.completedAt != nil }) { event in
                        if let finished = event.completedAt {
                            BarMark(x:.value(tr("date"),event.scheduledAt,unit:.day),y:.value(tr("delay"),max(0,finished.timeIntervalSince(event.scheduledAt)/60)))
                                .foregroundStyle(outcomeColor(event.outcome(at:Date())))
                        }
                    }.frame(height:170)
                }
            }
            Section(tr("history.log")) {
                if filtered.isEmpty { ContentUnavailableView(tr("history.empty"),systemImage:"clock.arrow.circlepath") }
                ForEach(filtered.sorted { $0.scheduledAt > $1.scheduledAt }) { event in
                    VStack(alignment:.leading,spacing:8) {
                        HStack {
                            Text(displayDate(event.scheduledAt,timeZoneID:event.timeZoneID)).font(.headline)
                            Spacer()
                            Image(systemName:outcomeIcon(event.outcome(at:Date()))).foregroundStyle(outcomeColor(event.outcome(at:Date())))
                        }
                        Text(tr("outcome."+event.outcome(at:Date()).rawValue)).foregroundStyle(outcomeColor(event.outcome(at:Date())))
                        Text(tf("reps.target.format",event.reps,event.alarm.targetReps)).font(.caption).foregroundStyle(.secondary)
                        Text(event.timeZoneID).font(.caption2).foregroundStyle(.secondary)
                        if let started = event.startedAt { Text(tr("challenge.start")+": "+displayDate(started,date:.omitted,time:.standard,timeZoneID:event.timeZoneID)).font(.caption) }
                        if let finished = event.completedAt { Text(tr("completionTime")+": "+displayDate(finished,date:.omitted,time:.standard,timeZoneID:event.timeZoneID)).font(.caption) }
                        if let reason = event.emergencyReason { Text(reason).font(.caption) }
                        if !event.resolved { Button(tr("challenge.start")) { model.start(event) } }
                    }.padding(.vertical,6)
                }
            }
        }.navigationTitle(tr("history"))
    }
}
