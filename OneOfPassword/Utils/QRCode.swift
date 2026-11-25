//
//  QRCode.swift
//  OneOfPassword
//
//  把一个字符串生成二维码图片（用于「关于」页分享 GitHub 链接）。
//
//  === 为什么要自己控制「像素/模块」和插值方式 ===
//  直接 CIFilter 出图再 `NSImage.draw(in:)` 放大，会走双线性插值，模块边缘被抹成
//  灰阶渐变，手机相机在弱光/远距离下明显更难识别。这里改成：
//  ① 先算出「每个模块用几个整数像素」再渲染（模块大小均匀，不会 6px/7px 混排）；
//  ② 用 `.none` 插值绘制（硬边）；
//  ③ 四周补 4 个模块的白边（QR 规范要求的 quiet zone；缺了它很多相机扫不出来）。
//  另外按 `backingScaleFactor` 出 2x 像素，Retina 屏上才不糊。
//

import AppKit
import CoreImage

enum QRCode {

    /// QR 规范的建议静区：4 个模块宽的白边。
    private static let quietZoneModules = 4
    /// 每个模块最少几个像素。再小就接近相机分辨极限，宁可整图变大一点。
    private static let minPixelsPerModule = 3

    /// 已生成的图缓存。弹层每次 `body` 都会重新求值，不缓存就是每次重跑 CI 滤镜。
    /// 只在主线程调用（SwiftUI body），所以不加锁。
    private static var cache: [String: NSImage] = [:]

    /// 生成二维码。`pointSize` 是期望的**点尺寸**，实际尺寸会被量化到「整数模块像素」。
    /// 返回 nil 表示编码失败（字符串非 UTF-8 或滤镜不可用，正常不会发生）。
    static func image(for text: String, pointSize: CGFloat,
                      scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2) -> NSImage? {
        let key = "\(text)|\(pointSize)|\(scale)"
        if let cached = cache[key] { return cached }
        guard let data = text.data(using: .utf8) else { return nil }

        let filter = CIFilter(name: "CIQRCodeGenerator")
        // M 级纠错（约 15%）：链接只有几十字节，M 级足够，模块数也不会太多（模块少=更容易扫）
        filter?.setValue(data, forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter?.outputImage else { return nil }

        let context = CIContext()
        guard let cg = context.createCGImage(output, from: output.extent) else { return nil }

        // CIQRCodeGenerator 的输出是「1 像素 = 1 模块」，所以宽度就是模块数
        let modules = cg.width
        guard modules > 0 else { return nil }

        let total = modules + quietZoneModules * 2
        let targetPixels = pointSize * scale
        let pixelsPerModule = max(minPixelsPerModule, Int((targetPixels / CGFloat(total)).rounded()))
        let pixelSize = total * pixelsPerModule

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize, pixelsHigh: pixelSize,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = graphics
        let ctx = graphics.cgContext

        // 白底（含静区）。深色界面下二维码若是透明底，部分相机会认不出边界。
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))

        // 硬边放大：否则模块边缘出现灰阶过渡，扫描成功率下降
        ctx.interpolationQuality = .none
        let inset = CGFloat(quietZoneModules * pixelsPerModule)
        ctx.draw(cg, in: CGRect(x: inset, y: inset,
                                width: CGFloat(modules * pixelsPerModule),
                                height: CGFloat(modules * pixelsPerModule)))

        NSGraphicsContext.restoreGraphicsState()

        // 用点作为逻辑尺寸（像素是它的 scale 倍），Retina 上由系统按 2x 取样
        rep.size = NSSize(width: CGFloat(pixelSize) / scale, height: CGFloat(pixelSize) / scale)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        image.isTemplate = false
        cache[key] = image
        return image
    }
}
