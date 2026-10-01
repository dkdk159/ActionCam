import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia
import AudioToolbox

// MARK: - 屏幕日志（排查用，默认不显示，出错自动弹出）
enum LogBuffer {
    private static let lock = NSLock()
    private static var lines: [String] = []
    static func add(_ s: String) {
        lock.lock()
        lines.append(s)
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
        lock.unlock()
    }
    static func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

enum Log {
    static func write(_ s: String) {
        LogBuffer.add(s)
    }
}

// MARK: - 线程安全环形缓冲
final class RingBuffer<T> {
    private var items: [T?]
    private var writeIndex = 0
    private(set) var count = 0
    let capacity: Int
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
        self.items = Array(repeating: nil, count: self.capacity)
    }

    func append(_ element: T) {
        lock.lock(); defer { lock.unlock() }
        items[writeIndex] = element
        writeIndex = (writeIndex + 1) % capacity
        count = min(count + 1, capacity)
    }

    /// 从旧到新返回全部元素
    func snapshot() -> [T] {
        lock.lock(); defer { lock.unlock() }
        guard count > 0 else { return [] }
        var out: [T] = []
        out.reserveCapacity(count)
        let start = count < capacity ? 0 : writeIndex
        for offset in 0..<count {
            if let e = items[(start + offset) % capacity] { out.append(e) }
        }
        return out
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        items = Array(repeating: nil, count: capacity)
        writeIndex = 0
        count = 0
    }
}

// MARK: - CMSampleBuffer 工具
extension CMSampleBuffer {
    /// 是否为关键帧（I 帧）。没有附加信息时保守认为是关键帧。
    var isSync: Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[CFString: Any]],
              let first = arr.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    /// 深拷贝：生成拥有独立内存的副本。
    ///
    /// 这一步是预录功能能不能用的关键！
    /// 采集回调 / 编码回调一旦返回，原始 sampleBuffer 内部的内存就会被系统回收，
    /// 如果我们直接把原对象存进预录缓冲、几十秒后再交给 AVAssetWriter，
    /// 拿到的是悬垂指针 → 写入器直接 .failed（录不出文件 / 保存失败）甚至崩溃。
    func deepCopy() -> CMSampleBuffer? {
        var copy: CMSampleBuffer?
        let st = CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: self, sampleBufferOut: &copy)
        guard st == noErr, let copied = copy else { return nil }
        guard let src = CMSampleBufferGetDataBuffer(self) else { return copied }
        let total = CMBlockBufferGetDataLength(src)
        guard total > 0 else { return copied }
        guard let mem = malloc(total) else { return copied }
        var atOffset = 0, contiguous = 0
        var ptr: UnsafeMutablePointer<Int8>?
        let gp = CMBlockBufferGetDataPointer(src, atOffset: 0,
                                            lengthAtOffsetOut: &atOffset,
                                            totalLengthOut: &contiguous,
                                            dataPointerOut: &ptr)
        // 只处理单块连续内存（采集与编码产出的都是单块）
        guard gp == noErr, let p = ptr, contiguous == total else { free(mem); return copied }
        memcpy(mem, p, total)
        var newBlock: CMBlockBuffer?
        let cs = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                    memoryBlock: mem,
                                                    blockLength: total,
                                                    blockAllocator: kCFAllocatorDefault,
                                                    customBlockSource: nil,
                                                    offsetToData: 0,
                                                    dataLength: total,
                                                    flags: 0,
                                                    blockBufferOut: &newBlock)
        guard cs == noErr, let block = newBlock else { free(mem); return copied }
        CMSampleBufferSetDataBuffer(copied, newValue: block)
        return copied
    }

    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let fmt = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return nil }
        let frames = CMSampleBufferGetNumSamples(self)
        guard frames > 0,
              let format = AVAudioFormat(streamDescription: asbd),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        let ok = CMSampleBufferCopyPCMDataIntoAudioBufferList(self, at: 0, frameCount: Int32(frames),
                                                              into: buf.mutableAudioBufferList)
        return ok == noErr ? buf : nil
    }
}

func samplePTS(_ s: CMSampleBuffer) -> CMTime {
    CMSampleBufferGetPresentationTimeStamp(s)
}

// MARK: - H.264 硬编码器
final class H264Encoder {
    private var session: VTCompressionSession?
    private var configuredSize = CGSize.zero
    private let lock = NSLock()
    var onSample: ((CMSampleBuffer) -> Void)?

