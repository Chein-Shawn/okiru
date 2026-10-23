import SwiftUI
import UserNotifications
import OSLog

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var challengeVisible = false
    static var challengeAudioPlaying = false
    private let log = Logger(subsystem:"com.shawn.okiru",category:"wake-delivery")
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey:Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Self.registerNotificationCategory()
        return true
    }
    static func registerNotificationCategory() {
        let center = UNUserNotificationCenter.current()
        let action = UNNotificationAction(identifier:"OPEN_TASK",title:tr("challenge.start"),options:.foreground)
        center.setNotificationCategories([.init(identifier:"OKIRU_WAKE",actions:[action],intentIdentifiers:[],options:.customDismissAction)])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        log.info("Foreground notification id=\(notification.request.identifier, privacy:.private) soundRequested=\(notification.request.content.sound != nil) taskVisible=\(Self.challengeVisible) audioPlaying=\(Self.challengeAudioPlaying)")
        if notification.request.identifier == "okiru.test" {
            NotificationCenter.default.post(name:.okiruTestNotificationDelivered,object:nil)
            completionHandler([.banner,.list,.sound])
            return
        }
        completionHandler(Self.challengeVisible && Self.challengeAudioPlaying ? [] : [.banner,.sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        log.info("Notification response id=\(response.notification.request.identifier, privacy:.private) action=\(response.actionIdentifier, privacy:.public)")
        // Dismissal deliberately never completes a challenge or cancels its future requests.
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }
        let info = response.notification.request.content.userInfo
        if let id = info["occurrenceID"] as? String { UserDefaults.standard.set(id,forKey:"requestedOccurrence") }
        else if let id = info["alarmID"] as? String { UserDefaults.standard.set(id,forKey:"requestedAlarm") }
        NotificationCenter.default.post(name:.init("OkiruOpenTask"),object:nil)
    }
}

extension Notification.Name {
    static let okiruTestNotificationDelivered = Notification.Name("OkiruTestNotificationDelivered")
}

@main struct OkiruApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @AppStorage("language") private var language = "system"
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environment(\.locale,Locale(identifier:AppLanguage.effective))
                .environment(\.layoutDirection,AppLanguage.effective == "ar" ? .rightToLeft : .leftToRight)
                .id(language)
                .tint(.orange)
                .task { AppDelegate.registerNotificationCategory(); model.routeDueTask(); await model.refresh() }
                .onChange(of:phase) { _, value in if value == .active { model.routeDueTask(); Task { await model.refresh() } } }
                .onReceive(NotificationCenter.default.publisher(for:.init("OkiruOpenTask"))) { _ in Task { await model.refresh(); model.routeRequestedAlarm() } }
                .onOpenURL { url in
                    if url.host == "challenge", let id = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first(where: { $0.name == "alarm" })?.value {
                        UserDefaults.standard.set(id,forKey:"requestedAlarm")
                        Task { await model.refresh() }
                    }
                }
        }
    }
}
