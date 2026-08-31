//
//  ScreenshotLogger.swift
//  OneOfPassword
//
//  截屏功能内部日志，写入 ~/Library/Logs/OneOfPassword-screenshot.log
//  便于排查全局快捷键 / CGEventTap / 覆盖层问题。
//

import Foundation

enum ScreenshotLogger {
    private static let logURL: URL = {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/OneOfPassword-screenshot.log")
    }()

    static func log(_ message: String, file: String = #fileID, line: Int = #line) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(ts)] \(message)\n"
        let fm = FileManager.default
        let dir = logURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // 追加写
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            if let data = entry.data(using: .utf8) { handle.write(data) }
            try? handle.close()
        } else {
            try? entry.data(using: .utf8)?.write(to: logURL, options: .atomic)
        }
        // 同时打到 stderr，方便从终端 / Console.app 看
        FileHandle.standardError.write(entry.data(using: .utf8) ?? Data())
    }
}
