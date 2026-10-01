import SwiftUI
import AVFoundation
import UIKit

// MARK: - 设计
private enum Palette {
    static let accent = Color(red: 0.25, green: 0.85, blue: 0.72)
    static let shutterRed = Color(red: 1.0, green: 0.23, blue: 0.23)
    static let warm = Color(red: 1.0, green: 0.78, blue: 0.35)
    static let glass = Color.black.opacity(0.38)
    static let stroke = Color.white.opacity(0.18)
    static func mono(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .monospaced) }
}

// MARK: - 预览
final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        update(view)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        update(view)
    }

    private func update(_ view: PreviewView) {
        guard let connection = view.previewLayer.connection else { return }
        if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }
}

// MARK: - 小控件
struct GlassChip: View {
    let text: String
    var color: Color = .white

    var body: some View {
        Text(text)
            .font(Palette.mono(11))
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Palette.glass)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Palette.stroke, lineWidth: 0.5))
    }
}

struct RoundIconButton: View {
    let systemName: String
    var active = false
    var activeColor: Color = Palette.accent
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundColor(active ? activeColor : .white)
                .frame(width: size, height: size)
                .background(Palette.glass)
                .clipShape(Circle())
                .overlay(Circle().stroke(active ? activeColor.opacity(0.7) : Palette.stroke, lineWidth: 1))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                for i in 1..<3 {
                    let x = geo.size.width * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geo.size.height))
                    let y = geo.size.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
        }
    }
}

struct LevelOverlay: View {
    @ObservedObject var motion: MotionManager

    var body: some View {
        ZStack {
            Circle()
                .stroke(motion.isLevel ? Palette.accent : Palette.warm, lineWidth: 1.5)
                .frame(width: 56, height: 56)
            Rectangle()
                .fill(motion.isLevel ? Palette.accent : Palette.warm)
                .frame(width: 36, height: 1)
                .offset(x: CGFloat(motion.roll * 100))
            Rectangle()
                .fill(motion.isLevel ? Palette.accent : Palette.warm)
                .frame(width: 1, height: 36)
                .offset(y: CGFloat(motion.pitch * 100))
            Circle()
                .fill(motion.isLevel ? Palette.accent : Palette.warm)
                .frame(width: 5, height: 5)
        }
        .opacity(0.85)
    }
}

