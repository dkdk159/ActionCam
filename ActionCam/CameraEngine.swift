import Foundation
import AVFoundation
import Speech
import Photos
import CoreMotion
import UIKit
import Combine

// MARK: - 选项
enum CameraLens: String, CaseIterable, Identifiable {
    case ultraWide = "超广角"
    case wide = "广角"
    case telephoto = "长焦"
    case front = "前置"
    var id: String { rawValue }
    var short: String {
        switch self {
        case .ultraWide: return "0.5"
        case .wide: return "1"
        case .telephoto: return "2"
        case .front: return "前置"
        }
    }
}

enum VideoResolution: String, CaseIterable, Identifiable {
    case hd720 = "720P"
    case hd1080 = "1080P"
    case uhd4K = "4K"
    var id: String { rawValue }
    var preset: AVCaptureSession.Preset {
        switch self {
        case .hd720: return .hd1280x720
        case .hd1080: return .hd1920x1080
        case .uhd4K: return .hd4K3840x2160
        }
    }
    var dimensions: (w: Int, h: Int) {
        switch self {
        case .hd720: return (1280, 720)
        case .hd1080: return (1920, 1080)
        case .uhd4K: return (3840, 2160)
        }
    }
}

enum FrameRateOption: Int, CaseIterable, Identifiable {
    case fps24 = 24, fps30 = 30, fps60 = 60
    var id: Int { rawValue }
    var label: String { "\(rawValue) fps" }
}

enum StabilizationLevel: String, CaseIterable, Identifiable {
    case auto = "自动"
    case standard = "标准"
    case cinematic = "影院级"
    case off = "关闭"
    var id: String { rawValue }
    var mode: AVCaptureVideoStabilizationMode {
        switch self {
        case .auto: return .auto
        case .standard: return .standard
        case .cinematic: return .cinematic
        case .off: return .off
        }
    }
}

/// 预录时长（预录帧是"按下之前"的画面）
enum PreRecordDuration: Int, CaseIterable, Identifiable {
    case s5 = 5, s15 = 15, s30 = 30, s60 = 60, s120 = 120
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .s5: return "5秒"
        case .s15: return "15秒"
        case .s30: return "30秒"
        case .s60: return "1分钟"
        case .s120: return "2分钟"
        }
    }
}

/// 省电：无操作自动熄屏
enum ScreenOffOption: Int, CaseIterable, Identifiable {
    case s5 = 5, s15 = 15, s30 = 30, s60 = 60, never = 0
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .s5: return "5秒"
        case .s15: return "15秒"
        case .s30: return "30秒"
        case .s60: return "1分钟"
        case .never: return "永不息屏"
        }
    }
}

// MARK: - 语音控制
final class VoiceCommandManager {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onListeningChanged: ((Bool) -> Void)?

    private(set) var startWords: [String] = ["开启录像", "开始录像", "开始录制", "开始拍摄"]
    private(set) var stopWords: [String] = ["关闭录像", "停止录像", "结束录像", "停止录制", "停止拍摄", "保存"]

    private var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var running = false
    private var useOnDevice = true
    private var lastStart = Date.distantPast
    private var lastStop = Date.distantPast

    func setWords(start: [String], stop: [String]) {
        if !start.isEmpty { startWords = start }
        if !stop.isEmpty { stopWords = stop }
    }

