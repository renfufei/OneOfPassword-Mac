//
//  ScreenRecorder.swift
//  OneOfPassword
//
//  录制内核：ScreenCaptureKit 取流 → AVAssetWriter 编码落盘 MP4（H.264 + AAC）。
//
//  === 为什么不用 macOS 15 的 SCRecordingOutput ===
//  部署目标是 macOS 13.0，而 `SCRecordingOutput` 是 15.0 才有的 API。走
//  `SCStream + AVAssetWriter` 这条路 13 → 26 全都能跑、行为一致（Apple 官方录屏示例在
//  SCRecordingOutput 出现之前就是这个组合）。唯一的代价是要自己处理
//  「首帧 PTS 作为会话起点」的换算，见 `appendVideo`。
//
//  === 为什么先「排除本应用」再录 ===
//  录制中要显示悬浮控制条（停止/丢弃）。如果不过滤，控制条会被录进画面里。
//  `SCContentFilter(display:excludingApplications:exceptingWindows:)` 把本应用整体排除，
//  于是控制条天然不进画面；代价是「本应用窗口所在位置」会露出桌面背景，
//  所以开始录制前要先把主窗口藏起来（`RecordingCoordinator.hideAppWindows`）。
//
//  === 帧率怎么设（两个时代的 API 并存，只能在运行时挑一个）===
//  老系统（13–15）的帧率是 `minimumFrameRate` / `maximumFrameRate`（Double），
//  当前 macOS 26/27 SDK 里这两个已经**移除**，只剩 `minimumFrameInterval`（CMTime）；
//  反过来 26/27 上调 `maximumFrameRate` 会 unrecognized selector 崩。
//  所以：编译期只引用 SDK 里有的那个，运行期先用 `responds(to:)` 探明到底支持哪个。
//  实测（macOS 27.2）：setMinimumFrameInterval 存在，两个 FrameRate setter 都不存在。
//
//  也**不要**用「按间隔丢帧」在软件层凑帧率：源流是 ~38fps 时，逐帧判断只能在
//  「全收(38)」和「隔一个收(19)」之间跳，永远拿不到 30 —— 实测过，别回头。
//
//  === 线程模型 ===
//  视频帧、系统音频、麦克风音频分别来自三条回调队列，但**全部**汇到 `processingQueue`
//  这一条串行队列上写盘：
//  · `AVAssetWriterInput` 不是线程安全的，多队列并发 append 会随机丢帧甚至崩溃；
//  · 串行化之后「会话起点 / 是否已 startSession」这类状态不需要加锁；
//  · 30fps + 两路音频的写入量对一条串行队列毫无压力（每帧只是把 IOSurface 交给编码器）。
//

@preconcurrency import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit

// MARK: - 错误

enum ScreenRecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case noPermission
    case noMicrophonePermission
    case noDisplay
    case regionTooSmall
    case setupFailed(String)
    case encodingFailed(String)
    case nothingRecorded

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:       return "已经在录制中"
        case .notRecording:           return "当前没有进行中的录制"
        case .noPermission:           return "没有「屏幕录制」权限，请到「设置 → 系统权限」中开启并重新启动本应用"
        case .noMicrophonePermission: return "没有「麦克风」权限，请到「设置 → 系统权限」中开启"
        case .noDisplay:              return "找不到可录制的屏幕"
        case .regionTooSmall:         return "录制区域太小"
        case .setupFailed(let m):     return "录制初始化失败：\(m)"
        case .encodingFailed(let m):  return "编码失败：\(m)"
        case .nothingRecorded:        return "没有录到任何画面"
        }
    }
}

// MARK: - 参数

struct RecordingOptions {
    /// 要录制的屏幕
    var displayID: CGDirectDisplayID
    /// 录制区域（CG 全局坐标，左上原点、点单位）。nil = 整块屏幕
    var region: CGRect?
    var audio: RecordingAudioSource
    var frameRate: Int
    var showsCursor: Bool
    var outputURL: URL
}

// MARK: - 录制器

final class ScreenRecorder: NSObject, ObservableObject {

    static let shared = ScreenRecorder()

    /// 是否正在录制。HUD / 计时都以此为准。
    @Published private(set) var isRecording = false
    /// 录制开始时刻（HUD 计时起点）
    @Published private(set) var startedAt: Date?
    /// 输出尺寸（像素），HUD 上标注「1280×720」用
    @Published private(set) var pixelSize: CGSize = .zero
    /// 是否暂停中（HUD 换按钮图标 + 冻结计时）
    @Published private(set) var isPaused = false
    /// 累计暂停时长（秒）。HUD 的计时 = 现在 - 开始时刻 - 这个值。
    @Published private(set) var pausedTotal: TimeInterval = 0