// MARK: - 主界面
struct CameraScreen: View {
    @ObservedObject var engine: CameraEngine
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: engine.session,
                          mirrored: engine.lens == .front ? !engine.mirrorRear : engine.mirrorRear)
                .ignoresSafeArea()

            if engine.showGrid { GridOverlay().ignoresSafeArea() }

            VStack(spacing: 0) {
                topBar
                Spacer()
                if engine.showLevel {
                    LevelOverlay(motion: engine.motion).padding(.bottom, 16)
                }
                bottomBar
            }

            if let message = engine.statusMessage {
                VStack {
                    Spacer()
                    Text(message)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.72))
                        .clipShape(Capsule())
                        .padding(.bottom, 190)
                    Spacer()
                }
                .transition(.opacity)
            }

            if engine.debugInfo || engine.showLog {
                VStack {
                    Spacer()
                    Text(engine.logText.isEmpty ? "…" : engine.logText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(red: 0.55, green: 1.0, blue: 0.65))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(8)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 12)
                }
                .allowsHitTesting(false)
            }

            if engine.screenDimmed {
                Color.black.ignoresSafeArea()
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 20).onEnded { value in
                            if value.translation.height < -50,
                               abs(value.translation.height) > abs(value.translation.width) {
                                engine.wakeScreen()
                            }
                        }
                    )
                    .overlay(
                        VStack(spacing: 10) {
                            Image(systemName: "chevron.up.2")
                                .font(.system(size: 26))
                                .foregroundColor(.white.opacity(0.45))
                            Text("省电熄屏中 · 上滑唤醒")
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.45))
                            if engine.isRecording {
                                Text("正在录像 \(timeText(engine.recordSeconds))")
                                    .font(Palette.mono(12))
                                    .foregroundColor(Palette.shutterRed.opacity(0.8))
                            }
                        }
                    )
            }
        }
        .onAppear { engine.prepare() }
        .statusBar(hidden: true)
        .sheet(isPresented: $showSettings) { SettingsView(engine: engine) }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            RoundIconButton(systemName: engine.torchOn ? "bolt.fill" : "bolt.slash.fill",
                            active: engine.torchOn,
                            activeColor: Palette.warm,
                            size: 40) {
                engine.toggleTorch()
            }

            if engine.preRecordEnabled {
                HStack(spacing: 6) {
                    Circle().fill(Palette.accent).frame(width: 7, height: 7)
                    Text("预录中").font(Palette.mono(11)).foregroundColor(Palette.accent)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Palette.glass)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Palette.accent.opacity(0.6), lineWidth: 0.5))
            }

            Spacer()

            if engine.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(Palette.shutterRed).frame(width: 8, height: 8)
                    Text(timeText(engine.recordSeconds))
                        .font(Palette.mono(12)).foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Palette.glass)
                .clipShape(Capsule())
            }

            GlassChip(text: "\(Int(engine.batteryLevel * 100))%")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            lensRow

            HStack {
                RoundIconButton(systemName: "photo.on.rectangle", size: 46) {
                    engine.openPhotos()
                }
                Spacer()
                shutterButton
                Spacer()
                RoundIconButton(systemName: "slider.horizontal.3", size: 46) {
                    showSettings = true
                }
            }
            .padding(.horizontal, 30)

            Text(captionText)
                .font(Palette.mono(11))
                .foregroundColor(.white.opacity(0.55))
                .padding(.bottom, 18)
        }
    }

    private var lensRow: some View {
        HStack(spacing: 6) {
            ForEach(CameraLens.allCases) { item in
                Button {
                    engine.lens = item
                } label: {
                    Text(item.short + (item == .front ? "" : "x"))
                        .font(Palette.mono(12))
                        .foregroundColor(engine.lens == item ? .black : .white)
                        .frame(width: item == .front ? 46 : 34, height: 30)
                        .background(engine.lens == item ? Color.white : Palette.glass)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Palette.stroke, lineWidth: 0.5))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(engine.isRecording)
                .opacity(engine.isRecording ? 0.4 : 1)
            }
        }
    }

    private var shutterButton: some View {
        Button {
            if engine.isRecording {
                engine.stopRecording()
            } else {
                engine.startRecording()
            }
        } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 76, height: 76)
                if engine.isRecording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Palette.shutterRed)
                        .frame(width: 32, height: 32)
                } else {
                    Circle().fill(Palette.shutterRed).frame(width: 62, height: 62)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var captionText: String {
        var parts = ["\(engine.resolution.rawValue)", "\(engine.frameRate.rawValue)fps"]
        if engine.preRecordEnabled { parts.append("预录\(engine.preRecordDuration.label)") }
        if engine.voiceEnabled && !engine.voiceListening { parts.append("语音未就绪") }
        return parts.joined(separator: " · ")
    }

    private func timeText(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - 设置
struct SettingsView: View {
    @ObservedObject var engine: CameraEngine
    @Environment(\.presentationMode) private var presentation
    @State private var startInput = ""
    @State private var stopInput = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("预录"),
                        footer: Text("开启后会持续缓存最近画面，按下录像时把「按下之前」的画面一起保存。")) {
                    Toggle("开启预录", isOn: $engine.preRecordEnabled)
                    Picker("预录时长", selection: $engine.preRecordDuration) {
                        ForEach(PreRecordDuration.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(!engine.preRecordEnabled)
                }

                Section(header: Text("语音控制"),
                        footer: Text("开启后对着手机说「开启录像」即可开始录制。")) {
                    Toggle("语音控制", isOn: $engine.voiceEnabled)
                    HStack {
                        Text("开始口令")
                        Spacer()
                        Text(engine.startWords.joined(separator: " / "))
                            .foregroundColor(.secondary).lineLimit(1)
                    }
                    TextField("自定义开始口令（英文逗号分隔）", text: $startInput)
                    HStack {
                        Text("结束口令")
                        Spacer()
                        Text(engine.stopWords.joined(separator: " / "))
                            .foregroundColor(.secondary).lineLimit(1)
                    }
                    TextField("自定义结束口令（英文逗号分隔）", text: $stopInput)
                    Button("保存口令") {
                        engine.startWords = startInput.isEmpty
                            ? engine.startWords
                            : startInput.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        engine.stopWords = stopInput.isEmpty
                            ? engine.stopWords
                            : stopInput.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        engine.applyVoiceWords()
                    }
                }

                Section(header: Text("省电"),
                        footer: Text("熄屏后仍会继续录像，在屏幕上向上滑动即可唤醒。")) {
                    Picker("自动熄屏", selection: $engine.screenOffOption) {
                        ForEach(ScreenOffOption.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section(header: Text("画面"), footer: engine.isRecording ? Text("录制中，画面参数暂不可调整") : Text("")) {
                    Picker("镜头", selection: $engine.lens) {
                        ForEach(CameraLens.allCases) { Text($0.rawValue).tag($0) }
                    }.disabled(engine.isRecording)
                    Picker("分辨率", selection: $engine.resolution) {
                        ForEach(VideoResolution.allCases) { Text($0.rawValue).tag($0) }
                    }.disabled(engine.isRecording)
                    Picker("帧率", selection: $engine.frameRate) {
                        ForEach(FrameRateOption.allCases) { Text($0.label).tag($0) }
                    }.disabled(engine.isRecording)
                    Picker("防抖", selection: $engine.stabilization) {
                        ForEach(StabilizationLevel.allCases) { Text($0.rawValue).tag($0) }
                    }.disabled(engine.isRecording)
                    Toggle("水平镜像", isOn: $engine.mirrorRear).disabled(engine.isRecording)
                }

                Section(header: Text("拍摄辅助")) {
                    Toggle("构图网格", isOn: $engine.showGrid)
                    Toggle("水平仪", isOn: $engine.showLevel)
                    Toggle("录制提示音", isOn: $engine.beepEnabled)
                }

                Section(header: Text("其它")) {
                    Toggle("显示调试信息", isOn: $engine.debugInfo)
                }
            }
            .navigationBarTitle("设置", displayMode: .inline)
            .navigationBarItems(trailing: Button("完成") { presentation.wrappedValue.dismiss() })
        }
        .onAppear {
            startInput = engine.startWords.joined(separator: ",")
            stopInput = engine.stopWords.joined(separator: ",")
        }
    }
}
