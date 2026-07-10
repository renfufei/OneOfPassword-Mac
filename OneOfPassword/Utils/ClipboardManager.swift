//
//  ClipboardManager.swift
//  OneOfPassword
//
//  剪贴板管理
//

import AppKit
import Foundation

class ClipboardManager {
    static let shared = ClipboardManager()

    private var clearTimer: Timer?

    private init() {}

    func copy(_ text: String, autoClearAfter seconds: TimeInterval = 30) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // Schedule auto-clear
        clearTimer?.invalidate()
        clearTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.clearIfMatches(text)
        }
    }

    private func clearIfMatches(_ originalText: String) {
        if let currentText = NSPasteboard.general.string(forType: .string),
           currentText == originalText {
            NSPasteboard.general.clearContents()
        }
    }

    func cancelAutoClear() {
        clearTimer?.invalidate()
        clearTimer = nil
    }
}
