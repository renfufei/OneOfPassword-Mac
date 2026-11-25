#!/usr/bin/env swift
// gen_dmg_background.swift — 生成 DMG 安装窗口背景图（含「应用 → Applications」连接线）
//
// 用法:
//   swift scripts/gen_dmg_background.swift <输出目录> [窗口宽 窗口高 图标尺寸
//        appX appY  appsX appsY  txtX txtY]
//
// 输出: <输出目录>/background.png（1x）、<输出目录>/background@2x.png（2x）
// 由 build.sh 调 tiffutil 合成多分辨率 dmg-background.tiff 给 Finder 用。
//
// 【几何一致性铁律】这里画的连接线与圆点，必须和 build.sh 里 DMG_ICON_* 常量、
//   以及 Finder 布局脚本里的图标坐标完全一致；否则箭头会跑到图标外面。
//   所以所有坐标都由 build.sh 传进来，本文件不存第二份真相。

import AppKit
import CoreGraphics
import Foundation

// ── 参数 ────────────────────────────────────────────────────────
let argv = CommandLine.arguments
guard argv.count >= 2 else {
    FileHandle.standardError.write("用法: swift gen_dmg_background.swift <输出目录> [W H iconSize appX appY appsX appsY txtX txtY]\n".data(using: .utf8)!)
    exit(2)
}
let outDir = argv[1]

func arg(_ i: Int, _ def: CGFloat) -> CGFloat {
    guard argv.count > i, let v = Double(argv[i]) else { return def }
    return CGFloat(v)
}

let W        = arg(2, 660)     // 窗口内容宽（pt）
let H        = arg(3, 480)     // 窗口内容高（pt）
let iconSize = arg(4, 112)     // Finder 图标尺寸（pt）
let appX     = arg(5, 165)     // 左侧 .app 图标中心
let appY     = arg(6, 215)
let appsX    = arg(7, 495)     // 右侧 Applications 图标中心
let appsY    = arg(8, 215)
let txtX     = arg(9, 330)     // 底部「安装说明.txt」图标中心
let txtY     = arg(10, 392)

// ── 配色（跟随应用图标的靛蓝风格）────────────────────────────────
// 三档竖向渐变：顶部略亮 → 中段最亮 → 底部最暗
let bgTop    = (r: 0.086, g: 0.094, b: 0.173)   // #16182C
let bgMid    = (r: 0.118, g: 0.126, b: 0.220)   // #1E2038
let bgBottom = (r: 0.039, g: 0.043, b: 0.078)   // #0A0B14
let glowTint = (r: 0.36,  g: 0.36,  b: 0.85)    // 中段柔光的紫调
let accent    = CGColor(red: 0.74, green: 0.72, blue: 1.00, alpha: 1)    // #BDB8FF
let titleColor   = NSColor(white: 1.0, alpha: 0.96)
let subtitleColor = NSColor(white: 1.0, alpha: 0.52)
let hintColor     = NSColor(white: 1.0, alpha: 0.30)