    func start() {
        lock.lock(); let busy = running; lock.unlock()
        guard !busy else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] st in
            guard let self = self else { return }
            guard st == .authorized else {
                Log.write("[语音] 未授权 st=\(st.rawValue)")
                return
            }
            DispatchQueue.main.async { self.begin() }
        }
    }

    func stop() {
        lock.lock()
        running = false
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        lock.unlock()
        onListeningChanged?(false)
    }

    private func begin() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()
        startTask()
    }

    /// 建/重建一次识别任务。restart 复用它（上一版就是这里没复位 running，导致语音只生效一次）
    private func startTask() {
        lock.lock()
        guard running else { lock.unlock(); return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        let supportsOffline = recognizer?.supportsOnDeviceRecognition ?? false
        if supportsOffline && useOnDevice { req.requiresOnDeviceRecognition = true }
        request = req
        lock.unlock()
        onListeningChanged?(true)
        guard let rec = recognizer else {
            Log.write("[语音] zh-CN 识别器不可用")
            return
        }
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                self.handle(text)
                if result.isFinal {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.restart() }
                }
            } else if let error = error {
                Log.write("[语音] 错误 \(error.localizedDescription)")
                if supportsOffline { self.useOnDevice = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.restart() }
            }
        }
    }

    private func restart() {
        guard running else { return }
        lock.lock()
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self, self.running else { return }
            self.startTask()
        }
    }

    private func handle(_ text: String) {
        let t = text.replacingOccurrences(of: " ", with: "")
        guard !t.isEmpty else { return }
        let now = Date()
        if startWords.contains(where: { t.contains($0) }) {
            if now.timeIntervalSince(lastStart) > 2.5 {
                lastStart = now
                Log.write("[语音] 开启录像")
                DispatchQueue.main.async { [weak self] in self?.onStart?() }
            }
        } else if stopWords.contains(where: { t.contains($0) }) {
            if now.timeIntervalSince(lastStop) > 2.5 {
                lastStop = now
                Log.write("[语音] 停止录像")
                DispatchQueue.main.async { [weak self] in self?.onStop?() }
            }
        }
    }

    func feed(_ sample: CMSampleBuffer) {
        lock.lock(); let req = request; lock.unlock()
        guard running, let r = req, let pcm = sample.toPCMBuffer() else { return }
        if let mono = Self.resampleTo16k(pcm) { r.append(mono) }
    }

    private static func resampleTo16k(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if Int(src.format.sampleRate) == 16000 && src.format.channelCount == 1 { return src }
        guard let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: src.format, to: dst) else { return nil }
        let ratio = 16000.0 / src.format.sampleRate
        let capacity = AVAudioFrameCount(Double(src.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: capacity) else { return nil }
        var fed = false
        var attempts = 0
        while attempts < 6 {
            attempts += 1
            var err: NSError?
            let status = converter.convert(to: out, error: &err) { _, inputStatus in
                if fed { inputStatus.pointee = .endOfStream; return nil }
                fed = true
                inputStatus.pointee = .haveData
                return src
            }
            if status == .error { return nil }
            if status == .endOfStream { break }
            if status == .haveData && out.frameLength > 0 { break }
        }
        return out.frameLength > 0 ? out : nil
    }
}

// MARK: - 电池
final class BatteryMonitor {
    private var timer: Timer?
    func start(_ handler: @escaping (Float) -> Void) {
        UIDevice.current.isBatteryMonitoringEnabled = true
        handler(max(UIDevice.current.batteryLevel, 0))
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            handler(max(UIDevice.current.batteryLevel, 0))
        }
    }
}

// MARK: - 水平仪
final class MotionManager: ObservableObject {
    @Published var roll: Double = 0
    @Published var pitch: Double = 0
    @Published var isLevel = false
    private let manager = CMMotionManager()
    func start() {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 0.1
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self = self, let m = motion else { return }
            self.roll = m.attitude.roll
            self.pitch = m.attitude.pitch
            self.isLevel = abs(m.attitude.roll) < 0.03
        }
    }
    func stop() { manager.stopDeviceMotionUpdates() }
}

// MARK: - 相册
enum PhotoLibrary {
    static func save(_ url: URL, completion: @escaping (Bool) -> Void) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.write("[相册] 文件不存在")
            completion(false)
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Log.write("[相册] 无权限 \(status.rawValue)")
                completion(false)
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { ok, err in
                if let err = err {
                    Log.write("[相册] 失败 \(err.localizedDescription)")
                } else {
                    Log.write("[相册] 保存\(ok ? "成功" : "失败")")
                }
                completion(ok)
            }
        }
    }
}

// MARK: - 相机引擎
final class CameraEngine: NSObject, ObservableObject {
    // 对外状态
    @Published var isRecording = false
    @Published var recordSeconds = 0
    @Published var statusMessage: String?
    @Published var voiceListening = false
    @Published var batteryLevel: Float = 1
    @Published var torchOn = false
    @Published var screenDimmed = false
    @Published var showLog = false
    @Published var logText = ""
    @Published var encodedFrameCount = 0
    @Published var bufferedFrameCount = 0