    /// 编码器是否可用（创建失败或被系统回收后会变 false，由引擎重试重建）
    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return session != nil
    }

    func configure(width: Int, height: Int, fps: Int, bitrate: Int) {
        lock.lock(); defer { lock.unlock() }
        let w = width % 2 == 0 ? width : width + 1
        let h = height % 2 == 0 ? height : height + 1
        if let s = session, configuredSize == CGSize(width: w, height: h) { return }
        if let old = session {
            session = nil
            VTCompressionSessionInvalidate(old)
        }
        var ns: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                               width: Int32(w), height: Int32(h),
                                               codecType: kCMVideoCodecType_H264,
                                               encoderSpecification: nil,
                                               imageBufferAttributes: nil,
                                               compressedDataAllocator: nil,
                                               outputCallback: { refcon, _, st, _, sb in
                                                   guard st == noErr, let s = sb, let r = refcon else { return }
                                                   Unmanaged<H264Encoder>.fromOpaque(r).takeUnretainedValue().onSample?(s)
                                               },
                                               refcon: Unmanaged.passUnretained(self).toOpaque(),
                                               compressionSessionOut: &ns)
        guard status == noErr, let s = ns else {
            Log.write("[编码] 创建失败 st=\(status) \(w)x\(h)")
            return
        }
        set(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(s, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(s, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(s, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        set(s, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        // 关键帧间隔：帧数 + 时间双保险，保证预录总能找到可解码的起点
        set(s, kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: max(fps, 15)))
        set(s, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 1.0))
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
        configuredSize = CGSize(width: w, height: h)
        Log.write("[编码] 就绪 \(w)x\(h) \(fps)fps")
    }

    private func set(_ s: VTCompressionSession, _ key: CFString, _ value: CFTypeRef?) {
        let st = VTSessionSetProperty(s, key: key, value: value)
        if st != noErr { Log.write("[编码] \(key) 设置失败 st=\(st)") }
    }

    func encode(_ pixelBuffer: CVPixelBuffer, at time: CMTime, forceKey: Bool) {
        lock.lock(); let s = session; lock.unlock()
        guard let session = s else { return }
        var props: [String: Any] = [:]
        if forceKey { props[kVTEncodeFrameOptionKey_ForceKeyFrame as String] = true }
        VTCompressionSessionEncodeFrame(session,
                                        imageBuffer: pixelBuffer,
                                        presentationTimeStamp: time,
                                        duration: .invalid,
                                        frameProperties: props.isEmpty ? nil : (props as CFDictionary),
                                        sourceFrameRefcon: nil,
                                        infoFlagsOut: nil)
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        if let s = session { session = nil; VTCompressionSessionInvalidate(s) }
        configuredSize = .zero
    }
}

// MARK: - 提示音（进程内合成，走扬声器，避免录音会话下听不到）
final class SoundPlayer {
    private let queue = DispatchQueue(label: "com.actioncam.sound")
    private var current: AVAudioPlayer?
    // 大疆式：短促三连"滴"
    private lazy var startTone = Self.makeTone([(0.00, 0.07), (0.12, 0.07), (0.24, 0.16)])
    private lazy var stopTone = Self.makeTone([(0.00, 0.20)])

    func playStart() { play(startTone) }
    func playStop() { play(stopTone) }

    private func play(_ data: Data) {
        queue.async { [weak self] in
            guard let self = self, let p = try? AVAudioPlayer(data: data) else { return }
            p.volume = 1.0
            p.prepareToPlay()
            p.play()
            self.current = p
        }
    }

    private static func makeTone(_ pattern: [(Double, Double)]) -> Data {
        let rate = 44100, freq = 880.0, amp = 28000.0
        let total = Int(0.7 * Double(rate))
        var pcm = [Int16](repeating: 0, count: total)
        for (offset, duration) in pattern {
            let start = Int(offset * Double(rate))
            let count = Int(duration * Double(rate))
            for i in 0..<count {
                let idx = start + i
                if idx >= total { break }
                let t = Double(i) / Double(rate)
                pcm[idx] = Int16(sin(2 * Double.pi * freq * t) * amp * exp(-t * 18.0))
            }
        }
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8))
        var size = UInt32(36 + total * 2); d.append(Data(bytes: &size, count: 4))
        d.append(contentsOf: Array("WAVEfmt ".utf8))
        var sub = UInt32(16); d.append(Data(bytes: &sub, count: 4))
        var fmt = UInt16(1); d.append(Data(bytes: &fmt, count: 2))
        var ch = UInt16(1); d.append(Data(bytes: &ch, count: 2))
        var r = UInt32(rate); d.append(Data(bytes: &r, count: 4))
        var br = UInt32(rate * 2); d.append(Data(bytes: &br, count: 4))
        var align = UInt16(2); d.append(Data(bytes: &align, count: 2))
        var bits = UInt16(16); d.append(Data(bytes: &bits, count: 2))
        d.append(contentsOf: Array("data".utf8))
        var dsz = UInt32(total * 2); d.append(Data(bytes: &dsz, count: 4))
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}

