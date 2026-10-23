import SwiftUI
import FamilyControls
import OkiruCore

struct AlarmsView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: AlarmDefinition?
    @State private var deleting: AlarmDefinition?
    var body: some View {
        List {
            Section {
                if let warning = model.report.warning { Label(warning,systemImage:"exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
            }
            if model.alarms.isEmpty { ContentUnavailableView(tr("alarms.empty"),systemImage:"alarm",description:Text(tr("alarm.first"))) }
            ForEach(model.alarms) { alarm in
                HStack {
                    Button { editing = alarm } label: {
                        VStack(alignment:.leading,spacing:7) {
                            Text(time(for:alarm)).font(.system(size:42,weight:.medium,design:.rounded)).foregroundStyle(alarm.enabled ? .primary : .secondary)
                            Text(alarm.name.isEmpty ? tf("task.reps",alarm.targetReps) : alarm.name).font(.subheadline)
                            Text(scheduleLabel(alarm)).font(.caption).foregroundStyle(.secondary)
                            if alarm.enabled, let next = ScheduleCalculator.next(for:alarm,after:Date()) {
                                Text(tr("nextAlarm")+": "+displayDate(next)).font(.caption2).foregroundStyle(.secondary)
                            }
                            if alarm.enabled {
                                let eventIDs = Set(model.occurrences.filter { $0.alarm.id == alarm.id }.map(\.id))
                                let reminders = model.report.actualReminders.filter { eventIDs.contains($0.occurrenceID) }
                                Text(tr("reminders.scheduled")+": "+reminders.count.formatted()).font(.caption2).foregroundStyle(.secondary)
                                if let last = reminders.last?.at {
                                    Text(tr("reminders.until")+": "+displayDate(last)).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            if alarm.restriction.enabled { Label(tr("restriction.title"),systemImage:"lock.shield").font(.caption).foregroundStyle(.orange) }
                        }
                    }.buttonStyle(.plain)
                    Spacer()
                    Toggle(tr("enabled"),isOn:Binding(get:{ alarm.enabled },set:{ value in var changed = alarm; changed.enabled = value; Task { _ = await model.saveAlarm(changed) } })).labelsHidden().disabled(model.busy)
                }.padding(.vertical,6)
                .swipeActions { Button(tr("delete"),role:.destructive) { deleting = alarm } }
            }
            Section(tr("reminders.title")) {
                LabeledContent(tr("reminders.scheduled"),value:model.report.actualReminders.count.formatted())
                if let date = model.report.actualReminders.last?.at { LabeledContent(tr("reminders.until"),value:displayDate(date)) }
                Text(tr(model.report.limited ? "reminders.limited" : "reminders.description")).font(.caption).foregroundStyle(.secondary)
            }
            Section { Button(tr("practice")) { model.challenge = .practice } }
        }
        .navigationTitle(tr("alarms"))
        .toolbar { Button { editing = AlarmDefinition() } label: { Image(systemName:"plus") }.accessibilityLabel(tr("alarm.create")) }
        .sheet(item:$editing) { AlarmEditor(alarm:$0).environmentObject(model) }
        .confirmationDialog(tr("alarm.deleteConfirm"),isPresented:Binding(get:{ deleting != nil },set:{ if !$0 { deleting = nil } })) {
            Button(tr("delete"),role:.destructive) { if let alarm = deleting { Task { await model.deleteAlarm(alarm) } }; deleting = nil }
        }
    }
    private func time(for alarm: AlarmDefinition) -> String {
        let date = alarm.isRepeating ? Calendar.current.date(bySettingHour:alarm.hour,minute:alarm.minute,second:0,of:Date())! : alarm.oneShotDate
        return displayDate(date,date:.omitted)
    }
}

func scheduleLabel(_ alarm: AlarmDefinition) -> String {
    guard alarm.isRepeating else { return displayDate(alarm.oneShotDate,time:.omitted) }
    if alarm.weekdays.count == 7 { return tr("daily") }
    var calendar = Calendar.current; calendar.locale = Locale(identifier:AppLanguage.effective)
    return [2,3,4,5,6,7,1].filter { alarm.weekdays.contains($0) }.map { calendar.shortWeekdaySymbols[$0-1] }.joined(separator:" · ")
}

struct AlarmEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var alarm: AlarmDefinition
    @State private var selection = FamilyActivitySelection()
    @State private var blockedSelection = FamilyActivitySelection()
    @State private var choosingApps = false
    @State private var choosingBlocked = false
    @StateObject private var audio = AudioController()
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(tr("alarm.name"),text:$alarm.name)
                    Picker(tr("alarm.type"),selection:Binding(get:{ alarm.isRepeating },set:{ alarm.weekdays = $0 ? [2,3,4,5,6] : [] })) {
                        Text(tr("once")).tag(false); Text(tr("weekly")).tag(true)
                    }.pickerStyle(.segmented)
                    if alarm.isRepeating {
                        DatePicker(tr("time"),selection:timeBinding,displayedComponents:.hourAndMinute)
                        weekdayButtons
                    } else { DatePicker(tr("date"),selection:$alarm.oneShotDate,in:Date()...,displayedComponents:[.date,.hourAndMinute]) }
                }
                Section(tr("sound")) {
                    Picker(tr("sound"),selection:$alarm.sound) { ForEach(AlarmSound.allCases,id:\.self) { Text(tr("sound."+$0.rawValue)).tag($0) } }
                    Button(tr("preview")) { do { try audio.play(alarm.sound,preview:true) } catch { model.errorMessage = error.localizedDescription } }
                }
                Section(tr("task.title")) {
                    Picker(tr("task.target"),selection:$alarm.targetReps) {
                        ForEach(Array(stride(from:5,through:100,by:5)),id:\.self) { n in Text(tf("task.reps",n)).tag(n) }
                    }
                    Text(tr("camera.guide")).font(.caption).foregroundStyle(.secondary)
                }
                Section(tr("reminders.title")) {
                    Label(tr("enabled"),systemImage:"bell.badge.fill")
                    Text(tr("reminders.description")).font(.caption).foregroundStyle(.secondary)
                }
                Section(tr("restriction.title")) {
                    Toggle(tr("enabled"),isOn:$alarm.restriction.enabled)
                    if alarm.restriction.enabled {
                        DatePicker(tr("restriction.start"),selection:minuteBinding(\.startMinute),displayedComponents:.hourAndMinute)
                        Picker(tr("restriction.releaseDelay"),selection:$alarm.restriction.releaseDelayMinutes) {
                            ForEach(Array(stride(from:15,through:120,by:15)),id:\.self) { n in Text(tf("restriction.delayMinutes",n)).tag(n) }
                        }
                        Button(tf("restriction.allowed",selection.applicationTokens.count)) {
                            Task { do { try await model.restrictions.authorize(); choosingApps = true } catch { model.errorMessage = error.localizedDescription } }
                        }
                        Button(tf("restriction.blocked",blockedSelection.applicationTokens.count,blockedSelection.webDomainTokens.count)) {
                            Task { do { try await model.restrictions.authorize(); choosingBlocked = true } catch { model.errorMessage = error.localizedDescription } }
                        }
                        Text(tr("restriction.scopeNote")).font(.caption).foregroundStyle(.secondary)
                        if let next = ScheduleCalculator.next(for:alarm,after:Date()) {
                            let window = RestrictionWindow(occurrence:AlarmOccurrence(alarm:alarm,scheduledAt:next))
                            Text(displayDate(window.start)+" → "+tr("restriction.afterCompletion")).font(.caption)
                        }
                        Text(tr("restriction.unlockRule.dynamic")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(tr("alarm.edit"))
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(tr("cancel")) { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button(tr("save")) { save() }.disabled(model.busy) }
            }
            .familyActivityPicker(isPresented:$choosingApps,selection:$selection)
            .familyActivityPicker(isPresented:$choosingBlocked,selection:$blockedSelection)
            .onAppear {
                if let data = alarm.restriction.selectionData { selection = (try? JSONDecoder().decode(FamilyActivitySelection.self,from:data)) ?? .init() }
                if let data = alarm.restriction.blockedSelectionData { blockedSelection = (try? JSONDecoder().decode(FamilyActivitySelection.self,from:data)) ?? .init() }
            }
            .onDisappear { audio.stop() }
            .alert(tr("attention"),isPresented:Binding(get:{ model.errorMessage != nil },set:{ if !$0 { model.errorMessage = nil } })) { Button(tr("ok"),role:.cancel) { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
        }
    }
    private var timeBinding: Binding<Date> {
        Binding(get:{ Calendar.current.date(bySettingHour:alarm.hour,minute:alarm.minute,second:0,of:Date())! },set:{ alarm.hour = Calendar.current.component(.hour,from:$0); alarm.minute = Calendar.current.component(.minute,from:$0) })
    }
    private func minuteBinding(_ key: WritableKeyPath<RestrictionPolicy,Int>) -> Binding<Date> {
        Binding(get:{ let n = alarm.restriction[keyPath:key]; return Calendar.current.date(bySettingHour:n/60,minute:n%60,second:0,of:Date())! },set:{ alarm.restriction[keyPath:key] = Calendar.current.component(.hour,from:$0)*60+Calendar.current.component(.minute,from:$0) })
    }
    private var weekdayButtons: some View {
        var cal = Calendar.current; cal.locale = Locale(identifier:AppLanguage.effective)
        return HStack {
            ForEach([2,3,4,5,6,7,1],id:\.self) { day in
                Button {
                    if alarm.weekdays.contains(day) { if alarm.weekdays.count > 1 { alarm.weekdays.remove(day) } }
                    else { alarm.weekdays.insert(day) }
                } label: { Text(cal.veryShortWeekdaySymbols[day-1]).font(.subheadline.bold()).frame(maxWidth:.infinity).padding(.vertical,10).background(alarm.weekdays.contains(day) ? Color.orange.opacity(0.2) : .clear,in:Capsule()) }
                    .buttonStyle(.plain).accessibilityLabel(cal.weekdaySymbols[day-1]).accessibilityAddTraits(alarm.weekdays.contains(day) ? .isSelected : [])
            }
        }
    }
    private func save() {
        do {
            guard selection.categoryTokens.isEmpty && selection.webDomainTokens.isEmpty && selection.applicationTokens.count <= 50 else { throw DisplayError(key:"restriction.appsOnly") }
            guard blockedSelection.categoryTokens.isEmpty && blockedSelection.applicationTokens.count <= 50 && blockedSelection.webDomainTokens.count <= 50 else { throw DisplayError(key:"restriction.blockedOnly") }
            alarm.restriction.selectionData = try JSONEncoder().encode(selection)
            alarm.restriction.blockedSelectionData = try JSONEncoder().encode(blockedSelection)
            alarm.restriction.legacyEndMinute = nil
            Task { if await model.saveAlarm(alarm) { dismiss() } }
        } catch { model.errorMessage = error.localizedDescription }
    }
}
