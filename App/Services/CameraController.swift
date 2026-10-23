import AVFoundation
import Vision
import SwiftUI
import OkiruCore

// Capture state is confined to `queue`; published UI state and runGeneration are
// changed on the main thread. AVCaptureSession owns its internal synchronization.
final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    @Published var points: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
    @Published var count = 0
    @Published var tracking = false
    @Published var errorKey: String?
    @Published var lastMotion: TimeInterval?
    @Published var detectedJointCount = 0
    @Published var detectedPeople = 0
    @Published var phase: PoseCounter.Phase = .ready
    @Published var diagnostic: PoseDiagnosticSnapshot?
    @Published var practiceLimitReached = false
    @Published var skeletonOpacity = 0.0
    private let queue = DispatchQueue(label:"okiru.camera",qos:.userInitiated)
    private var counter = PoseCounter()
    private var practiceLog: PracticeDiagnosticLog?
    private var configured = false
    private var lastProcessed = 0.0
    private let poseRequest = VNDetectHumanBodyPoseRequest()
    private var observations: [NSObjectProtocol] = []
    private var lastStrongPoints: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
    private var lastStrongPointsAt: TimeInterval?
    @MainActor private var runGeneration = 0

    @MainActor func start(initialCount: Int = 0, target: Int = 10, practice: Bool = false) {
        runGeneration += 1
        let generation = runGeneration
        count = initialCount
        Task {
            let permission = AVCaptureDevice.authorizationStatus(for:.video)
            let authorized: Bool
            if permission == .authorized { authorized = true }
            else if permission == .notDetermined { authorized = await AVCaptureDevice.requestAccess(for:.video) }
            else { authorized = false }
            guard generation == runGeneration else { return }
            guard authorized else { self.errorKey = "error.cameraPermission"; return }
            queue.async {
                self.counter = PoseCounter(count:initialCount,target:target)
                if practice && self.practiceLog == nil {
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
                    self.practiceLog = PracticeDiagnosticLog(startedAt:Date(),uptime:ProcessInfo.processInfo.systemUptime,appVersion:version)
                }
                do {
                    if !self.configured { try self.configure() }
                    self.session.startRunning()
                    DispatchQueue.main.async { self.errorKey = nil }
                } catch { DispatchQueue.main.async { self.errorKey = "error.cameraUnavailable" } }
            }
        }
    }
    @MainActor func stop() {
        runGeneration += 1
        tracking = false; points = [:]; lastMotion = nil; detectedJointCount = 0; detectedPeople = 0
        phase = .ready; diagnostic = nil; skeletonOpacity = 0
        queue.async {
            self.session.stopRunning(); self.counter.resetTracking()
            self.lastStrongPoints = [:]; self.lastStrongPointsAt = nil
        }
    }
    @MainActor func finishPractice(reason: String, completion: @escaping @MainActor @Sendable (PracticeDiagnosticLog?) -> Void) {
        queue.async {
            if self.practiceLog == nil {
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
                self.practiceLog = PracticeDiagnosticLog(startedAt:Date(),uptime:ProcessInfo.processInfo.systemUptime,appVersion:version)
            }
            self.practiceLog?.finish(reason)
            let finished = self.practiceLog
            self.practiceLog = nil
            DispatchQueue.main.async { completion(finished) }
        }
    }
    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,for:.video,position:.front) else { throw DisplayError(key:"error.cameraUnavailable") }
        session.beginConfiguration()
        defer {
            if !configured {
                session.inputs.forEach { session.removeInput($0) }
                session.outputs.forEach { session.removeOutput($0) }
            }
            session.commitConfiguration()
        }
        session.sessionPreset = .hd1280x720
        let input = try AVCaptureDeviceInput(device:device)
        guard session.canAddInput(input) else { throw DisplayError(key:"error.cameraUnavailable") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self,queue:queue)
        guard session.canAddOutput(output) else { throw DisplayError(key:"error.cameraUnavailable") }
        session.addOutput(output)
        if let connection = output.connection(with:.video) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
        }
        observations.append(NotificationCenter.default.addObserver(forName:.AVCaptureSessionWasInterrupted,object:session,queue:.main) { [weak self] _ in
            self?.errorKey = "camera.interrupted"
            self?.queue.async { self?.counter.resetTracking() }
        })
        observations.append(NotificationCenter.default.addObserver(forName:.AVCaptureSessionInterruptionEnded,object:session,queue:.main) { [weak self] _ in self?.errorKey = nil })
        configured = true
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastProcessed >= 1.0/15, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastProcessed = now
        do {
            try VNImageRequestHandler(cvPixelBuffer:buffer,orientation:.up).perform([poseRequest])
            let people = poseRequest.results ?? []
            guard !people.isEmpty else {
                counter.trackingLost(at:now,reason:.noPerson)
                publish(points:[:], detectedPeople:0, now:now); return
            }

            // Vision may report a weak second observation for a reflection or background
            // image. Select the strongest body for display, and only reject counting when
            // more than one observation has enough joints to be a plausible participant.
            let candidates = try people.map { body -> (body: VNHumanBodyPoseObservation, joints: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint], quality: Float) in
                let joints = try body.recognizedPoints(.all)
                let names: [VNHumanBodyPoseObservation.JointName] = [
                    .leftShoulder,.leftElbow,.leftWrist,
                    .rightShoulder,.rightElbow,.rightWrist]
                let quality = names.map { joints[$0]?.confidence ?? 0 }.reduce(0,+) / Float(names.count)
                return (body,joints,quality)
            }
            guard let primary = candidates.max(by:{ $0.quality < $1.quality }) else {
                counter.trackingLost(at:now,reason:.noPerson); publish(points:[:], detectedPeople:0, now:now); return
            }
            let joints = primary.joints
            var visible: [VNHumanBodyPoseObservation.JointName:CGPoint] = [:]
            for (name,p) in joints where p.confidence >= 0.15 {
                // Vision uses a lower-left origin. The preview is mirrored for the front
                // camera, so convert to top-left coordinates and mirror horizontally.
                visible[name] = CGPoint(x:1-p.x,y:1-p.y)
            }

            let sides: [[VNHumanBodyPoseObservation.JointName]] = [
                [.leftShoulder,.leftElbow,.leftWrist],
                [.rightShoulder,.rightElbow,.rightWrist]]
            let best = sides.max { a,b in
                a.map { joints[$0]?.confidence ?? 0 }.reduce(0,+) < b.map { joints[$0]?.confidence ?? 0 }.reduce(0,+)
            }!
            let confidence = best.map { Double(joints[$0]?.confidence ?? 0) }.min() ?? 0
            let shoulderName = best[0], elbowName = best[1], wristName = best[2]
            let shoulder = joints[shoulderName]?.location ?? .zero
            let elbow = joints[elbowName]?.location ?? .zero
            let wrist = joints[wristName]?.location ?? .zero
            let elbowAngle = Self.angle(shoulder,elbow,wrist)
            let armLength = hypot(Double(shoulder.x-elbow.x),Double(shoulder.y-elbow.y))
            let plausiblePeople = candidates.filter { candidate in
                sides.contains { side in side.allSatisfy { (candidate.joints[$0]?.confidence ?? 0) >= 0.20 } }
            }.count
            if confidence >= counter.configuration.minimumConfidence, armLength > 0 {
                counter.ingest(.init(timestamp:now,elbowAngle:elbowAngle,
                                     shoulderY:1-Double(shoulder.y),upperArmLength:armLength,
                                     confidence:confidence,people:plausiblePeople,
                                     side:best == sides[0] ? .left : .right))
            } else { counter.trackingLost(at:now,reason:.lowConfidence,people:plausiblePeople,confidence:confidence) }
            publish(points:visible, detectedPeople:plausiblePeople, now:now)
        } catch {
            counter.trackingLost(at:now); publish(points:[:], detectedPeople:0, now:now)
        }
    }
    private func publish(points: [VNHumanBodyPoseObservation.JointName:CGPoint], detectedPeople: Int,
                         now: TimeInterval) {
        let displayPoints: [VNHumanBodyPoseObservation.JointName:CGPoint]
        let opacity: Double
        if points.count >= 6 {
            lastStrongPoints = points; lastStrongPointsAt = now
            displayPoints = points; opacity = 1
        } else if let lastStrongPointsAt, now - lastStrongPointsAt <= 0.3 {
            displayPoints = lastStrongPoints
            opacity = max(0.2, 1 - (now - lastStrongPointsAt) / 0.3)
        } else {
            displayPoints = points; opacity = points.isEmpty ? 0 : 1
        }
        let count = counter.count, tracking = counter.tracking, motion = counter.lastMotionAt, phase = counter.phase
        let diagnostic = counter.diagnostics
        var limitReached = false
        if let diagnostic, practiceLog != nil {
            limitReached = !practiceLog!.append(diagnostic)
        }
        DispatchQueue.main.async {
            self.points = displayPoints; self.count = count; self.tracking = tracking; self.lastMotion = motion
            self.detectedJointCount = points.count; self.detectedPeople = detectedPeople
            self.phase = phase; self.diagnostic = diagnostic; self.skeletonOpacity = opacity
            if limitReached { self.practiceLimitReached = true }
        }
    }
    private static func angle(_ a: CGPoint,_ b: CGPoint,_ c: CGPoint) -> Double {
        let x1 = Double(a.x-b.x), y1 = Double(a.y-b.y), x2 = Double(c.x-b.x), y2 = Double(c.y-b.y)
        let d = hypot(x1,y1)*hypot(x2,y2)
        guard d > 0 else { return 0 }
        return acos(max(-1,min(1,(x1*x2+y1*y2)/d))) * 180 / .pi
    }
    deinit { observations.forEach(NotificationCenter.default.removeObserver) }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView { let view = PreviewView(); view.preview.session = session; return view }
    func updateUIView(_ view: PreviewView, context: Context) {}
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override func layoutSubviews() {
            super.layoutSubviews()
            preview.videoGravity = .resizeAspect
            if let connection = preview.connection {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = true }
            }
        }
    }
}
