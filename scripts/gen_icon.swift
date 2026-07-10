#!/usr/bin/env swift
// gen_icon.swift — 生成 OneOfPassword 应用图标 (1024×1024)
// 用法: swift scripts/gen_icon.swift

import AppKit
import CoreGraphics

let size = 1024
let outPath = "scripts/AppIcon-1024.png"

let nsImg = NSImage(size: NSSize(width: size, height: size))
nsImg.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }

let colorSpace = CGColorSpaceCreateDeviceRGB()

// ── 背景：深蓝到蓝紫渐变 ──────────────────────────────────────────
let gradientColors: [CGColor] = [
    CGColor(red: 0.10, green: 0.22, blue: 0.58, alpha: 1), // 深蓝
    CGColor(red: 0.36, green: 0.16, blue: 0.72, alpha: 1), // 蓝紫
]
let locations: [CGFloat] = [0, 1]
let gradient = CGGradient(colorsSpace: colorSpace,
                          colors: gradientColors as CFArray,
                          locations: locations)!

// macOS 图标标准圆角
let radius = CGFloat(size) * 0.2237
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let clipPath = CGMutablePath()
clipPath.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
ctx.addPath(clipPath)
ctx.clip()

ctx.drawLinearGradient(gradient,
    start: CGPoint(x: 0, y: CGFloat(size)),
    end:   CGPoint(x: CGFloat(size), y: 0),
    options: [])

// ── 盾牌（白色半透明轮廓）────────────────────────────────────────
let cx = CGFloat(size) / 2
let cy = CGFloat(size) / 2
let sw: CGFloat = 580
let sh: CGFloat = 640
let sx = cx - sw / 2
let sy = cy - sh / 2 - 10

let shieldPath = CGMutablePath()
shieldPath.move(to: CGPoint(x: sx + sw * 0.15, y: sy))
shieldPath.addLine(to: CGPoint(x: sx + sw * 0.85, y: sy))
shieldPath.addQuadCurve(to: CGPoint(x: sx + sw, y: sy + sh * 0.16),
                         control: CGPoint(x: sx + sw, y: sy))
shieldPath.addLine(to: CGPoint(x: sx + sw, y: sy + sh * 0.56))
shieldPath.addQuadCurve(to: CGPoint(x: cx, y: sy + sh),
                         control: CGPoint(x: sx + sw, y: sy + sh * 0.82))
shieldPath.addQuadCurve(to: CGPoint(x: sx, y: sy + sh * 0.56),
                         control: CGPoint(x: sx, y: sy + sh * 0.82))
shieldPath.addLine(to: CGPoint(x: sx, y: sy + sh * 0.16))
shieldPath.addQuadCurve(to: CGPoint(x: sx + sw * 0.15, y: sy),
                         control: CGPoint(x: sx, y: sy))
shieldPath.closeSubpath()

ctx.addPath(shieldPath)
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
ctx.fillPath()
ctx.addPath(shieldPath)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.30))
ctx.setLineWidth(7)
ctx.strokePath()

// ── 文字 ─────────────────────────────────────────────────────────
let paraStyle = NSMutableParagraphStyle()
paraStyle.alignment = .center

// 主字 "GA" — 大号粗体
let mainAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 340, weight: .heavy),
    .foregroundColor: NSColor.white,
    .paragraphStyle: paraStyle,
]
let mainStr = NSAttributedString(string: "GA", attributes: mainAttrs)
let mainSize = mainStr.size()
mainStr.draw(at: NSPoint(
    x: cx - mainSize.width / 2,
    y: cy - mainSize.height / 2 + 40
))

// 副标小字
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 56, weight: .regular),
    .foregroundColor: NSColor(white: 1, alpha: 0.65),
    .paragraphStyle: paraStyle,
    .kern: 8.0,
]
let subStr = NSAttributedString(string: "OneOfPassword", attributes: subAttrs)
let subSize = subStr.size()
subStr.draw(at: NSPoint(
    x: cx - subSize.width / 2,
    y: cy - mainSize.height / 2 - subSize.height - 4
))

nsImg.unlockFocus()

// 导出 PNG
guard let tiffData = nsImg.tiffRepresentation,
      let bitmapRep = NSBitmapImageRep(data: tiffData),
      let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
    fatalError("PNG 导出失败")
}

try! pngData.write(to: URL(fileURLWithPath: outPath))
print("✅ 图标已生成：\(outPath)")