// MARK: - 影片写入器（预录历史帧 + 实时帧）
///
/// 关键点（上一版踩过的坑，这里全部规避）：
/// 1. expectsMediaDataInRealTime = false —— 预录帧是"历史数据"，
///    若设 true，AVAssetWriter 会按实时速度节流，135 帧要写 3 秒还丢帧。
/// 2. 所有 append 前先判 isReadyForMoreMediaData —— 未就绪时盲目 append 会阻塞/抛异常。
/// 3. 时间戳必须单调递增，音频必须不早于视频起点。
/// 4. 实时帧走"积压队列"，就绪就排空，一帧都不丢。
final class MovieWriter {
    private let queue = DispatchQueue(label: "com.actioncam.writer")
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var active = false

    private var videoWritten = 0
    private var audioWritten = 0
    private var lastVideoPTS = CMTime.invalid
    private var lastAudioPTS = CMTime.invalid

    private var videoBacklog: [CMSampleBuffer] = []
    private var audioBacklog: [CMSampleBuffer] = []
    private let maxBacklog = 240

    func start(video: [CMSampleBuffer], audio: [CMSampleBuffer],
               url: URL, transform: CGAffineTransform?, completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { DispatchQueue.main.async { completion(false) }; return }
            if self.active {
                Log.write("[写入] 丢弃未收尾的上一段")
                self.writer?.cancelWriting()
                self.resetLocked()
            }
            guard let first = video.first, let fmt = CMSampleBufferGetFormatDescription(first) else {
                Log.write("[写入] 没有可用的视频帧")
                DispatchQueue.main.async { completion(false) }; return
            }
            let startTime = samplePTS(first)
            do {
                if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
                let w = try AVAssetWriter(outputURL: url, fileType: .mp4)

                let v = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
                v.expectsMediaDataInRealTime = false
                if let t = transform { v.transform = t }
                guard w.canAdd(v) else {
                    Log.write("[写入] 视频轨添加失败")
                    DispatchQueue.main.async { completion(false) }; return
                }
                w.add(v)

                let validAudio = audio.filter { CMTimeCompare(samplePTS($0), startTime) >= 0 }
                let a = AVAssetWriterInput(mediaType: .audio,
                                           outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                            AVEncoderBitRateKey: 128000],
                                           sourceFormatHint: validAudio.first.flatMap { CMSampleBufferGetFormatDescription($0) })
                a.expectsMediaDataInRealTime = false
                let hasAudio = w.canAdd(a)
                if hasAudio { w.add(a) }

                guard w.startWriting() else {
                    Log.write("[写入] startWriting 失败 \(w.error?.localizedDescription ?? "")")
                    DispatchQueue.main.async { completion(false) }; return
                }
                w.startSession(atSourceTime: startTime)

                self.writer = w
                self.videoInput = v
                self.audioInput = hasAudio ? a : nil
                self.outputURL = url
                self.videoWritten = 0
                self.audioWritten = 0
                self.lastVideoPTS = startTime
                self.lastAudioPTS = .invalid
                self.videoBacklog.removeAll()
                self.audioBacklog.removeAll()
                self.active = true

                self.writeBulk(video: video, audio: validAudio)
                Log.write("[写入] 就绪 预录v=\(video.count) 写入v=\(self.videoWritten) 音频=\(hasAudio)")
                DispatchQueue.main.async { completion(true) }
            } catch {
                Log.write("[写入] 异常 \(error)")
                self.resetLocked()
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    /// 预录历史帧：按 PTS 交错写入，未就绪短暂等待，不静默丢帧
    private func writeBulk(video: [CMSampleBuffer], audio: [CMSampleBuffer]) {
        guard let v = videoInput else { return }
        var i = 0, j = 0
        let deadline = Date().addingTimeInterval(8)
        while (i < video.count || j < audio.count) && Date() < deadline {
            if let w = writer, w.status != .writing {
                Log.write("[写入] 预录写入中止 \(w.error?.localizedDescription ?? "")")
                break
            }
            let takeVideo: Bool
            if j >= audio.count { takeVideo = true }
            else if i >= video.count { takeVideo = false }
            else { takeVideo = CMTimeCompare(samplePTS(video[i]), samplePTS(audio[j])) <= 0 }

            if takeVideo {
                if v.isReadyForMoreMediaData {
                    if v.append(video[i]) { videoWritten += 1; lastVideoPTS = samplePTS(video[i]) }
                    i += 1
                } else {
                    Thread.sleep(forTimeInterval: 0.002)
                }
            } else if let a = audioInput {
                if a.isReadyForMoreMediaData {
                    if a.append(audio[j]) { audioWritten += 1; lastAudioPTS = samplePTS(audio[j]) }
                    j += 1
                } else {
                    Thread.sleep(forTimeInterval: 0.002)
                }
            } else {
                j += 1
            }
        }
    }

    func appendVideo(_ sample: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self = self, self.active,
                  let w = self.writer, w.status == .writing else { return }
            if self.videoBacklog.count > self.maxBacklog { self.videoBacklog.removeFirst() }
            self.videoBacklog.append(sample)
            self.drainVideo()
        }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self = self, self.active,
                  let w = self.writer, w.status == .writing else { return }
            if self.audioBacklog.count > self.maxBacklog { self.audioBacklog.removeFirst() }
            self.audioBacklog.append(sample)
            self.drainAudio()
        }
    }

    private func drainVideo() {
        guard let v = videoInput, let w = writer, w.status == .writing else { return }
        while !videoBacklog.isEmpty {
            guard v.isReadyForMoreMediaData else { return }
            let s = videoBacklog.removeFirst()
            let p = samplePTS(s)
            if lastVideoPTS.isValid && CMTimeCompare(p, lastVideoPTS) <= 0 { continue }
            lastVideoPTS = p
            if v.append(s) { videoWritten += 1 }
        }
    }

    private func drainAudio() {
        guard let a = audioInput, let w = writer, w.status == .writing else { return }
        while !audioBacklog.isEmpty {
            guard a.isReadyForMoreMediaData else { return }
            let s = audioBacklog.removeFirst()
            let p = samplePTS(s)
            if lastAudioPTS.isValid && CMTimeCompare(p, lastAudioPTS) <= 0 { continue }
            lastAudioPTS = p
            if a.append(s) { audioWritten += 1 }
        }
    }

    func finish(completion: @escaping (URL?) -> Void) {
        queue.async { [weak self] in
            guard let self = self, self.active, let w = self.writer else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            self.active = false
            let url = self.outputURL

            // 收尾前把积压写完
            let deadline = Date().addingTimeInterval(3)
            while (!self.videoBacklog.isEmpty || !self.audioBacklog.isEmpty)
                    && Date() < deadline && w.status == .writing {
                self.drainVideo(); self.drainAudio()
                if !self.videoBacklog.isEmpty || !self.audioBacklog.isEmpty {
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
            let vCount = self.videoWritten
            Log.write("[写入] 收尾 视频帧=\(vCount) 音频帧=\(self.audioWritten) 剩余积压=\(self.videoBacklog.count)")

            if vCount == 0 {
                Log.write("[写入] 无有效视频帧，取消")
                w.cancelWriting()
                self.resetLocked()
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            w.finishWriting {
                let ok = (w.status == .completed)
                Log.write("[写入] 完成 ok=\(ok) \(w.error?.localizedDescription ?? "")")
                DispatchQueue.main.async { completion(ok ? url : nil) }
            }
            self.resetLocked()
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.active { self.writer?.cancelWriting() }
            self.resetLocked()
        }
    }

    private func resetLocked() {
        writer = nil
        videoInput = nil
        audioInput = nil
        outputURL = nil
        active = false
        videoBacklog.removeAll()
        audioBacklog.removeAll()
        videoWritten = 0
        audioWritten = 0
        lastVideoPTS = .invalid
        lastAudioPTS = .invalid
    }
}