    // 设置
    @Published var lens: CameraLens = .wide { didSet { if oldValue != lens { switchLens() } } }
    @Published var resolution: VideoResolution = .hd1080 { didSet { if oldValue != resolution { reconfigure() } } }
    @Published var frameRate: FrameRateOption = .fps30 { didSet { if oldValue != frameRate { applyFrameRate() } } }
    @Published var stabilization: StabilizationLevel = .auto { didSet { if oldValue != stabilization { applyStabilization() } } }
    @Published var preRecordEnabled = false { didSet { if oldValue != preRecordEnabled { rebuildBuffers() } } }
    @Published var preRecordDuration: PreRecordDuration = .s15 { didSet { if oldValue != preRecordDuration { rebuildBuffers() } } }
    @Published var screenOffOption: ScreenOffOption = .never { didSet { resetScreenOffTimer() } }
    @Published var showGrid = false
    @Published var showLevel = false
    @Published var beepEnabled = true
    @Published var mirrorRear = false { didSet { applyOrientation() } }
    @Published var debugInfo = false
    @Published var voiceEnabled = false { didSet { if oldValue != voiceEnabled { voiceEnabled ? startVoice() : stopVoice() } } }
    @Published var startWords: [String] = ["开启录像", "开始录像", "开始录制", "开始拍摄"]
    @Published var stopWords: [String] = ["关闭录像", "停止录像", "结束录像", "停止录制", "保存"]

    let session = AVCaptureSession()
    let motion = MotionManager()

