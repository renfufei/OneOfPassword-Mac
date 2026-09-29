//
//  ScreenshotCaptureService.swift
//  OneOfPassword
//
//  区域截图、标注合成、文件保存/复制、前台窗口识别。
//

import AppKit
import CoreGraphics
import SwiftUI

enum ScreenshotCaptureService {

    // MARK: - 截图

    /// 抓取全屏快照（覆盖层显示前调用，此时屏幕是目标内容）。
    /// 用 screencapture 命令行截全屏到临时文件，避免 app 自身 CGWindowListCreateImage 权限问题。
    static func captureFullScreen() -> CGImage? {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oop_full_\(UUID().uuidString).png")

        ScreenshotLogger.log("captureFullScreen() using screencapture")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", tmpURL.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            ScreenshotLogger.log("captureFullScreen() run failed: \(error)")
            return nil
        }
        guard process.terminationStatus == 0 else {
            ScreenshotLogger.log("captureFullScreen() exit status=\(process.terminationStatus)")
            try? FileManager.default.removeItem(at: tmpURL)
            return nil
        }
        guard let nsImage = NSImage(contentsOf: tmpURL),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            ScreenshotLogger.log("captureFullScreen() failed to load image")
            try? FileManager.default.removeItem(at: tmpURL)
            return nil
        }
        try? FileManager.default.removeItem(at: tmpURL)
        ScreenshotLogger.log("captureFullScreen() OK size=\(cgImage.width)x\(cgImage.height)")
        return cgImage
    }

    /// 从全屏快照裁剪指定区域。rect 为视图坐标（左上原点），快照为左上原点像素，直接按 scale 换算。
    static func crop(from snapshot: CGImage, rect: CGRect) -> CGImage? {
        guard let screen = NSScreen.main else { return nil }
        let scale = screen.backingScaleFactor
        let pxX = rect.minX * scale
        let pxY = rect.minY * scale
        let pxW = rect.width * scale
        let pxH = rect.height * scale
        let cropRect = CGRect(x: pxX, y: pxY, width: pxW, height: pxH)
        ScreenshotLogger.log("crop() rect=\(rect) scale=\(scale) cropRect=\(cropRect)")
        guard let cropped = snapshot.cropping(to: cropRect) else {
            ScreenshotLogger.log("crop() cropping failed")
            return nil
        }
        return cropped
    }

    // 屏幕录制权限的查询 / 申请 / 跳转已统一收拢到 `AppPermission`（Services/AppPermission.swift），
    // 这里不再保留第二份实现 —— 截屏与验证码「截取屏幕」共用同一份状态真相。

    // MARK: - 上次选区记忆

    private static let lastSelectionKey = "screenshotLastSelectionRect"

    /// 记住上次截屏使用的框选区域（全屏视图坐标，左上原点、点单位），
    /// 下次进入截屏时自动定位到相同位置。
    static func saveLastSelection(_ rect: CGRect) {
        let arr: [CGFloat] = [rect.origin.x, rect.origin.y, rect.width, rect.height]
        UserDefaults.standard.set(arr, forKey: lastSelectionKey)
        ScreenshotLogger.log("saveLastSelection \(rect)")
    }

    /// 读取上次框选区域；无记录或格式异常返回 nil。
    static func loadLastSelection() -> CGRect? {
        guard let arr = UserDefaults.standard.array(forKey: lastSelectionKey) as? [CGFloat],
              arr.count == 4, arr[2] > 1, arr[3] > 1 else { return nil }
        return CGRect(x: arr[0], y: arr[1], width: arr[2], height: arr[3])
    }

    // MARK: - 标注合成

    /// 将标注叠加到底图上。shapes 的 points 为相对底图【左下原点、像素】坐标（已由调用方完成
    /// 视图左上→底图左下、点→像素的转换）。底图经 NSImage.draw 正立绘制，标注按左下原点直接绘制，方向一致。
    static func composite(base: CGImage, shapes: [AnnotationShape]) -> CGImage? {
        let width = base.width
        let height = base.height
        let size = NSSize(width: width, height: height)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        defer { NSGraphicsContext.restoreGraphicsState() }

        // cgContext 默认左下原点；底图用 NSImage.draw 正立绘制，标注按左下原点直接绘制，方向一致。
        NSGraphicsContext.current?.cgContext.textMatrix = .identity

        // 画底图（CGImage 在 NSGraphicsContext 里用 draw(in:) 正立绘制）
        NSImage(cgImage: base, size: size).draw(in: NSRect(origin: .zero, size: size))

        // 画标注（points 为底图左上原点坐标，坐标系已统一为左上原点）
        let ctx = NSGraphicsContext.current!.cgContext
        for shape in shapes {
            drawShapeNS(shape, in: ctx, canvasHeight: CGFloat(height))
        }

        return rep.cgImage
    }

    private static func drawShapeNS(_ shape: AnnotationShape, in ctx: CGContext, canvasHeight: CGFloat) {
        guard let first = shape.points.first else { return }
        let cgColor = cgColor(shape.color)
        ctx.setStrokeColor(cgColor)
        ctx.setFillColor(cgColor)
        ctx.setLineWidth(shape.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // points 已是底图左下原点像素坐标，NSGraphicsContext 亦为左下原点，无需翻转
        switch shape.tool {
        case .rectangle:
            let r = CGRect(from: first, to: shape.points.last ?? first)
            ctx.stroke(r)
        case .circle:
            let r = CGRect(from: first, to: shape.points.last ?? first)
            ctx.strokeEllipse(in: r)
        case .arrow:
            let end = shape.points.last ?? first
            ctx.beginPath()
            ctx.move(to: first)
            ctx.addLine(to: end)
            ctx.strokePath()
            let angle = atan2(end.y - first.y, end.x - first.x)
            let len = max(12, shape.lineWidth * 4)
            let a1 = CGPoint(x: end.x - len * cos(angle - .pi / 6),
                             y: end.y - len * sin(angle - .pi / 6))
            let a2 = CGPoint(x: end.x - len * cos(angle + .pi / 6),
                             y: end.y - len * sin(angle + .pi / 6))
            ctx.beginPath()
            ctx.move(to: end); ctx.addLine(to: a1)
            ctx.move(to: end); ctx.addLine(to: a2)
            ctx.strokePath()
        case .pen:
            ctx.beginPath()
            ctx.move(to: first)
            for p in shape.points.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        case .text, .selection:
            guard shape.tool == .text, let str = shape.text, !str.isEmpty,
                  let topLeft = shape.points.first else { return }
            let style = shape.style
            let textSize = style.textSize(for: str)
            let boxSize = style.boxSize(for: str)
            // points 已转成底图【左下原点】像素坐标，而 topLeft 语义上是「文本框左上角」，
            // 转换后它对应盒子在底图里的**上边**；所以 CG rect 要自 topLeft.y 向下（y 减小）展开。
            let boxRect = NSRect(x: topLeft.x, y: topLeft.y - boxSize.height,
                                 width: boxSize.width, height: boxSize.height)
            let radius = min(style.fontSize * 0.22, 8)

            // 背景（opacity = 0 表示完全透明，不画）
            // 注意：本函数开头有 `let cgColor = cgColor(shape.color)`，同名局部变量会遮蔽
            // 静态方法 `cgColor(_:)`，所以这里必须写成 `Self.cgColor(...)`。
            if style.backgroundOpacity > 0 {
                let bg = NSColor(cgColor: Self.cgColor(style.backgroundColor)) ?? .black
                ctx.setFillColor(bg.withAlphaComponent(style.backgroundOpacity).cgColor)
                ctx.addPath(CGPath(roundedRect: boxRect, cornerWidth: radius,
                                   cornerHeight: radius, transform: nil))
                ctx.fillPath()
            }
            // 边框（线宽 = 0 表示无边框）
            if style.borderWidth > 0 {
                ctx.setStrokeColor(Self.cgColor(style.borderColor))
                ctx.setLineWidth(style.borderWidth)
                ctx.addPath(CGPath(roundedRect: boxRect, cornerWidth: radius,
                                   cornerHeight: radius, transform: nil))
                ctx.strokePath()
            }

            let attr: [NSAttributedString.Key: Any] = [
                .font: style.nsFont(),
                // 文字颜色取 `style.textColor`，**不再复用** `shape.color`（那是图形颜色）。
                // 同样必须写成 `Self.cgColor(...)`：函数开头的局部变量 `cgColor` 会遮蔽它。
                .foregroundColor: NSColor(cgColor: Self.cgColor(style.textColor)) ?? .white
            ]
            let attrStr = NSAttributedString(string: str, attributes: attr)
            // 文字左上角 = 盒子左上角 + 内边距；再折算成左下原点的绘制矩形
            let textRect = NSRect(x: topLeft.x + style.paddingH,
                                  y: topLeft.y - style.paddingV - textSize.height,
                                  width: textSize.width, height: textSize.height)
            attrStr.draw(in: textRect)
        }
    }

    private static func cgColor(_ color: Color) -> CGColor {
        NSColor(color).usingColorSpace(.sRGB)?.cgColor ?? CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    }

    // MARK: - 输出

    /// 弹出保存面板，写入 PNG。
    static func savePanel(image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "截屏 \(timestamp()).png"
        panel.prompt = "保存"
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url, options: .atomic)
        }
    }

    /// 复制 PNG 到剪贴板。
    static func copyToPasteboard(image: CGImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let rep = NSBitmapImageRep(cgImage: image)
        if let png = rep.representation(using: .png, properties: [:]) {
            pb.setData(png, forType: .png)
        }
    }

    // MARK: - 鼠标所在窗口识别（类似钉钉自动选窗口）

    /// 识别鼠标当前所在的最上层普通窗口，返回其在主屏 overlay 视图坐标系（左上原点、点单位）下的 rect。
    /// 用于「自动识别鼠标所在窗口」预选选区。未找到合适窗口返回 nil。
    /// 注意：必须在隐藏本应用窗口之前调用（否则鼠标若恰在本应用窗口上，顶层会变化）。
    static func windowAtMouse() -> CGRect? {
        guard let ev = CGEvent(source: nil) else { return nil }
        let mouse = ev.location  // CG 全局坐标，左上原点
        ScreenshotLogger.log("windowAtMouse called, mouse=\(mouse)")

        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        let selfPid = Int(ProcessInfo.processInfo.processIdentifier)

        for info in infos {
            // 跳过本应用窗口（CG 字典值是 Int，不能用 pid_t(Int32) 直接 as? 转换）
            guard let pid = info[kCGWindowOwnerPID as String] as? Int, pid != selfPid else { continue }
            // 只取默认层级（0）普通窗口，跳过菜单/Dock/浮层等
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            let alpha = info[kCGWindowAlpha as String] as? CGFloat ?? 1
            guard alpha > 0.01 else { continue }
            guard let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let w = b["Width"] ?? 0
            let h = b["Height"] ?? 0
            guard w > 10, h > 10 else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: w, height: h)
            if r.contains(mouse) {
                // CG 窗口坐标是全局左上原点，平移到 NSScreen.main 局部（overlay 视图坐标）。
                // 用 CGDisplayBounds 拿 main screen 在 CG 坐标系的 origin，多屏也正确。
                guard let mainScreen = NSScreen.main,
                      let displayID = mainScreen.deviceDescription[
                        NSDeviceDescriptionKey("NSScreenNumber")
                      ] as? CGDirectDisplayID else {
                    ScreenshotLogger.log("windowAtMouse matched pid=\(pid) layer=\(layer) raw=\(r) (no mainScreen, return raw)")
                    return r
                }
                let screenCG = CGDisplayBounds(displayID)
                let out = CGRect(x: r.origin.x - screenCG.origin.x,
                                y: r.origin.y - screenCG.origin.y,
                                width: r.width,
                                height: r.height)
                ScreenshotLogger.log("windowAtMouse matched pid=\(pid) layer=\(layer) raw=\(r) out=\(out)")
                return out
            }
        }
        ScreenshotLogger.log("windowAtMouse no match, mouse=\(mouse) count=\(infos.count)")
        return nil
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f.string(from: Date())
    }
}
