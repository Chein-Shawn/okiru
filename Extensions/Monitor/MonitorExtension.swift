import DeviceActivity

final class MonitorExtension: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) { SharedRestrictionStore.handleMonitorCallback() }
    override func intervalDidEnd(for activity: DeviceActivityName) { SharedRestrictionStore.handleMonitorCallback() }
}