    private let processingQueue = DispatchQueue(label: "com.oneofpassword.recorder.processing")

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var systemAudioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var micSession: AVCaptureSession?
    private var outputURL: URL?

    /// 写入会话起点 = 首帧视频的时间戳。视频/音频都必须 >= 这个时间才能 append。
    private var sessionStartTime: CMTime = .invalid
    private var hasStartedSession = false
    /// 收尾中：此后到达的样本一律丢弃，避免向已 markAsFinished 的 input 写数据
    private var finishing = false

    /// 目标帧间隔（仅诊断用：日志里能看到实际送达帧率）
    private var targetFrameRate: Int = 30

    // 诊断计数（写日志用）
    private var videoFrameCount = 0
    private var droppedFrameCount = 0
    /// 麦克风时间戳与系统时钟的偏移，只在首次采样时测定一次
    private var micTimeOffset: CMTime?

    // === 暂停 ===
    //  暂停的语义是「时间轴原地停住」，不是「留一段黑屏/静止」：
    //  暂停期间到达的样本全部丢弃，恢复时把这段时长记进 `pausedAccum`，
    //  之后所有样本的时间戳统一减去它 —— 于是影片里根本没有这段空白。
    //  `pausedAccum` 只在这条串行队列上读写（样本回调也在这条队列）；
    //  `isPaused` / `pausedTotal` 是给 UI 的，只在主线程改。
    private var pausedFlag = false
    private var pausedAccum: CMTime = .zero
    /// 暂停起点的宿主时钟（与 SCStream 的 PTS 同基准），恢复时用它算暂停时长
    private var pauseAnchor: CMTime = .invalid
    /// 暂停起点的墙钟，用来更新 pausedTotal
    private var pauseStartedDate: Date?

    // 已写入的最后一个 PTS（视频/音频各一）。暂停恢复的边界上，扣完暂停时长后
    // 有可能比上一帧早几毫秒 —— `AVAssetWriterInput.append` 遇到时间戳倒退会拒收，
    // 并把整个 writer 置为 failed（表现为「整段录了但只有几帧」），所以必须自己兜住。
    private var lastVideoPTS: CMTime = .invalid
    private var lastAudioPTS: CMTime = .invalid

    private override init() { super.init() }

    // MARK: - 公开接口

    /// 开始录制。返回即表示流已启动（首帧稍后才到）。
    func start(options: RecordingOptions) async throws {
        guard !isRecording else { throw ScreenRecorderError.alreadyRecording }
        guard AppPermission.screenRecording.status.isAuthorized else {
            throw ScreenRecorderError.noPermission
        }
        if options.audio == .microphone,
           AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            throw ScreenRecorderError.noMicrophonePermission
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            // 首次运行 / 刚被撤权时，这里会以 SCStreamError.userDeclined 失败
            ScreenshotLogger.log("recorder start: SCShareableContent failed \(error)")
            throw ScreenRecorderError.noPermission
        }
        guard let display = content.displays.first(where: { $0.displayID == options.displayID })
                ?? content.displays.first else {
            throw ScreenRecorderError.noDisplay
        }

        // 录制几何：先把「全局 CG 坐标的选区」换算成「该屏幕内的点坐标」，再换算成像素。
        let displayFrame = display.frame
        var captureRect = CGRect(origin: .zero, size: displayFrame.size)
        if let region = options.region {
            let local = CGRect(x: region.minX - displayFrame.minX,
                               y: region.minY - displayFrame.minY,
                               width: region.width, height: region.height)
            captureRect = local.intersection(CGRect(origin: .zero, size: displayFrame.size))
        }
        let scale = Self.backingScale(for: display.displayID)
        // H.264 要求宽高为偶数，奇数会让编码器直接报错
        let width = Self.evenPixels(captureRect.width * scale)
        let height = Self.evenPixels(captureRect.height * scale)
        guard width >= 16, height >= 16 else { throw ScreenRecorderError.regionTooSmall }

        let url = options.outputURL
        try? FileManager.default.removeItem(at: url)   // AVAssetWriter 拒绝已存在的文件

        let (writer, videoInput, adaptor, audioInput) = try Self.makeWriter(
            url: url, width: width, height: height, frameRate: options.frameRate,
            withAudio: options.audio != .none
        )