// ── 绘制（坐标一律按「左上角原点、y 向下」书写）──────────────────
func render(scale: CGFloat) -> Data {
    let pw = Int(W * scale)
    let ph = Int(H * scale)
    // 4 通道（alpha 全不透明，压缩后几乎不占体积）：24 位 RGB 的
    // NSBitmapImageRep 没法包成 NSGraphicsContext，文字就画不上去。
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("位图创建失败") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: scale, y: scale)          // 之后全部按 pt 绘制

    /// 左上角原点的 y → AppKit 的 y
    func ty(_ y: CGFloat) -> CGFloat { H - y }

    // ── 背景：逐行填色，【不要用 drawLinearGradient】──────────────
    // CoreGraphics 往 8 位上下文画渐变会自动加抖动，一张 660×480 的纯渐变
    // PNG 会因此涨到 330KB，LZW 完全压不动，DMG 直接胖 1MB。
    // 每行一个纯色矩形没有抖动、行内像素完全相同，压缩率极高。
    // 中段柔光也做成「只随 y 变化」，保持行内一致。
    let midY = 0.46
    for row in 0..<Int(H) {
        let t = Double(row) / Double(H)
        var c: (r: Double, g: Double, b: Double)
        if t < midY {
            let k = midY > 0 ? t / midY : 0
            c = (bgTop.r + (bgMid.r - bgTop.r) * k,
                 bgTop.g + (bgMid.g - bgTop.g) * k,
                 bgTop.b + (bgMid.b - bgTop.b) * k)
        } else {
            let k = (t - midY) / max(0.0001, 1 - midY)
            c = (bgMid.r + (bgBottom.r - bgMid.r) * k,
                 bgMid.g + (bgBottom.g - bgMid.g) * k,
                 bgMid.b + (bgBottom.b - bgMid.b) * k)
        }
        // 中段柔光：越接近 midY 越亮，平方衰减更自然
        let d = abs(t - midY) / 0.62
        let glow = max(0, 1 - d)
        let gk = 0.085 * glow * glow
        c.r += glowTint.r * gk
        c.g += glowTint.g * gk
        c.b += glowTint.b * gk

        ctx.setFillColor(CGColor(red: c.r, green: c.g, blue: c.b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: CGFloat(Int(H) - row - 1), width: W, height: 1))
    }

    // ── 标题 / 副标题 ────────────────────────────────────────────
    let para = NSMutableParagraphStyle()
    para.alignment = .center

    func drawCentered(_ text: String, top: CGFloat, font: NSFont, color: NSColor, kern: CGFloat = 0) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: para, .kern: kern,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: (W - size.width) / 2, y: ty(top) - size.height))
    }

    drawCentered("OneOfPassword", top: 84,
                 font: .systemFont(ofSize: 32, weight: .semibold), color: titleColor)
    drawCentered("拖入 Applications 文件夹即可安装", top: 128,
                 font: .systemFont(ofSize: 14, weight: .regular), color: subtitleColor)

    // ── 连接线：从左图标右缘 → 右图标左缘 ────────────────────────
    // 起点/终点贴着图标外缘（各留 10pt 间隙），曲线先微沉再上扬，
    // 和 Finder 实际图标位置由同一组坐标推导，不会错位。
    let start = CGPoint(x: appX + iconSize / 2 + 10, y: ty(appY + 18))
    let end   = CGPoint(x: appsX - iconSize / 2 - 10, y: ty(appsY - 18))
    let span  = end.x - start.x

    let curve = CGMutablePath()
    curve.move(to: start)
    curve.addCurve(to: end,
                   control1: CGPoint(x: start.x + span * 0.42, y: start.y - 26),
                   control2: CGPoint(x: end.x - span * 0.42, y: end.y + 26))

    // 先描一条略宽的低透明度线当柔光，再描主线
    ctx.addPath(curve)
    ctx.setStrokeColor(accent.copy(alpha: 0.20)!)
    ctx.setLineWidth(11)
    ctx.setLineCap(.round)
    ctx.strokePath()

    ctx.addPath(curve)
    ctx.setStrokeColor(accent)
    ctx.setLineWidth(3.5)
    ctx.setLineCap(.round)
    ctx.strokePath()

    // 两端圆点：起点实心小点，终点实心 + 外圈
    ctx.setFillColor(accent)
    ctx.fillEllipse(in: CGRect(x: start.x - 4.5, y: start.y - 4.5, width: 9, height: 9))
    ctx.fillEllipse(in: CGRect(x: end.x - 5.5, y: end.y - 5.5, width: 11, height: 11))
    ctx.setStrokeColor(accent.copy(alpha: 0.6)!)
    ctx.setLineWidth(2)
    ctx.strokeEllipse(in: CGRect(x: end.x - 12, y: end.y - 12, width: 24, height: 24))

    // ── 底部提示（对应 安装说明.txt）─────────────────────────────
    drawCentered("首次打开若提示「无法验证开发者」，请查看下方 安装说明",
                 top: txtY - iconSize / 2 - 26,
                 font: .systemFont(ofSize: 11, weight: .regular), color: hintColor)

    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG 导出失败")
    }
    return data
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (scale, name) in [(CGFloat(1), "background.png"), (CGFloat(2), "background@2x.png")] {
    let path = (outDir as NSString).appendingPathComponent(name)
    try! render(scale: scale).write(to: URL(fileURLWithPath: path))
    print("✅ \(path)")
}