    private let sessionQueue = DispatchQueue(label: "com.actioncam.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let encoder = H264Encoder()
    private let writer = MovieWriter()
    private let sound = SoundPlayer()
    private let voice = VoiceCommandManager()
    private let battery = BatteryMonitor()

    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?

    private var videoRing: RingBuffer<CMSampleBuffer>?
    private var audioRing: RingBuffer<CMSampleBuffer>?
    private var encoderSize = CGSize.zero
    private var lastKeyPTS = CMTime.invalid
    private var fileSequence = 0
    private var configured = false

    // 跨线程状态
    private let stateLock = NSLock()
    private var _recording = false
    private var _starting = false
    private var _live = false
    private var _pendingStart = false
    private var _voiceFlag = false

    private var recordingFlag: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _recording }
    private var pendingStartFlag: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _pendingStart }
    private var preRecordFlag: Bool { preRecordEnabled }
    private var voiceFlag: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _voiceFlag }

    private var watchdog: Timer?
    private var recordTimer: Timer?
    private var screenOffTimer: Timer?
    private var infoTimer: Timer?

    // MARK: 生命周期
    func prepare() {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, mode: .default,
                                      options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        try? audioSession.setActive(true)

        motion.start()
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }

        infoTimer?.invalidate()
        infoTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.debugInfo || self.showLog else { return }
            let info = "编码:\(self.encodedFrameCount) 缓冲:\(self.videoRing?.count ?? 0) "
                + "录制:\(self.isRecording ? "Y" : "N") 写入:\(self._live ? "live" : (self._starting ? "starting" : "-"))"
            self.logText = info + "\n" + LogBuffer.text()
        }

        battery.start { [weak self] level in
            DispatchQueue.main.async { self?.batteryLevel = level }
        }

        encoder.onSample = { [weak self] sample in self?.handleEncoded(sample) }
        voice.onListeningChanged = { [weak self] on in
            DispatchQueue.main.async { self?.voiceListening = on }
        }
        voice.onStart = { [weak self] in
            guard let self = self else { return }
            if !self.recordingFlag { self.startRecording() }
        }
        voice.onStop = { [weak self] in
            guard let self = self else { return }
            if self.recordingFlag { self.stopRecording() }
        }

        sessionQueue.async { [weak self] in self?.configureSession() }
    }

    private func configureSession() {
        guard !configured else { return }
        configured = true
        session.beginConfiguration()
        if session.canSetSessionPreset(resolution.preset) { session.sessionPreset = resolution.preset }

        if let device = deviceFor(lens),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            videoDevice = device
            videoInput = input
        }
        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        applyOrientationLocked()
        applyStabilizationLocked()
        session.commitConfiguration()
        applyFrameRateLocked()
        rebuildBuffers()
        session.startRunning()
        Log.write("[会话] 启动 \(resolution.rawValue) \(lens.rawValue)")
    }

    private func deviceFor(_ target: CameraLens) -> AVCaptureDevice? {
        switch target {
        case .ultraWide:
            return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .wide:
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .telephoto:
            return AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .front:
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
    }

    func switchLens() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.recordingFlag {
                Log.write("[镜头] 录制中不切换")
                return
            }
            guard let device = self.deviceFor(self.lens),
                  let newInput = try? AVCaptureDeviceInput(device: device) else { return }
            if self.lens == .front, self.videoDevice?.position == .back, self.torchOn {
                self.setTorchLocked(false)
            }
            self.session.beginConfiguration()
            if let old = self.videoInput { self.session.removeInput(old) }
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoInput = newInput
                self.videoDevice = device
            } else if let old = self.videoInput {
                self.session.addInput(old)
            }
            self.applyOrientationLocked()
            self.applyStabilizationLocked()
            self.session.commitConfiguration()
            self.videoRing?.removeAll()
            self.audioRing?.removeAll()
            self.encoderSize = .zero
            DispatchQueue.main.async { self.torchOn = false }
            Log.write("[镜头] 切换 \(self.lens.rawValue)")
        }
    }

    private func reconfigure() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.recordingFlag {
                Log.write("[会话] 录制中不切换分辨率")
                return
            }
            self.session.beginConfiguration()
            if self.session.canSetSessionPreset(self.resolution.preset) {
                self.session.sessionPreset = self.resolution.preset
            }
            self.session.commitConfiguration()
            self.applyFrameRateLocked()
            self.videoRing?.removeAll()
            self.audioRing?.removeAll()
            self.encoderSize = .zero
            Log.write("[会话] 分辨率 \(self.resolution.rawValue)")
        }
    }

    func applyFrameRate() { sessionQueue.async { [weak self] in self?.applyFrameRateLocked() } }

    private func applyFrameRateLocked() {
        guard let device = videoDevice else { return }
        let fps = Double(frameRate.rawValue)
        do {
            try device.lockForConfiguration()
            let target = resolution.dimensions
            if let format = device.formats.first(where: { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard Int(dims.width) >= target.w, Int(dims.height) >= target.h else { return false }
                return format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
            }) {
                device.activeFormat = format
            }
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            Log.write("[会话] 帧率设置失败 \(error.localizedDescription)")
        }
    }

    func applyStabilization() { sessionQueue.async { [weak self] in self?.applyStabilizationLocked() } }

    private func applyStabilizationLocked() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = stabilization.mode
        }
    }

    func applyOrientation() { sessionQueue.async { [weak self] in self?.applyOrientationLocked() } }

    private func applyOrientationLocked() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = (lens == .front) ? !mirrorRear : mirrorRear
        }
    }

    // MARK: 缓冲
    private func rebuildBuffers() {
        let seconds = preRecordEnabled ? preRecordDuration.rawValue : 3
        let fps = max(Double(frameRate.rawValue), 24)
        videoRing = RingBuffer(capacity: Int(fps * Double(seconds)))
        audioRing = RingBuffer(capacity: Int(48 * Double(seconds)))
        Log.write("[缓冲] 预录\(preRecordEnabled ? "\(seconds)秒" : "关") 视频\(Int(fps * Double(seconds))) 音频\(Int(48 * Double(seconds)))")
    }

    // MARK: 录制
    func startRecording() {
        stateLock.lock()
        if _recording || _starting {
            stateLock.unlock()
            return
        }
        _recording = true
        _starting = true
        _live = false
        stateLock.unlock()

        resetScreenOffTimer()
        armWatchdog()
        if beepEnabled { sound.playStart() }

        DispatchQueue.main.async {
            self.isRecording = true
            self.recordSeconds = 0
            self.startRecordTimer()
        }

        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.recordingFlag else { return }
            if self.preRecordEnabled {
                let window = Self.trimToFirstSync(self.videoRing?.snapshot() ?? [])
                if window.isEmpty {
                    self.markPendingStart()
                    Log.write("[录制] 缓冲内暂无关键帧，等待下一帧关键帧")
                    return
                }
                let startTime = samplePTS(window[0])
                let audios = (self.audioRing?.snapshot() ?? []).filter {
                    CMTimeCompare(samplePTS($0), startTime) >= 0
                }
                Log.write("[录制] 预录窗口 \(window.count) 帧")
                self.launchWriter(video: window, audio: audios)
            } else {
                // 未开预录：从"现在"开始，等下一个关键帧
                self.markPendingStart()
                Log.write("[录制] 未开预录，从当前时刻开始")
            }
        }
    }

    private func markPendingStart() {
        stateLock.lock()
        if _recording { _pendingStart = true }
        stateLock.unlock()
    }

    func stopRecording() {
        stateLock.lock()
        let wasActive = _recording || _starting
        let hadWriter = _live
        _recording = false
        _starting = false
        _live = false
        _pendingStart = false
        stateLock.unlock()
        guard wasActive else { return }

        if beepEnabled { sound.playStop() }
        DispatchQueue.main.async {
            self.disarmWatchdog()
            self.isRecording = false
            self.stopRecordTimer()
        }
        resetScreenOffTimer()

        writer.finish { [weak self] url in
            guard let self = self else { return }
            guard let url = url else {
                if hadWriter {
                    DispatchQueue.main.async { self.toast("保存失败，请看日志") }
                }
                return
            }
            PhotoLibrary.save(url) { ok in
                DispatchQueue.main.async {
                    self.toast(ok ? "已保存到相册 · \(self.recordSeconds)秒" : "保存相册失败（请检查相册权限）")
                }
            }
        }
    }

    private func handleEncoded(_ sample: CMSampleBuffer) {
        encodedFrameCount &+= 1
        let needRing = preRecordFlag
        let needStart = pendingStartFlag
        let needWrite = recordingFlag
        guard needRing || needStart || needWrite else { return }
        // 关键：深拷贝成独立内存，否则回调返回后就是悬垂指针
        guard let frame = sample.deepCopy() else { return }
        if needRing { videoRing?.append(frame) }

        if needStart {
            guard frame.isSync else { return }
            stateLock.lock(); _pendingStart = false; stateLock.unlock()
            let startTime = samplePTS(frame)
            let audios = (audioRing?.snapshot() ?? []).filter {
                CMTimeCompare(samplePTS($0), startTime) >= 0
            }
            Log.write("[录制] 关键帧到达，启动写入")
            launchWriter(video: [frame], audio: audios)
            return
        }
        if needWrite { writer.appendVideo(frame) }
    }

    private func launchWriter(video: [CMSampleBuffer], audio: [CMSampleBuffer]) {
        guard !video.isEmpty else {
            resetAfterFailure("录像启动失败：没有画面")
            return
        }
        let url = nextFileURL()
        writer.start(video: video, audio: audio, url: url, transform: .identity) { [weak self] ok in
            guard let self = self else { return }
            self.stateLock.lock()
            self._starting = false
            let stillWanted = self._recording
            if ok && stillWanted { self._live = true }
            self.stateLock.unlock()
            self.disarmWatchdog()
            if !ok && stillWanted {
                self.resetAfterFailure("录像启动失败，请看日志")
            }
        }
    }

    private func resetAfterFailure(_ message: String) {
        stateLock.lock()
        _recording = false
        _starting = false
        _live = false
        _pendingStart = false
        stateLock.unlock()
        writer.cancel()
        DispatchQueue.main.async {
            self.disarmWatchdog()
            self.isRecording = false
            self.stopRecordTimer()
            self.toast(message)
        }
    }

    /// 看门狗：8 秒内没有真正进入写入状态就中止复位，避免"点了没反应"永久卡死
    private func armWatchdog() {
        disarmWatchdog()
        watchdog = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.stateLock.lock()
            let neverLive = self._starting || !self._live
            self.stateLock.unlock()
            guard neverLive, self._recording else { return }
            Log.write("[录制] 启动超时(8秒)，已复位")
            self.writer.cancel()
            self.resetAfterFailure("录像启动超时，请看日志")
        }
    }

    private func disarmWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private static func trimToFirstSync(_ samples: [CMSampleBuffer]) -> [CMSampleBuffer] {
        guard let index = samples.firstIndex(where: { $0.isSync }) else { return [] }
        return Array(samples[index...])
    }

    private func nextFileURL() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        fileSequence += 1
        return dir.appendingPathComponent("ActionCam_\(formatter.string(from: Date()))_\(fileSequence).mp4")
    }

    // MARK: 手电筒
    func toggleTorch() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let next = !self.torchOn
            self.setTorchLocked(next)
            DispatchQueue.main.async { self.torchOn = next }
        }
    }

    private func setTorchLocked(_ on: Bool) {
        guard let device = videoDevice, device.hasTorch,
              device.isTorchModeSupported(on ? .on : .off) else { return }
        try? device.lockForConfiguration()
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    // MARK: 语音
    private func startVoice() {
        stateLock.lock(); _voiceFlag = true; stateLock.unlock()
        voice.setWords(start: startWords, stop: stopWords)
        voice.start()
    }

    private func stopVoice() {
        stateLock.lock(); _voiceFlag = false; stateLock.unlock()
        voice.stop()
    }

    func applyVoiceWords() {
        voice.setWords(start: startWords, stop: stopWords)
    }

    // MARK: 计时 / 提示 / 熄屏
    private func startRecordTimer() {
        recordTimer?.invalidate()
        recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.recordSeconds += 1
            self.resetScreenOffTimer()
        }
    }

    private func stopRecordTimer() {
        recordTimer?.invalidate()
        recordTimer = nil
    }

    func toast(_ text: String) {
        DispatchQueue.main.async {
            self.statusMessage = text
            if text.contains("失败") || text.contains("超时") || text.contains("错误") {
                self.showLog = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.showLog = false }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                if self?.statusMessage == text { self?.statusMessage = nil }
            }
        }
    }

    func resetScreenOffTimer() {
        screenOffTimer?.invalidate()
        let seconds = screenOffOption.rawValue
        guard seconds > 0 else { return }
        screenOffTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.screenDimmed = true }
        }
    }

    func wakeScreen() {
        screenDimmed = false
        resetScreenOffTimer()
    }

    func openPhotos() {
        if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}