        // 流配置
        let config = SCStreamConfiguration()
        config.sourceRect = captureRect
        config.width = width
        config.height = height
        config.showsCursor = options.showsCursor
        // 帧率上限：SDK 只声明了 `minimumFrameInterval`（13–15 的系统上没有这个选择器），
        // 老系统改用 KVC 设已从 SDK 移除的 `maximumFrameRate`。两条路都在运行时探测。
        Self.applyFrameRate(options.frameRate, to: config)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 6
        if options.audio == .system {
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            // 不录本应用自己发出的声音（提示音等），否则会串进录制里
            config.excludesCurrentProcessAudio = true
        }

        let ownApps = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display,
                                     excludingApplications: ownApps,
                                     exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)

        // 先装配好 writer 再开流：第一帧到达时 writer 必须已经可写，
        // 否则 `startSession` 之前到的样本全会被丢掉（开头缺一段）。
        guard writer.startWriting() else {
            throw ScreenRecorderError.setupFailed(writer.error?.localizedDescription ?? "未知原因")
        }

        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: processingQueue)
        if options.audio == .system {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: processingQueue)
        }

        // 麦克风走 AVCapture：ScreenCaptureKit 的麦克风采集是 macOS 15 才有的（还是单独的
        // 输出类型），用 AVCaptureSession 一条路就能覆盖 13 → 26。
        if options.audio == .microphone {
            micInput = audioInput
            do {
                try await startMicrophone()
            } catch {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                micInput = nil
                throw error
            }
        } else {
            systemAudioInput = audioInput
        }

        self.stream = stream
        self.writer = writer
        self.videoInput = videoInput
        self.videoAdaptor = adaptor
        self.outputURL = url
        self.sessionStartTime = .invalid
        self.hasStartedSession = false
        self.finishing = false
        self.micTimeOffset = nil
        self.targetFrameRate = options.frameRate
        self.videoFrameCount = 0
        self.droppedFrameCount = 0
        self.pausedFlag = false
        self.pausedAccum = .zero
        self.pauseAnchor = .invalid
        self.pauseStartedDate = nil
        self.lastVideoPTS = .invalid
        self.lastAudioPTS = .invalid
        self.pixelSize = CGSize(width: width, height: height)
        await MainActor.run {
            self.isPaused = false
            self.pausedTotal = 0
        }

        do {
            try await stream.startCapture()
        } catch {
            await stopMicrophone()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            self.stream = nil
            self.writer = nil
            self.micInput = nil
            self.systemAudioInput = nil
            ScreenshotLogger.log("recorder start: startCapture failed \(error)")
            throw ScreenRecorderError.setupFailed(error.localizedDescription)
        }

        ScreenshotLogger.log("recorder started \(width)x\(height) audio=\(options.audio.rawValue) fps=\(options.frameRate) url=\(url.path)")
        let now = Date()
        await MainActor.run {
            self.isRecording = true
            self.startedAt = now
        }
    }

    /// 结束录制并把结果落盘。成功返回文件 URL。
    func stop() async -> Result<URL, Error> {
        guard isRecording, let writer, let url = outputURL else {
            return .failure(ScreenRecorderError.notRecording)
        }
        finishing = true
        await MainActor.run { self.isRecording = false }

        // 顺序很重要：先停流 → ScreenCaptureKit 不再回调新样本 → 再 markAsFinished → finishWriting
        if let stream {
            do { try await stream.stopCapture() } catch {
                ScreenshotLogger.log("recorder stop: stopCapture error \(error)")
            }
        }
        stream = nil
        await stopMicrophone()

        let frames = videoFrameCount
        let dropped = droppedFrameCount
        ScreenshotLogger.log("recorder stopping: frames=\(frames) dropped=\(dropped) hasSession=\(hasStartedSession)")

        guard hasStartedSession else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            reset()
            return .failure(ScreenRecorderError.nothingRecorded)
        }

        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        micInput?.markAsFinished()

        let status: AVAssetWriter.Status = await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume(returning: writer.status) }
        }
        let errorMessage = writer.error?.localizedDescription
        reset()

        if status == .completed,
           let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let bytes = attributes[.size] as? Int, bytes > 0 {
            ScreenshotLogger.log("recorder finished ok bytes=\(bytes) url=\(url.path)")
            RecordingPreferences.rememberSaveDirectory(url)
            return .success(url)
        }

        try? FileManager.default.removeItem(at: url)
        let message = errorMessage ?? "写入器状态 \(status.rawValue)"
        ScreenshotLogger.log("recorder finished FAILED status=\(status.rawValue) error=\(message)")
        return .failure(ScreenRecorderError.encodingFailed(message))
    }

    // MARK: - 暂停 / 恢复

    /// 暂停录制。返回即生效：之后的帧与音频都不写盘，时间轴原地停住。
    func pause() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        pauseStartedDate = Date()
        pauseAnchor = CMClockGetTime(CMClockGetHostTimeClock())
        processingQueue.async {
            guard !self.finishing else { return }
            self.pausedFlag = true
        }
        ScreenshotLogger.log("recorder paused")
    }

    /// 恢复录制。把暂停时长从时间轴里扣掉（视频与音频同一套偏移，音画不会错位）。
    func resume() {
        guard isRecording, isPaused else { return }
        let wall = max(0, Date().timeIntervalSince(pauseStartedDate ?? Date()))
        isPaused = false
        pausedTotal += wall
        pauseStartedDate = nil
        // 暂停时长用「宿主时钟差值」而不是墙钟：样本 PTS 就是这个时钟，
        // 两边同一基准算差值，误差只有一个帧间隔，比墙钟更贴合真实时间轴。
        let anchor = pauseAnchor
        pauseAnchor = .invalid
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        processingQueue.async {
            guard self.pausedFlag else { return }
            if anchor.isValid {
                let delta = CMTimeSubtract(now, anchor)
                if delta.isValid, delta.seconds.isFinite, delta.seconds > 0 {
                    self.pausedAccum = CMTimeAdd(self.pausedAccum, delta)
                }
            }
            self.pausedFlag = false
        }
        ScreenshotLogger.log("recorder resumed, pausedTotal=\(String(format: "%.2f", pausedTotal))s")
    }

    /// 已录制时长（不含暂停），HUD 计时用。与文件里的实际时长同口径。
    func elapsedSeconds(at date: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, date.timeIntervalSince(startedAt) - pausedTotal)
    }

    /// 丢弃当前录制（停止并删除文件）
    func cancel() async {
        guard isRecording else { return }
        finishing = true
        await MainActor.run { self.isRecording = false }
        if let stream { try? await stream.stopCapture() }
        stream = nil
        await stopMicrophone()
        writer?.cancelWriting()
        if let url = outputURL { try? FileManager.default.removeItem(at: url) }
        ScreenshotLogger.log("recorder cancelled")
        reset()
    }

    /// HUD / 结果面板显示的实际时长（读文件最准；读不到返回 0）。
    /// 用 `load(.duration)` 而不是已废弃的 `asset.duration` —— 后者在 macOS 13 起就被标记废弃。
    static func duration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let value = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(value)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    private func reset() {
        writer = nil
        videoInput = nil
        videoAdaptor = nil
        systemAudioInput = nil
        micInput = nil
        outputURL = nil
        sessionStartTime = .invalid
        hasStartedSession = false
        finishing = false
        pausedFlag = false
        pausedAccum = .zero
        pauseAnchor = .invalid
        pauseStartedDate = nil
        lastVideoPTS = .invalid
        lastAudioPTS = .invalid
        DispatchQueue.main.async {
            self.startedAt = nil
            self.isPaused = false
            self.pausedTotal = 0
        }
    }

    // MARK: - 写入器

    private static func makeWriter(url: URL, width: Int, height: Int, frameRate: Int, withAudio: Bool)
        throws -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor, AVAssetWriterInput?) {

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw ScreenRecorderError.setupFailed(error.localizedDescription)
        }

        // 码率随分辨率与帧率走：大约「像素数 × 帧率 × 0.1」，夹在 3–24 Mbps。
        // 1080p30 ≈ 6.2 Mbps（文字清晰、体积可控），4K60 到顶 24 Mbps。
        let pixels = Double(width * height)
        let bitRate = Int(min(24_000_000, max(3_000_000, pixels * Double(frameRate) * 0.10)))

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                // High profile + 自动 level：文字锐利，又不用自己算 level 上限
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                // 关键帧间隔 2 秒：拖进度条手感好，体积也不会失控
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                AVVideoAllowFrameReorderingKey: true
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: attributes
        )
        guard writer.canAdd(videoInput) else {
            throw ScreenRecorderError.setupFailed("无法添加视频轨道（\(width)×\(height) 可能超出编码器能力）")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if withAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                ScreenshotLogger.log("recorder: 无法添加音频轨道，降级为无声录制")
            }
        }
        return (writer, videoInput, adaptor, audioInput)
    }

    // MARK: - 样本写入

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard !finishing, writer?.status == .writing else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }
        // 暂停期间到达的帧：不写、也不推进时间轴（恢复后由 pausedAccum 把时间轴接上）
        if pausedFlag { return }
        var mediaPTS = adjustedPTS(pts)
        // 时间戳倒退 = 恢复瞬间扣多了几毫秒。补最小步进（1/600 秒）而不是丢弃这一帧：
        // 画面不能缺，且只影响一帧的时长。
        if lastVideoPTS.isValid, CMTimeCompare(mediaPTS, lastVideoPTS) <= 0 {
            mediaPTS = CMTimeAdd(lastVideoPTS, CMTime(value: 1, timescale: 600))
        }

        // 首帧决定整段时间轴的零点。不用 `.zero` 当会话起点：SCStream 的 PTS 来自
        // 系统时钟（开机以来的秒数），从 0 起算会让影片开头空出十几个小时。
        if !hasStartedSession {
            hasStartedSession = true
            sessionStartTime = mediaPTS
            writer?.startSession(atSourceTime: mediaPTS)
        }

        guard let adaptor = videoAdaptor, adaptor.assetWriterInput.isReadyForMoreMediaData else {
            droppedFrameCount += 1
            return
        }
        // 不筛掉「内容未变化的 idle 帧」：SCStream 在画面静止时也会送帧，
        // 丢光会让静止段的影片时长变短（播放器只播到最后一个真实帧）。
        // H.264 对完全相同的帧只写几个 skip 宏块，体积代价可以忽略。
        if adaptor.append(imageBuffer, withPresentationTime: mediaPTS) {
            videoFrameCount += 1
            lastVideoPTS = mediaPTS
        } else {
            droppedFrameCount += 1
            if let error = writer?.error {
                ScreenshotLogger.log("recorder appendVideo failed: \(error)")
            }
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard !finishing, !pausedFlag, hasStartedSession, writer?.status == .writing, let input else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let pts = adjustedPTS(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        // 会话起点之前的样本 writer 一律拒收（首帧之前的几十毫秒音频），直接丢
        guard CMTimeCompare(pts, sessionStartTime) >= 0 else { return }
        guard input.isReadyForMoreMediaData else { return }

        // 暂停过就整轨跟着平移：否则恢复后的声音会比画面早到「暂停时长」那么多（音画不同步）。
        // 麦克风那条路已经先按 micTimeOffset 平移过一次，两次偏移叠加是对的。
        var buffer = sampleBuffer
        var finalPTS = pts
        if pausedAccum != .zero {
            guard let shifted = Self.retimed(sampleBuffer, by: pausedAccum) else { return }
            buffer = shifted
            finalPTS = CMSampleBufferGetPresentationTimeStamp(shifted)
        }
        // 恢复边界上音频包可能和暂停前最后一个包重叠几毫秒。这里丢这一个包（听不出来），
        // 让时间戳保持严格递增 —— 倒退会让 writer 直接 failed。
        if lastAudioPTS.isValid, CMTimeCompare(finalPTS, lastAudioPTS) <= 0 { return }
        if !input.append(buffer), let error = writer?.error {
            ScreenshotLogger.log("recorder appendAudio failed: \(error)")
        } else {
            lastAudioPTS = finalPTS
        }
    }

    /// 把 PTS 换算到「扣除暂停」的时间轴上。暂停期间的样本已被丢弃，所以这里只需常量平移。
    private func adjustedPTS(_ pts: CMTime) -> CMTime {
        pausedAccum == .zero ? pts : CMTimeSubtract(pts, pausedAccum)
    }

    private func appendMic(_ sampleBuffer: CMSampleBuffer) {
        guard !finishing, hasStartedSession, writer?.status == .writing, let input = micInput else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        // 麦克风时间戳来自 AVCaptureSession 的时钟，通常与 SCStream 同为 host clock；
        // 万一两者基准不同，整轨音频会被「早于会话起点」的判断丢光 —— 表现就是
        // 「录了但一点声音都没有」。首个样本测一次偏差，超过 5 秒就认定基准不同，
        // 整轨平移过去（常量偏移即可，不需要逐帧校正）。
        let raw = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if micTimeOffset == nil {
            let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
            let delta = CMTimeSubtract(raw, hostNow)
            let seconds = CMTimeGetSeconds(delta)
            let offset: CMTime = (seconds.isFinite && abs(seconds) > 5) ? delta : .zero
            micTimeOffset = offset
            ScreenshotLogger.log("recorder mic clock offset=\(CMTimeGetSeconds(offset))s")
        }

        var buffer = sampleBuffer
        if let offset = micTimeOffset, offset != .zero,
           let shifted = Self.retimed(sampleBuffer, by: offset) {
            buffer = shifted
        }

        appendAudio(buffer, to: input)
    }

    /// 把样本的时间戳整体平移 -offset（保留原 duration：音频是多采样合一包，必须带上）
    private static func retimed(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var duration = CMSampleBufferGetDuration(sampleBuffer)
        if !duration.isValid || duration.seconds <= 0 {
            let frames = CMSampleBufferGetNumSamples(sampleBuffer)
            duration = CMTime(value: CMTimeValue(max(frames, 1)), timescale: 48_000)
        }
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), offset),
            decodeTimeStamp: .invalid
        )
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &out
        )
        return status == noErr ? out : nil
    }

    // MARK: - 麦克风

    private func startMicrophone() async throws {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw ScreenRecorderError.setupFailed("没有找到可用的麦克风")
        }
        let session = AVCaptureSession()
        session.beginConfiguration()

        let deviceInput: AVCaptureDeviceInput
        do {
            deviceInput = try AVCaptureDeviceInput(device: device)
        } catch {
            session.commitConfiguration()
            throw ScreenRecorderError.setupFailed("麦克风被占用或不可用：\(error.localizedDescription)")
        }
        guard session.canAddInput(deviceInput) else {
            session.commitConfiguration()
            throw ScreenRecorderError.setupFailed("无法使用麦克风输入")
        }
        session.addInput(deviceInput)

        let output = AVCaptureAudioDataOutput()
        // 显式要求 48kHz 双声道 LPCM：与系统声音同格式，编码器不用二次猜测；
        // 也避免某些设备给 44.1kHz 单声道导致 AAC 输入被拒。
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        output.setSampleBufferDelegate(self, queue: processingQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw ScreenRecorderError.setupFailed("无法使用麦克风输出")
        }
        session.addOutput(output)
        session.commitConfiguration()

        // startRunning 是同步阻塞调用（可能几百毫秒），放后台避免卡住主线程
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
                if session.isRunning {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ScreenRecorderError.setupFailed("麦克风启动失败"))
                }
            }
        }
        micSession = session
        ScreenshotLogger.log("recorder microphone started: \(device.localizedName)")
    }

    private func stopMicrophone() async {
        guard let session = micSession else { return }
        micSession = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                session.stopRunning()
                continuation.resume()
            }
        }
        ScreenshotLogger.log("recorder microphone stopped")
    }

    // MARK: - 工具

    /// 给流配置设帧率上限。两个时代的 API 只可能在运行时存在一个（见文件头注释），
    /// 探测后各走各的路；都不支持就保持系统默认（≤60fps），不报错。
    static func applyFrameRate(_ fps: Int, to config: SCStreamConfiguration) {
        let clamped = max(1, min(120, fps))
        if config.responds(to: Selector(("setMinimumFrameInterval:"))) {
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(clamped))
        } else if config.responds(to: Selector(("setMaximumFrameRate:"))) {
            // 老系统：属性已从当前 SDK 移除，只能 KVC 设。
            // 只设 maximum —— 设 minimum 会强制静止画面也按该速率送帧。
            config.setValue(Double(clamped), forKey: "maximumFrameRate")
        } else {
            ScreenshotLogger.log("recorder: 系统不支持设置帧率上限，按默认帧率录制")
        }
    }

    static func backingScale(for displayID: CGDirectDisplayID) -> CGFloat {
        for screen in NSScreen.screens {
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            if id == displayID { return screen.backingScaleFactor }
        }
        return NSScreen.main?.backingScaleFactor ?? 2
    }

    /// 取最近的偶数（向上），且不小于 2
    static func evenPixels(_ value: CGFloat) -> Int {
        let rounded = Int(value.rounded())
        let even = rounded % 2 == 0 ? rounded : rounded + 1
        return max(2, even)
    }
}

// MARK: - ScreenCaptureKit 回调

extension ScreenRecorder: SCStreamOutput {
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        switch type {
        case .screen: appendVideo(sampleBuffer)
        case .audio:  appendAudio(sampleBuffer, to: systemAudioInput)
        // .microphone（macOS 15+）不走这条路：麦克风统一由 AVCaptureSession 提供
        default:      break
        }
    }
}

// MARK: - AVCapture 回调（麦克风）

extension ScreenRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        appendMic(sampleBuffer)
    }
}
