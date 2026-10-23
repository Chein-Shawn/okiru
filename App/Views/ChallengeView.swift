import SwiftUI
import Vision
import UniformTypeIdentifiers
import OkiruCore

struct PracticeJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents:data) }
}

struct ChallengeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var scenePhase
    @StateObject private var camera = CameraController()
    @StateObject private var audio = AudioController()
    @State private var reviewing: PracticeDiagnosticLog?
    @State private var practiceClosing = false
    @State private var exporting = false
    @State private var exportDocument: PracticeJSONDocument?
    @State private var exportError: String?
    let route: ChallengeRoute
    var event: AlarmOccurrence? { model.occurrences.first { $0.id == route.occurrenceID } }
    var practice: Bool { route.occurrenceID == nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing:18) {
                    progressHeader
                    if let reviewing { practiceReview(reviewing) }
                    else { activeContent }
                }.padding(20)
            }
            .navigationTitle(tr(practice ? "practice" : "task.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if practice && reviewing == nil {
                    ToolbarItem(placement:.topBarLeading) { Button(tr("close")) { finishPractice(reason:"exited") } }
                }
            }
        }
        .interactiveDismissDisabled(true)
        .onAppear {
            AppDelegate.challengeVisible = true
            audio.onPlaybackChange = { AppDelegate.challengeAudioPlaying = $0 }
            UIApplication.shared.isIdleTimerDisabled = true
            start()
        }
        .onDisappear { camera.stop(); audio.stop(); audio.onPlaybackChange = nil; AppDelegate.challengeAudioPlaying = false; AppDelegate.challengeVisible = false; UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of:scenePhase) { _,phase in
            if phase == .active && !practiceClosing { start() }
            else { camera.stop(); audio.stop(); AppDelegate.challengeAudioPlaying = false }
        }
        .onChange(of:camera.count) { _,count in
            if let id = route.occurrenceID { Task { await model.recordReps(count,occurrenceID:id) } }
            else if count >= 10 { finishPractice(reason:"completed") }
        }
        .onChange(of:camera.practiceLimitReached) { _,reached in if reached { finishPractice(reason:"limitReached") } }
        .fileExporter(isPresented:$exporting,document:exportDocument,contentType:.json,defaultFilename:"okiru-practice-diagnostics") { result in
            switch result {
            case .success: discardPractice()
            case .failure(let error): exportError = error.localizedDescription
            }
        }
        .alert(tr("attention"),isPresented:Binding(get:{ model.errorMessage != nil },set:{ if !$0 { model.errorMessage = nil } })) {
            Button(tr("ok"),role:.cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
    private var progressHeader: some View {
        TimelineView(.periodic(from:.now,by:1)) { timeline in
            VStack(spacing:8) {
                Text(tf("reps.target.format",camera.count,event?.alarm.targetReps ?? 10))
                    .font(.system(size:58,weight:.bold,design:.rounded)).contentTransition(.numericText())
                if let event {
                    let remaining = max(0,event.deadline.timeIntervalSince(timeline.date))
                    Text(remaining > 0 ? Duration.seconds(remaining).formatted(.time(pattern:.minuteSecond))
                         : tf("challenge.late.target",event.alarm.targetReps >= 50 ? 10 : 5))
                        .font(.title3.monospacedDigit()).foregroundStyle(remaining > 0 ? Color.secondary : Color.orange)
                    if !event.resolved && timeline.date < event.reminderEnd {
                        Text(tr(camera.tracking ? "camera.keepGoing" : "challenge.cue"))
                            .font(.subheadline.bold()).foregroundStyle(.orange)
                            .opacity(Int(timeline.date.timeIntervalSince(event.scheduledAt)/5)%2 == 0 ? 1 : 0.65)
                    }
                } else { Text(tr("practice.note")).font(.caption).foregroundStyle(.secondary) }
            }.onChange(of:timeline.date) { _,_ in audio.update() }
        }
    }
    private var activeContent: some View {
        VStack(spacing:18) {
            cameraPanel
            if practice { practiceDiagnostics }
            else { Text(tr(camera.tracking ? "camera.tracking" : "camera.guide"))
                .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary) }
            if practice {
                Button(tr(camera.count == 10 ? "done" : "close")) {
                    finishPractice(reason:camera.count >= 10 ? "completed" : "exited")
                }.buttonStyle(.borderedProminent)
            } else { EmergencyButton() }
            Text(tr("challenge.leaveNote")).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
    private var cameraPanel: some View {
        ZStack {
            Color.black
            CameraPreview(session:camera.session)
            SkeletonOverlay(points:camera.points).opacity(camera.skeletonOpacity)
            VStack {
                HStack {
                    Image(systemName:camera.detectedJointCount > 0 ? "figure.stand" : "viewfinder")
                    Text(camera.detectedJointCount > 0 ? tr("camera.tracking") : tr("camera.guide")).lineLimit(2)
                    Spacer(minLength:0)
                }.font(.caption.bold()).foregroundStyle(.white)
                    .padding(.horizontal,12).padding(.vertical,9)
                    .background(.black.opacity(0.62),in:Capsule()).padding(12)
                Spacer()
            }
            if let key = camera.errorKey {
                VStack(spacing:12) {
                    Image(systemName:"camera.fill").font(.largeTitle)
                    Text(tr(key)).multilineTextAlignment(.center)
                    Button(tr("openSettings")) {
                        if let url = URL(string:UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }.buttonStyle(.bordered)
                }.padding().foregroundStyle(.white).background(.black.opacity(0.7),in:RoundedRectangle(cornerRadius:18)).padding()
            }
        }.aspectRatio(9.0/16.0,contentMode:.fit).frame(maxHeight:430).clipShape(RoundedRectangle(cornerRadius:24))
    }
    private func start() {
        guard !practiceClosing else { return }
        camera.start(initialCount:event?.reps ?? camera.count,target:event?.alarm.targetReps ?? 10,practice:practice)
        if let event, !event.resolved {
            do {
                try audio.play(event.alarm.sound,until:event.reminderEnd)
                AppDelegate.challengeAudioPlaying = audio.isPlaying
                // Do not silence the system alarm until this screen has mounted
                // and its replacement audio is actually playing.
                if audio.isPlaying { model.scheduler.stopCurrentSound(for:event.alarm.id) }
            }
            catch { AppDelegate.challengeAudioPlaying = false; model.errorMessage = error.localizedDescription }
        }
    }
    private var practiceCue: String {
        guard camera.tracking else { return tr("camera.guide") }
        switch camera.phase {
        case .ready: return tr("camera.guide")
        case .upper: return "↓ " + tr("camera.tracking")
        case .lower: return "↑ " + tr("camera.keepGoing")
        }
    }
    private func finishPractice(reason: String) {
        guard practice, !practiceClosing else { return }
        practiceClosing = true
        camera.stop()
        camera.finishPractice(reason:reason) { log in
            if let log { reviewing = log }
            else { dismiss() }
        }
    }
    private func discardPractice() {
        reviewing = nil; exportDocument = nil; exportError = nil
        dismiss()
    }
    private func exportPractice() {
        guard let reviewing else { return }
        do { exportDocument = PracticeJSONDocument(data:try reviewing.jsonData()); exportError = nil; exporting = true }
        catch { exportError = error.localizedDescription }
    }
    private func practiceReview(_ log: PracticeDiagnosticLog) -> some View {
        VStack(alignment:.leading,spacing:14) {
            Text(tr("practice.review")).font(.title2.bold())
            Text(tf("practice.samples",log.records.count)).foregroundStyle(.secondary)
            Text(tf("reps.target.format",camera.count,10)).font(.title.monospacedDigit())
            if let last = log.records.last { Text(tr("diagnostic.reason")+": "+tr("diagnostic.reason."+last.reason.rawValue)) }
            if let exportError { Text(exportError).foregroundStyle(.orange) }
            Button(tr("practice.export")) { exportPractice() }.buttonStyle(.borderedProminent)
            Button(tr("practice.discard"),role:.destructive) { discardPractice() }
            Text(tr("practice.ephemeral")).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private var practiceDiagnostics: some View {
        VStack(alignment:.leading,spacing:8) {
            Text(practiceCue).font(.headline)
            if let d = camera.diagnostic {
                diagnosticRow("diagnostic.reason",tr("diagnostic.reason."+d.reason.rawValue))
                diagnosticRow("diagnostic.phase",tr("diagnostic.phase."+d.phase.rawValue))
                diagnosticRow("diagnostic.side",tr("diagnostic.side."+d.side.rawValue))
                diagnosticRow("diagnostic.people",String(d.people))
                diagnosticRow("diagnostic.confidence",format(d.confidence))
                diagnosticRow("diagnostic.rawAngle",angle(d.rawElbowAngle))
                diagnosticRow("diagnostic.usedAngle",angle(d.smoothedElbowAngle))
                diagnosticRow("diagnostic.elbowCheck",criterion(d.smoothedElbowAngle.map {
                    switch d.evaluationPhase {
                    case .ready: return $0 >= d.configuration.upperAngle
                    case .upper: return $0 <= d.configuration.lowerAngle
                    case .lower: return $0 >= d.configuration.returnAngle
                    }
                }))
                diagnosticRow("diagnostic.upperThreshold","≥ "+angle(d.configuration.upperAngle))
                diagnosticRow("diagnostic.lowerThreshold","≤ "+angle(d.configuration.lowerAngle))
                diagnosticRow("diagnostic.returnAngle","≥ "+angle(d.configuration.returnAngle))
                diagnosticRow("diagnostic.rawShoulderY",format(d.rawShoulderY))
                diagnosticRow("diagnostic.shoulderY",format(d.smoothedShoulderY))
                diagnosticRow("diagnostic.topShoulderY",format(d.topShoulderY))
                diagnosticRow("diagnostic.armScale",format(d.armScale))
                diagnosticRow("diagnostic.drop",format(d.shoulderDropInArmLengths)+" × "+tr("diagnostic.armLength"))
                diagnosticRow("diagnostic.rise",format(d.shoulderRiseInArmLengths)+" × "+tr("diagnostic.armLength"))
                diagnosticRow("diagnostic.lowestAngle",angle(d.lowestElbowAngle))
                diagnosticRow("diagnostic.shoulderCheck",criterion(d.evaluationPhase == .ready ? nil :
                    d.evaluationPhase == .upper
                        ? d.shoulderDropInArmLengths.map { $0 >= d.configuration.minimumShoulderDropInArmLengths }
                        : d.shoulderRiseInArmLengths.map { $0 >= d.configuration.minimumReturnRiseInArmLengths }))
                diagnosticRow("diagnostic.lowerDrop","≥ "+format(d.configuration.minimumShoulderDropInArmLengths))
                diagnosticRow("diagnostic.returnRise","≥ "+format(d.configuration.minimumReturnRiseInArmLengths))
                diagnosticRow("diagnostic.stable",format(d.stableElapsed)+" / "+format(d.configuration.stableSeconds)+" s")
                diagnosticRow("diagnostic.cycle",format(d.cycleElapsed)+" / "+format(d.configuration.minimumCycleSeconds)+" s")
                diagnosticRow("diagnostic.loss",format(d.trackingLossElapsed)+" / "+format(d.configuration.trackingLossGraceSeconds)+" s")
                Text(tr(d.tracked ? "diagnostic.live" : "diagnostic.stale"))
                    .font(.caption.bold()).foregroundStyle(d.tracked ? .green : .orange)
            } else { Text(tr("camera.guide")).font(.caption) }
        }.padding().frame(maxWidth:.infinity,alignment:.leading)
            .background(.regularMaterial,in:RoundedRectangle(cornerRadius:16))
    }
    private func diagnosticRow(_ key: String,_ value: String) -> some View {
        HStack(alignment:.firstTextBaseline) {
            Text(tr(key)).foregroundStyle(.secondary)
            Spacer(minLength:8)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }.font(.caption)
    }
    private func format(_ number: Double?) -> String { number.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—" }
    private func angle(_ number: Double?) -> String { number.map { $0.formatted(.number.precision(.fractionLength(1)))+"°" } ?? "—" }
    private func criterion(_ passes: Bool?) -> String { passes.map { $0 ? "✓" : "✕" } ?? "—" }
}

struct SkeletonOverlay: View {
    var points: [VNHumanBodyPoseObservation.JointName:CGPoint]
    private let bones: [(VNHumanBodyPoseObservation.JointName,VNHumanBodyPoseObservation.JointName)] = [
        (.leftShoulder,.rightShoulder),(.leftShoulder,.leftElbow),(.leftElbow,.leftWrist),
        (.rightShoulder,.rightElbow),(.rightElbow,.rightWrist),(.leftShoulder,.leftHip),
        (.rightShoulder,.rightHip),(.leftHip,.rightHip),(.leftHip,.leftKnee),(.leftKnee,.leftAnkle),
        (.rightHip,.rightKnee),(.rightKnee,.rightAnkle)]
    var body: some View {
        Canvas { context,size in
            func point(_ p: CGPoint) -> CGPoint { CGPoint(x:p.x*size.width,y:p.y*size.height) }
            for (a,b) in bones {
                guard let first = points[a], let second = points[b] else { continue }
                var path = Path(); path.move(to:point(first)); path.addLine(to:point(second))
                context.stroke(path,with:.color(.orange),style:.init(lineWidth:3,lineCap:.round))
            }
            for p in points.values {
                let center = point(p)
                context.fill(Path(ellipseIn:CGRect(x:center.x-4,y:center.y-4,width:8,height:8)),with:.color(.white))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct EmergencyButton: View {
    @EnvironmentObject var model: AppModel
    @State private var pressing = false
    @State private var confirm = false
    @State private var reason = ""
    var body: some View {
        Text(tr("emergency.hold")).font(.subheadline.bold()).frame(maxWidth:.infinity).padding()
            .background(pressing ? Color.red.opacity(0.3) : Color.red.opacity(0.08),in:RoundedRectangle(cornerRadius:14))
            .foregroundStyle(.red)
            .onLongPressGesture(minimumDuration:3,perform:{ confirm = true },onPressingChanged:{ pressing = $0 })
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { confirm = true }
            .alert(tr("emergency.title"),isPresented:$confirm) {
                TextField(tr("emergency.reason"),text:$reason)
                Button(tr("cancel"),role:.cancel) {}
                Button(tr("emergency.confirm"),role:.destructive) { Task { await model.emergency(reason:reason) } }
            } message: { Text(tr("emergency.message")) }
    }
}