// MARK: - 采集回调
extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            handleVideo(sampleBuffer)
        } else if output === audioOutput {
            handleAudio(sampleBuffer)
        }
    }

    private func handleVideo(_ sample: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        if encoderSize != CGSize(width: w, height: h) {
            encoderSize = CGSize(width: w, height: h)
            videoRing?.removeAll()
            audioRing?.removeAll()
            lastKeyPTS = .invalid
            let bitrate = max(w * h * 3, 6_000_000)
            encoder.configure(width: w, height: h, fps: frameRate.rawValue, bitrate: bitrate)
            if recordingFlag {
                Log.write("[采集] 录制中画面尺寸变化，停止录制")
                DispatchQueue.main.async { self.stopRecording() }
                return
            }
        }

        let pts = samplePTS(sample)
        var forceKey = false
        if pendingStartFlag {
            forceKey = true
        } else if !lastKeyPTS.isValid || CMTimeGetSeconds(CMTimeSubtract(pts, lastKeyPTS)) >= 1.0 {
            forceKey = true
            lastKeyPTS = pts
        }
        encoder.encode(pixelBuffer, at: pts, forceKey: forceKey)
    }

    private func handleAudio(_ sample: CMSampleBuffer) {
        if voiceFlag { voice.feed(sample) }
        let needRing = preRecordFlag || recordingFlag || pendingStartFlag
        guard needRing else { return }
        guard let copy = sample.deepCopy() else { return }
        audioRing?.append(copy)
        if recordingFlag { writer.appendAudio(copy) }
    }
}
