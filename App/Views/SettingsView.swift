import SwiftUI
import AVFoundation
import UserNotifications
import AlarmKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("language") private var language = "system"
    @AppStorage("permissionSetupVersion") private var permissionSetupVersion = 0
    @State private var notificationAllowed = false
    @State private var notificationSoundAllowed = false
    @State private var cameraAllowed = false
    @State private var alarmAllowed = false
    @State private var resetting = false
    @State private var clearing = false
    @State private var testPending = false
    var body: some View {
        List {
            Section(tr("language")) {
                Picker(tr("language"),selection:$language) { ForEach(AppLanguage.choices,id:\.0) { key,name in Text(key == "system" ? tr("system") : name).tag(key) } }
                    .onChange(of:language) { _,value in UserDefaults(suiteName:SharedRestrictionStore.groupID)?.set(value,forKey:"language") }
            }
            Section(tr("permissions")) {
                permission(tr("permission.alarm"),allowed:model.scheduler.modern ? alarmAllowed : notificationAllowed)
                permission(tr("permission.notification"),allowed:notificationAllowed)
                permission(tr("permission.notificationSounds"),allowed:notificationSoundAllowed)
                permission(tr("permission.camera"),allowed:cameraAllowed)
                permission(tr("permission.restriction"),allowed:model.restrictions.isAuthorized)
                Button(tr("permission.requestAlarms")) { Task { do { try await model.scheduler.authorize(needsReminders:true); await permissions() } catch { model.errorMessage = error.localizedDescription } } }
                Button(tr("permission.requestRestriction")) { Task { do { try await model.restrictions.authorize(); await permissions() } catch { model.errorMessage = error.localizedDescription } } }
                Button(tr("openSettings")) { open(URL(string:UIApplication.openSettingsURLString)!) }
                Button(tr("permission.review")) { permissionSetupVersion = 0 }
            }
            Section(tr("support")) {
                NavigationLink(tr("feedback")) { FeedbackView() }
                Button(tr("review")) {
                    let id = ServiceConfiguration.current.appStoreID
                    guard !id.isEmpty, id.allSatisfy(\.isNumber),let url = URL(string:"https://apps.apple.com/app/id\(id)?action=write-review") else { model.notice = tr("review.unavailable"); return }
                    open(url)
                }
                if let url = publicURL(ServiceConfiguration.current.privacyURL) { Link(tr("privacy"),destination:url) }
                if let url = publicURL(ServiceConfiguration.current.supportURL) { Link(tr("support"),destination:url) }
            }
            Section(tr("testing")) {
                Button(tr("practice")) { model.challenge = .practice }
                Button(tr("test.alarm")) {
                    testPending = true
                    Task {
                        do {
                            _ = try await UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound])
                            try await model.scheduler.testSound(.sunrise)
                            model.notice = tr("test.scheduled")
                        } catch {
                            testPending = false
                            model.errorMessage = error.localizedDescription
                        }
                    }
                }.disabled(testPending)
            }
            Section(tr("data")) {
                Button(tr("history.clear"),role:.destructive) { clearing = true }
                Button(tr("reset"),role:.destructive) { resetting = true }
                LabeledContent(tr("version"),value:versionText)
            }
        }.navigationTitle(tr("settings"))
        .task { await permissions() }
        .onReceive(NotificationCenter.default.publisher(for:.okiruTestNotificationDelivered)) { _ in
            testPending = false
            model.notice = tr("test.delivered")
        }
        .confirmationDialog(tr("reset.confirm"),isPresented:$resetting) { Button(tr("reset"),role:.destructive) { Task { await model.reset() } } }
        .confirmationDialog(tr("history.clearConfirm"),isPresented:$clearing) { Button(tr("history.clear"),role:.destructive) { model.clearHistory() } }
    }
    private func permission(_ name: String,allowed: Bool) -> some View { HStack { Text(name); Spacer(); Image(systemName:allowed ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(allowed ? .green : .secondary).accessibilityLabel(tr(allowed ? "authorized" : "notAuthorized")) } }
    private func permissions() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationAllowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        notificationSoundAllowed = settings.soundSetting == .enabled
        cameraAllowed = AVCaptureDevice.authorizationStatus(for:.video) == .authorized
        if #available(iOS 26.0, *) { alarmAllowed = AlarmManager.shared.authorizationState == .authorized }
    }
    private func open(_ url: URL) { UIApplication.shared.open(url) }
    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
    private func publicURL(_ value: String) -> URL? {
        guard let url = URL(string:value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

struct TextDocumentView: View {
    var title: String
    var key: String
    var body: some View { ScrollView { Text(tr(key)).frame(maxWidth:.infinity,alignment:.leading).padding(24) }.navigationTitle(title).navigationBarTitleDisplayMode(.inline) }
}

struct FeedbackView: View {
    @AppStorage("feedback.id") private var id = ""
    @AppStorage("feedback.lastPayload") private var lastPayload = ""
    @AppStorage("feedback.category") private var category = "bug"
    @AppStorage("feedback.summary") private var summary = ""
    @AppStorage("feedback.details") private var details = ""
    @AppStorage("feedback.email") private var email = ""
    @State private var sending = false
    @State private var message: String?
    var body: some View {
        Form {
            Section {
                Picker(tr("feedback.category"),selection:$category) { ForEach(["bug","idea","other"],id:\.self) { Text(tr("feedback."+$0)).tag($0) } }
                TextField(tr("feedback.summary"),text:$summary).onChange(of:summary) { _,value in if value.unicodeScalars.count > 160 { summary = String(String.UnicodeScalarView(value.unicodeScalars.prefix(160))) } }
                TextField(tr("feedback.details"),text:$details,axis:.vertical).lineLimit(6...14).onChange(of:details) { _,value in if value.unicodeScalars.count > 4000 { details = String(String.UnicodeScalarView(value.unicodeScalars.prefix(4000))) } }
                TextField(tr("feedback.email"),text:$email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section {
                Text(tr("feedback.privacy")).font(.caption).foregroundStyle(.secondary)
                if ServiceConfiguration.current.feedbackEndpoint.isEmpty { Label(tr("feedback.unconfigured"),systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                Button {
                    let fingerprint = [category,summary,details,email].joined(separator:"\u{001F}")
                    if id.isEmpty || lastPayload != fingerprint { id = UUID().uuidString.lowercased(); lastPayload = fingerprint }
                    sending = true
                    Task {
                        do {
                            try await FeedbackService.shared.submit(id:id,category:category,summary:summary,details:details,email:email)
                            summary = ""; details = ""; email = ""; id = ""; lastPayload = ""; message = tr("feedback.sent")
                        } catch { message = error.localizedDescription }
                        sending = false
                    }
                } label: { HStack { Text(tr("feedback.send")); if sending { Spacer(); ProgressView() } } }
                    .disabled(sending || summary.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || details.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || ServiceConfiguration.current.feedbackEndpoint.isEmpty)
            }
        }.navigationTitle(tr("feedback"))
        .alert(tr("feedback"),isPresented:Binding(get:{ message != nil },set:{ if !$0 { message = nil } })) { Button(tr("ok")) { message = nil } } message: { Text(message ?? "") }
    }
}
