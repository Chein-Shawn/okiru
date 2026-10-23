import AVFoundation
import Combine
import OkiruCore
import OSLog

@MainActor final class AudioController: ObservableObject {
    private let log = Logger(subsystem:"com.shawn.okiru",category:"wake-audio")
    private var player: AVAudioPlayer?
    private var interruptionObserver: NSObjectProtocol?
    private var endAt: Date?
    private var active = false
    var isPlaying: Bool { player?.isPlaying == true }
    var onPlaybackChange: ((Bool) -> Void)?
    init() {
        interruptionObserver = NotificationCenter.default.addObserver(forName:AVAudioSession.interruptionNotification,object:nil,queue:.main) { [weak self] notification in
            Task { @MainActor in
                guard let self, let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue:raw) else { return }
                if type == .began { self.player?.pause(); self.onPlaybackChange?(false); self.log.info("Foreground audio interrupted") }
                else if self.active && (self.endAt == nil || Date() < self.endAt!) {
                    do {
                        try AVAudioSession.sharedInstance().setActive(true)
                        guard self.player?.play() == true else { throw DisplayError(key:"error.sound") }
                        self.onPlaybackChange?(true)
                        self.log.info("Foreground audio resumed")
                    } catch { self.log.error("Foreground audio resume failed"); self.stop() }
                }
            }
        }
    }
    func play(_ sound: AlarmSound, until endAt: Date? = nil, preview: Bool = false) throws {
        stop()
        if let endAt, endAt <= Date() { return }
        guard let url = Bundle.main.url(forResource:sound.rawValue,withExtension:"wav") else { throw DisplayError(key:"error.sound") }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback,mode:.default,options:[])
        try session.setActive(true)
        do {
            let newPlayer = try AVAudioPlayer(contentsOf:url)
            newPlayer.numberOfLoops = preview ? 0 : -1
            newPlayer.volume = 1.0
            guard newPlayer.play() else { throw DisplayError(key:"error.sound") }
            player = newPlayer
            self.endAt = endAt; active = true
            onPlaybackChange?(true)
            log.info("Foreground audio started sound=\(sound.filename, privacy:.public) preview=\(preview)")
        } catch {
            log.error("Foreground audio start failed sound=\(sound.filename, privacy:.public) error=\(String(describing:type(of:error)), privacy:.public)")
            stop()
            throw error
        }
    }
    func update() {
        if let endAt, Date() >= endAt { stop(); return }
    }
    func stop() {
        active = false; player?.stop(); player = nil
        onPlaybackChange?(false)
        try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation)
    }
    deinit { if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) } }
}
