//
//  MultilineTextEditor.swift
//  OneOfPassword
//
//  文本标注的输入控件：把 AppKit 的 `NSTextView` 包进 SwiftUI。
//

import SwiftUI
import AppKit

/// 多行文本编辑器（`NSTextView` 的 SwiftUI 包装）。
///
/// 为什么不再用 SwiftUI 的 `TextField`（三个真实踩过的坑）：
/// 1. `TextField(axis: .vertical)` 的 Return 行为不受控 —— 回车不走「插入换行」，
///    而是被当成提交/全选，多行输入根本做不出来；
/// 2. 输入过程中的内容变化无法即时回灌模型，文本框宽高要等**失焦之后**才更新；
/// 3. 中文输入法的组合文本（marked text）在浮层里表现不稳定。
///
/// `NSTextView` 是 AppKit 原生的多行编辑器，上面三件事都是它的默认行为：
/// Return 插换行、逐字符 `textDidChange` 回调、IME 组合文本天然支持。
/// 结束编辑只认 **Esc**（输入法组合中除外）与 **Cmd+Enter**，见 `onCommit`。
struct MultilineTextEditor: NSViewRepresentable {
    /// 模型侧的当前文本（真值来源）
    let text: String
    let style: TextStyle
    let textColor: Color
    /// 每次输入变化**立即**回调（不是等失焦）——模型实时更新，盒子才会跟着长
    let onChange: (String) -> Void
    /// 结束编辑（Esc / Cmd+Enter）
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView(frame: .zero)
        // 背景透明：底色/边框由 SwiftUI 那层画，与 Canvas 画的盒子同源，编辑期间外观不跳
        tv.drawsBackground = false
        tv.isRichText = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.isFieldEditor = false
        tv.usesFontPanel = false
        tv.usesFindBar = false
        // 关掉全部「智能替换」：标注文字必须原样保留，
        // 不能被系统把 " 换成弯引号、把 -- 换成破折号（这些字符还要原样画进截图）
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        // 内边距交给 SwiftUI 的 padding（与 Canvas 的 paddingH/paddingV 同源），这里清零
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        // **不折行**：Canvas 侧就是「按 \n 分行、逐行量宽、不折行」，
        // 编辑器必须同一套规则 —— 否则输入过程中会出现「编辑器里折了行、盒子里没折」的错位。
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: 1_000_000, height: 1_000_000)
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        tv.minSize = .zero
        tv.maxSize = NSSize(width: 1_000_000, height: 1_000_000)
        tv.alignment = .left
        tv.delegate = context.coordinator
        applyStyle(to: tv)
        tv.string = text
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        context.coordinator.parent = self
        applyStyle(to: tv)
        // 只在「模型值 ≠ 视图值」时回写（外部改内容，比如新建时），
        // 否则会把用户正在敲的内容和光标位置冲掉。
        if tv.string != text {
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        // 宽度随内容实时变化 → frame 变化，主动请求重绘，避免残留旧的裁剪区域
        tv.needsDisplay = true
        // 首次出现（新建文本框 / 点开已有文本框）时抢第一响应者。
        // 必须异步：这一刻视图还没上屏，`tv.window` 还是 nil。
        // 而且要重试几次 —— 面板/窗口还没成为 key 时 `makeFirstResponder` 会静默失败，
        // 表现就是「框画出来了但敲键盘没反应」（这个坑踩过）。
        if !context.coordinator.focused {
            context.coordinator.focused = true
            context.coordinator.grabFocus(tv, attempt: 0)
        }
    }

    private func applyStyle(to tv: NSTextView) {
        tv.font = style.nsFont()
        let ns = NSColor(textColor)
        tv.textColor = ns
        tv.insertionPointColor = ns
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineTextEditor
        /// 是否已经抢过第一响应者。只抢一次 —— 否则用户去点工具栏时会被反复抢回来。
        var focused = false

        init(_ parent: MultilineTextEditor) { self.parent = parent }

        /// 抢第一响应者（带上限重试）。
        /// 只重试很短的一段时间（0 → 0.1 → 0.2 → …s，共 5 次），
        /// 一旦成功就彻底停 —— 否则用户随后去点工具栏下拉时会被把焦点抢回来。
        func grabFocus(_ tv: NSTextView, attempt: Int) {
            guard attempt < 5 else { return }
            let delay = attempt == 0 ? 0.0 : 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak tv] in
                guard let tv else { return }
                guard let win = tv.window else {
                    // 还没上屏：稍后再试
                    self.grabFocus(tv, attempt: attempt + 1)
                    return
                }
                if !win.isKeyWindow { win.makeKey() }
                if win.firstResponder !== tv {
                    win.makeFirstResponder(tv)
                    if win.firstResponder !== tv {
                        self.grabFocus(tv, attempt: attempt + 1)
                    }
                }
            }
        }

        /// 逐字符回调：这里就是「输入即更新模型」的来源，盒子宽高因此实时跟随。
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.onChange(tv.string)
        }

        /// 兜底拦截 Esc / Cmd+Enter 结束编辑。
        /// 主路径其实是 `ScreenshotOverlayView` 里的本地键监听（它先于事件派发执行），
        /// 这里只是防止监听被摘掉时回车/esc 行为退化。
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCommit()
                return true
            }
            // Return 的各种 selector 名字（不同修饰键/键盘布局映射到不同的）
            let newlineSelectors = ["insertNewline:", "insertNewlineIgnoringFieldEditor:"]
            if newlineSelectors.contains(NSStringFromSelector(commandSelector)),
               NSEvent.modifierFlags.contains(.command) {
                parent.onCommit()
                return true
            }
            return false
        }
    }
}
