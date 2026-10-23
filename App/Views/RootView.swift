import SwiftUI
import OkiruCore
import AVFoundation
import UserNotifications
import AlarmKit

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var lastWakeRefill = Date.distantPast
    @AppStorage("permissionSetupVersion") private var permissionSetupVersion = 0
    var body: some View {
        TabView(selection:$tab) {
            NavigationStack { HomeView(selectedTab:$tab) }.tabItem { Label(tr("home"),systemImage:"sun.max") }.tag(0)
            NavigationStack { AlarmsView() }.tabItem { Label(tr("alarms"),systemImage:"alarm") }.tag(1)
            NavigationStack { SettingsView() }.tabItem { Label(tr("settings"),systemImage:"gearshape") }.tag(2)
        }
        .fullScreenCover(item:$model.challenge) { ChallengeView(route:$0).environmentObject(model) }
        .sheet(isPresented:Binding(get:{
            model.challenge?.occurrenceID == nil
                && WakeTaskPolicy.firstUnfinished(model.occurrences,at:Date()) == nil
                && (permissionSetupVersion < 2 || model.requiresPermissionSetup)
        },set:{ _ in })) {
            OnboardingView {
                permissionSetupVersion = 2
                model.requiresPermissionSetup = false
            }.environmentObject(model).interactiveDismissDisabled()
        }
        .alert(tr("attention"),isPresented:Binding(get:{ model.errorMessage != nil },set:{ if !$0 { model.errorMessage = nil } })) {
            Button(tr("ok"),role:.cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .safeAreaInset(edge:.top) {
            if let message = model.notice {
                HStack { Text(message).font(.footnote); Spacer(); Button { model.notice = nil } label: { Image(systemName:"xmark.circle.fill") }.accessibilityLabel(tr("close")) }
                    .padding().background(.orange.opacity(0.12))
            }
        }
        .overlay(alignment:.topTrailing) { if model.busy { ProgressView().padding().background(.regularMaterial,in:Capsule()).padding() } }
        // UI refresh only. Delivery and deadlines never depend on this timer.
        .onReceive(Timer.publish(every:5,on:.main,in:.common).autoconnect()) { date in
            if scenePhase == .active {
                model.foregroundNow = date
                // The Stop intent normally refills immediately. This periodic
                // path protects an already-visible challenge if the system
                // delivers the intent without another scene lifecycle event.
                if model.challenge?.occurrenceID != nil,
                   date.timeIntervalSince(lastWakeRefill) >= 30 {
                    lastWakeRefill = date
                    Task { await model.refresh() }
                }
            }
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    @State private var notificationAllowed = false
    @State private var notificationSoundAllowed = false
    @State private var alarmAllowed = false
    @State private var cameraAllowed = false
    @State private var restrictionAllowed = false
    @State private var requesting = false
    @State private var message: String?
    var finish: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                Image(systemName:"sunrise.fill").font(.system(size:64)).foregroundStyle(.orange)
                Text("Okiru").font(.system(size:46,weight:.bold,design:.rounded))
                Text(tr("onboarding.title.dynamic")).font(.title2.bold())
                Label(tr("onboarding.task.dynamic"),systemImage:"figure.strengthtraining.traditional")
                Label(tr("onboarding.reminders"),systemImage:"bell.badge")
                Label(tr("onboarding.privacy"),systemImage:"camera")
                Text(tr("permission.setup.intro")).font(.headline)
                VStack(spacing:12) {
                    permissionRow(tr("permission.alarm"),allowed:alarmAllowed)
                    permissionRow(tr("permission.notification"),allowed:notificationAllowed)
                    permissionRow(tr("permission.notificationSounds"),allowed:notificationSoundAllowed)
                    permissionRow(tr("permission.camera"),allowed:cameraAllowed)
                    permissionRow(tr("permission.restriction"),allowed:restrictionAllowed,optional:true)
                }.padding().background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:20))
                Button(tr("permission.requestAlarms")) { Task { await requestAlarms() } }
                    .buttonStyle(.borderedProminent).disabled(requesting || (alarmAllowed && notificationAllowed && notificationSoundAllowed))
                Button(tr("permission.requestCamera")) { Task { await requestCamera() } }
                    .buttonStyle(.bordered).disabled(requesting || cameraAllowed)
                Button(tr("permission.requestRestriction")) { Task { await requestRestriction() } }
                    .buttonStyle(.bordered).disabled(requesting || restrictionAllowed)
                Button(tr("openSettings")) {
                    if let url = URL(string:UIApplication.openSettingsURLString) { openURL(url) }
                }.buttonStyle(.plain)
                Text(tr("onboarding.emergency")).font(.footnote).foregroundStyle(.secondary)
                Button(tr("getStarted"),action:finish).buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth:.infinity)
            }.padding(28)
        }.presentationDragIndicator(.visible)
        .task { await refreshPermissions() }
        .alert(tr("attention"),isPresented:Binding(get:{ message != nil },set:{ if !$0 { message = nil } })) {
            Button(tr("ok"),role:.cancel) { message = nil }
        } message: { Text(message ?? "") }
    }
    private func permissionRow(_ title: String,allowed: Bool,optional: Bool = false) -> some View {
        HStack {
            Image(systemName:allowed ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(allowed ? .green : .secondary)
            Text(title)
            if optional { Text(tr("optional")).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Text(tr(allowed ? "authorized" : "notAuthorized")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func refreshPermissions() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationAllowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        notificationSoundAllowed = settings.soundSetting == .enabled
        if #available(iOS 26.0, *) { alarmAllowed = AlarmManager.shared.authorizationState == .authorized }
        else { alarmAllowed = notificationAllowed }
        cameraAllowed = AVCaptureDevice.authorizationStatus(for:.video) == .authorized
        restrictionAllowed = model.restrictions.isAuthorized
    }
    private func requestAlarms() async {
        requesting = true; defer { requesting = false }
        do { try await model.scheduler.authorize(needsReminders:true); await refreshPermissions() }
        catch { message = error.localizedDescription }
    }
    private func requestCamera() async {
        requesting = true; defer { requesting = false }
        if AVCaptureDevice.authorizationStatus(for:.video) == .notDetermined { _ = await AVCaptureDevice.requestAccess(for:.video) }
        await refreshPermissions()
        if !cameraAllowed { message = tr("error.cameraPermission") }
    }
    private func requestRestriction() async {
        requesting = true; defer { requesting = false }
        do { try await model.restrictions.authorize(); await refreshPermissions() }
        catch { message = error.localizedDescription }
    }
}

struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:24)) }
}

func outcomeColor(_ outcome: WakeOutcome) -> Color {
    switch outcome { case .onTime: return .green; case .late: return .orange; case .missed,.emergency:return .red; default:return .secondary }
}

func outcomeIcon(_ outcome: WakeOutcome) -> String {
    switch outcome { case .onTime:return "checkmark.circle.fill"; case .late:return "clock.badge.checkmark"; case .missed:return "xmark.circle"; case .emergency:return "exclamationmark.shield"; case .cancelled:return "minus.circle"; case .challenging:return "figure.strengthtraining.traditional"; case .upcoming:return "circle.dashed" }
}
