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

    /// 从全屏快照裁剪指定区域。rect 为视图坐标（左下原点），快照为左上原点。
    static func crop(from snapshot: CGImage, rect: CGRect) -> CGImage? {
        guard let screen = NSScreen.main else { return nil }
        let scale = screen.backingScaleFactor
        // 视图坐标（左下原点）→ 图片像素坐标（左上原点）
        let imgH = CGFloat(snapshot.height)
        let pxX = rect.minX * scale
        let pxY = (CGFloat(screen.frame.height) - rect.maxY) * scale
        let pxW = rect.width * scale
        let pxH = rect.height * scale
        let cropRect = CGRect(x: pxX, y: imgH - pxY - pxH, width: pxW, height: pxH)
        ScreenshotLogger.log("crop() rect=\(rect) scale=\(scale) cropRect=\(cropRect) imgH=\(imgH)")
        guard let cropped = snapshot.cropping(to: cropRect) else {
            ScreenshotLogger.log("crop() cropping failed")
            return nil
        }
        return cropped
    }

    /// 屏幕录制权限是否已授权（screencapture 方案不依赖此权限，保留供设置页展示状态）。
    static var hasScreenCapturePermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 请求屏幕录制权限（触发系统弹框）。返回当前授权状态，但系统弹框授权是异步生效的，
    /// 调用方应在用户从系统设置返回后重新检查。
    @discardableResult
    static func requestScreenCaptureAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// 打开系统设置 > 屏幕录制。
    static func openScreenCaptureSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        NSWorkspace.shared.open(url ?? URL(fileURLWithPath: "/"))
    }

    // MARK: - 标注合成

    /// 将标注叠加到底图上。shapes 的 points 为相对底图左上原点的坐标。
    /// 用 NSGraphicsContext（左上原点）合成，方向直观，避免 CGContext 坐标系陷阱。
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

        // NSGraphicsContext 默认左下原点；设为左上原点，使 base 和标注方向一致、直观
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

        // points 是 view 左下原点坐标，NSGraphicsContext 默认也是左下原点，无需翻转
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
                  let end = shape.points.first else { return }
            let attr: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18, weight: .medium),
                .foregroundColor: NSColor(cgColor: cgColor) ?? .red
            ]
            let attrStr = NSAttributedString(string: str, attributes: attr)
            let textSize = attrStr.size()
            // NSGraphicsContext 左下原点：文本基线对齐
            let textRect = NSRect(origin: NSPoint(x: end.x, y: end.y - textSize.height),
                                  size: textSize)
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

    // MARK: - 前台窗口识别

    /// 返回鼠标所在最上层普通窗口的屏幕全局 rect（左上原点坐标）。
    static func windowAt(_ point: CGPoint) -> CGRect? {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in infos {
            // 跳过自身与无标题窗口
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let x = bounds["X"] ?? 0
            let y = bounds["Y"] ?? 0
            let w = bounds["Width"] ?? 0
            let h = bounds["Height"] ?? 0
            let r = CGRect(x: x, y: y, width: w, height: h)
            if r.contains(point) {
                // 把 CG 窗口坐标（左上原点）转为 NSScreen 视图坐标（左下原点）
                return toScreenViewRect(r)
            }
        }
        return nil
    }

    /// CG 坐标 rect（左上原点）→ 视图坐标 rect（左下原点，供 overlay 使用）。
    static func toScreenViewRect(_ cgRect: CGRect) -> CGRect {
        guard let screen = NSScreen.main else { return cgRect }
        return CGRect(x: cgRect.origin.x,
                      y: screen.frame.maxY - cgRect.maxY,
                      width: cgRect.width,
                      height: cgRect.height)
    }

    /// 视图坐标 rect（左下原点）→ CG 截屏坐标 rect（左上原点）。
    static func toCaptureRect(_ viewRect: CGRect) -> CGRect {
        guard let screen = NSScreen.main else { return viewRect }
        return CGRect(x: viewRect.origin.x,
                      y: screen.frame.maxY - viewRect.maxY,
                      width: viewRect.width,
                      height: viewRect.height)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f.string(from: Date())
    }
}
