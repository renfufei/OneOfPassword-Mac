//
//  AppVersion.swift
//  OneOfPassword
//
//  「当前运行的这个 build 是谁」的唯一真相。
//
//  设置 → 关于 里展示、以及「复制版本信息」按钮都从这里取，不要在视图里各自读 Bundle：
//  版本号分散读取最容易出现的 bug 是「一处显示 1.78、另一处显示 78」。
//

import AppKit

enum AppVersion {

    /// `CFBundleShortVersionString`，例如 `1.78`
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// `CFBundleVersion`（构建号），例如 `78`
    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    /// 展示用：「1.78（构建 78）」
    static var display: String {
        "\(shortVersion)（构建 \(buildNumber)）"
    }

    /// 系统版本，例如 `macOS 14.6.1`。
    /// 用 `operatingSystemVersion` 而不是 `ProcessInfo.operatingSystemVersionString`：
    /// 后者带 `Version 14.6.1 (Build 23G93)` 这类冗余后缀，中文界面里也保持一致。
    static var systemDescription: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var text = "macOS \(v.majorVersion).\(v.minorVersion)"
        if v.patchVersion > 0 { text += ".\(v.patchVersion)" }
        return text
    }

    /// 芯片与架构。用**编译期**架构判断：Universal 包里 Intel 机器跑的就是 x86_64 那一份，
    /// 所以「实际运行的架构」等于「当时编译的分支」，不会把 Intel 报成 Apple 芯片。
    static var architectureDescription: String {
        #if arch(arm64)
        return "Apple 芯片（arm64）"
        #else
        return "Intel（x86_64）"
        #endif
    }

    /// 复测/反馈问题时要的一行环境摘要（复制到剪贴板用）。
    static var diagnosticsText: String {
        "OneOfPassword \(shortVersion)（\(buildNumber)） · \(systemDescription) · \(architectureDescription)"
    }
}
