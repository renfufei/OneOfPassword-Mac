//
//  RecordingPreferences.swift
//  OneOfPassword
//
//  录屏偏好：音频来源 / 帧率 / 鼠标指针 / 保存目录 / 上次录制区域。
//
//  === 为什么音频只做「三选一」，不做「系统声音 + 麦克风」混音 ===
//  系统声音（ScreenCaptureKit）和麦克风（AVCaptureSession）是两条**独立的采样流**：
//  时钟基准不同、缓冲节奏不同，要合成一条音轨就得在实时回调里做重采样 + 采样级求和，
//  一旦时序对不齐，表现就是「有画面没声音」或「越录越偏」，而这类问题几乎无法靠看代码发现。
//  另一种做法是塞两条音轨进 MP4 —— QuickTime / 手机相册往往只播第一条，用户会以为录坏了。
//  所以 v1 明确让用户选一种来源：可预期、可验证。默认「系统声音」，
//  因为录屏最常见的诉求是「把正在播放的视频/会议声音也录进去」。
//

import CoreGraphics
import Foundation

// MARK: - 音频来源

enum RecordingAudioSource: String, CaseIterable, Identifiable, Hashable {
    case none
    case system
    case microphone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:       return "不录音频"
        case .system:     return "系统声音"
        case .microphone: return "麦克风"
        }
    }

    var detail: String {
        switch self {
        case .none:       return "只录画面"
        case .system:     return "录制电脑正在播放的声音（视频、音乐、会议）"
        case .microphone: return "录制你的说话声（讲解、旁白）"
        }
    }

    var systemImage: String {
        switch self {
        case .none:       return "speaker.slash"
        case .system:     return "speaker.wave.2.fill"
        case .microphone: return "mic.fill"
        }
    }
}

// MARK: - 偏好

enum RecordingPreferences {

    private enum Keys {
        static let audioSource    = "recordingAudioSource"
        static let frameRate      = "recordingFrameRate"
        static let showsCursor    = "recordingShowsCursor"
        static let saveDirectory  = "recordingSaveDirectory"
        static let lastRegion     = "recordingLastRegion"
        static let rememberRegion = "recordingRememberLastRegion"
        static let useLastRegion  = "recordingUseLastRegion"
        static let showRegionMark = "recordingShowRegionMark"
        static let regionMarkOpacity = "recordingRegionMarkOpacity"
    }

    /// 可选的录制帧率。30 足够录教程/会议（文件小一半），60 适合录动画与滚动。
    static let frameRateOptions = [30, 60]

    static var audioSource: RecordingAudioSource {
        get {
            let raw = UserDefaults.standard.string(forKey: Keys.audioSource)
            return raw.flatMap(RecordingAudioSource.init(rawValue:)) ?? .system
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.audioSource) }
    }

    static var frameRate: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: Keys.frameRate)
            return frameRateOptions.contains(v) ? v : 30
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.frameRate) }
    }

    /// 是否把鼠标指针录进画面。默认开 —— 没有指针的教程录屏几乎不可看。
    static var showsCursor: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Keys.showsCursor) != nil else { return true }
            return UserDefaults.standard.bool(forKey: Keys.showsCursor)
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.showsCursor) }
    }

    /// 上次录制区域（**CG 全局坐标**，左上原点、点单位；nil = 整屏）。
    /// 与截屏的「上次选区」分开存：两个功能框的位置通常不一样，混用会让用户莫名其妙。
    static var lastRegion: CGRect? {
        get {
            guard let arr = UserDefaults.standard.array(forKey: Keys.lastRegion) as? [CGFloat],
                  arr.count == 4, arr[2] > 16, arr[3] > 16 else { return nil }
            return CGRect(x: arr[0], y: arr[1], width: arr[2], height: arr[3])
        }
        set {
            guard let r = newValue else {
                UserDefaults.standard.removeObject(forKey: Keys.lastRegion)
                return
            }
            UserDefaults.standard.set([r.origin.x, r.origin.y, r.width, r.height],
                                      forKey: Keys.lastRegion)
        }
    }

    // MARK: 录制区域

    /// 是否记住上次框选的区域。关掉时既不再保存，也会把已经存下的清掉。
    static var remembersLastRegion: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Keys.rememberRegion) != nil else { return true }
            return UserDefaults.standard.bool(forKey: Keys.rememberRegion)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.rememberRegion)
            if !newValue { lastRegion = nil }
        }
    }

    /// 打开选区面板时是否直接用上次的区域。关掉则每次都从空白开始框。
    static var usesLastRegion: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Keys.useLastRegion) != nil else { return true }
            return UserDefaults.standard.bool(forKey: Keys.useLastRegion)
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.useLastRegion) }
    }

    /// 录制中是否在屏幕上显示「录制区域标记框」。标记框是本应用的窗口，
    /// 已经被 `SCContentFilter` 排除，不会录进画面。
    static var showsRegionMark: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Keys.showRegionMark) != nil else { return true }
            return UserDefaults.standard.bool(forKey: Keys.showRegionMark)
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.showRegionMark) }
    }

    /// 标记框透明度（0.08 – 0.9）。默认 0.35：够看清边界，又不干扰画面。
    static var regionMarkOpacity: Double {
        get {
            let v = UserDefaults.standard.object(forKey: Keys.regionMarkOpacity) as? Double
            return (v.map { min(0.9, max(0.08, $0)) }) ?? 0.35
        }
        set { UserDefaults.standard.set(min(0.9, max(0.08, newValue)), forKey: Keys.regionMarkOpacity) }
    }

    // MARK: 保存位置
    //
    // 与截屏共用「上次保存的目录就记住」的习惯，但键分开：用户可能希望截图进「截图」文件夹、
    // 录屏进「影片」。没设置过时落到「影片」目录（macOS 对视频的默认去处），
    // 比桌面更符合预期；目录不存在时回落到桌面。

    static var saveDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: Keys.saveDirectory) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        if let movies, FileManager.default.fileExists(atPath: movies.path) { return movies }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// 记住保存目录。允许直接传文件 URL（录制结束时手上就是文件 URL），
    /// 内部按「是不是目录」自动折一层 —— 否则目录键里会存进一个文件路径，
    /// 下次 `makeOutputURL` 往文件路径上拼文件名，直接失败。
    static func rememberSaveDirectory(_ url: URL) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let directory = (exists && isDirectory.boolValue) ? url : url.deletingLastPathComponent()
        UserDefaults.standard.set(directory.path, forKey: Keys.saveDirectory)
    }

    /// 恢复默认（「影片」目录）。设置页的「恢复默认」用。
    static func resetSaveDirectory() {
        UserDefaults.standard.removeObject(forKey: Keys.saveDirectory)
    }

    // MARK: 输出文件

    /// 生成一个不重名的输出路径：`录屏 2026-11-23 11-21-05.mp4`
    ///
    /// 重名处理方式与系统截图一致（追加 `-2`），不弹保存框 —— 录完就结束，
    /// 不再打断用户一次（想换位置去设置里改，或录完在访达里拖走）。
    static func makeOutputURL() -> URL {
        let dir = saveDirectory
        let base = "录屏 \(timestamp())"
        var url = dir.appendingPathComponent("\(base).mp4")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(index).mp4")
            index += 1
        }
        return url
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f.string(from: Date())
    }
}
