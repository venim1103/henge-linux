#!/usr/bin/env swift
// SPDX-License-Identifier: GPL-3.0-or-later
// Deterministically renders the HengeLinux "OLED Obsidian + Cobalt Dark Edition"
// iOS 18–27 app icon set (Light, Dark, Tinted 1024x1024 + 256x256 About preview)
// into ios/Assets.xcassets using native CoreGraphics / ImageIO.
//
// Usage: swift scripts/make_icon.swift ios/Assets.xcassets

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum IconVariant {
    case fullColor
    case tinted
}

let args = CommandLine.arguments
let assetsDir = args.count > 1 ? args[1] : "ios/Assets.xcassets"
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func rgba(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255.0
    let g = CGFloat((hex >> 8) & 0xFF) / 255.0
    let b = CGFloat(hex & 0xFF) / 255.0
    return CGColor(colorSpace: srgb, components: [r, g, b, alpha])!
}

func makeGradient(_ stops: [(CGFloat, UInt32, CGFloat)]) -> CGGradient {
    let colors = stops.map { rgba($0.1, $0.2) } as CFArray
    let locs = stops.map { $0.0 }
    return CGGradient(colorsSpace: srgb, colors: colors, locations: locs)!
}

func drawRoundedWindow(
    in ctx: CGContext,
    rect: CGRect,
    radius: CGFloat,
    fillGradient: CGGradient,
    strokeGradient: CGGradient,
    strokeWidth: CGFloat,
    glowColor: CGColor,
    glowBlur: CGFloat,
    dividerColor: CGColor,
    drawSheen: Bool,
    drawDots: Bool,
    tinted: Bool
) {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Subtle neon outer rim glow
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: glowBlur, color: glowColor)
    ctx.addPath(path)
    ctx.setStrokeColor(glowColor)
    ctx.setLineWidth(strokeWidth + 4.0)
    ctx.strokePath()
    ctx.restoreGState()

    // Window body fill
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(
        fillGradient,
        start: CGPoint(x: rect.minX, y: rect.minY),
        end: CGPoint(x: rect.maxX, y: rect.maxY),
        options: []
    )
    if drawSheen {
        let sheen = makeGradient([
            (0.0, 0xFFFFFF, tinted ? 0.10 : 0.11),
            (0.45, tinted ? 0xCCCCCC : 0x93C5FD, 0.03),
            (1.0, 0xFFFFFF, 0.0)
        ])
        ctx.drawLinearGradient(
            sheen,
            start: CGPoint(x: rect.minX, y: rect.minY),
            end: CGPoint(x: rect.minX + rect.width * 0.65, y: rect.minY + rect.height * 0.65),
            options: []
        )
    }

    // Titlebar hairline divider
    ctx.setStrokeColor(dividerColor)
    ctx.setLineWidth(3.0)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: rect.minX + 4, y: rect.minY + 86))
    ctx.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.minY + 86))
    ctx.strokePath()

    if drawDots {
        let dotHexes: [UInt32] = tinted ? [0x6E6E6E, 0x8A8A8A, 0xA6A6A6] : [0x475569, 0x52627A, 0x64748B]
        for (idx, hex) in dotHexes.enumerated() {
            let cx = rect.minX + 52.0 + CGFloat(idx) * 40.0
            let cy = rect.minY + 44.0
            ctx.setFillColor(rgba(hex, 1.0))
            ctx.fillEllipse(in: CGRect(x: cx - 12.0, y: cy - 12.0, width: 24.0, height: 24.0))
        }
    }
    ctx.restoreGState()

    // Gradient specular rim stroke
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(strokeWidth)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        strokeGradient,
        start: CGPoint(x: rect.minX, y: rect.minY),
        end: CGPoint(x: rect.maxX, y: rect.maxY),
        options: []
    )
    ctx.restoreGState()
}

func renderIcon(size: Int, variant: IconVariant) -> CGImage {
    let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    let scale = CGFloat(size) / 1024.0
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: scale, y: -scale)
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let tinted = (variant == .tinted)

    // 1. Pure OLED black canvas + subtle ambient center glow
    ctx.setFillColor(rgba(0x000000, 1.0))
    ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))

    let ambient = makeGradient(
        tinted
            ? [(0.0, 0x555555, 0.22), (0.55, 0x222222, 0.08), (1.0, 0x000000, 0.0)]
            : [(0.0, 0x2563EB, 0.30), (0.55, 0x1E3A8A, 0.11), (1.0, 0x000000, 0.0)]
    )
    ctx.drawRadialGradient(
        ambient,
        startCenter: CGPoint(x: 512, y: 492),
        startRadius: 20,
        endCenter: CGPoint(x: 512, y: 492),
        endRadius: 490,
        options: [.drawsAfterEndLocation]
    )

    // 2. Back desktop window (upper-right)
    let backRect = CGRect(x: 260, y: 182, width: 588, height: 476)
    let backFill = makeGradient(
        tinted
            ? [(0.0, 0x262626, 0.90), (1.0, 0x101010, 0.94)]
            : [(0.0, 0x1A2438, 0.90), (1.0, 0x090D16, 0.94)]
    )
    let backStroke = makeGradient(
        tinted
            ? [(0.0, 0xD4D4D4, 0.85), (1.0, 0x737373, 0.55)]
            : [(0.0, 0x93C5FD, 0.84), (0.35, 0x3B82F6, 0.72), (1.0, 0x1D4ED8, 0.48)]
    )
    drawRoundedWindow(
        in: ctx,
        rect: backRect,
        radius: 54,
        fillGradient: backFill,
        strokeGradient: backStroke,
        strokeWidth: 5.5,
        glowColor: tinted ? rgba(0xA3A3A3, 0.30) : rgba(0x2563EB, 0.44),
        glowBlur: 22,
        dividerColor: tinted ? rgba(0xFFFFFF, 0.14) : rgba(0x93C5FD, 0.14),
        drawSheen: false,
        drawDots: false,
        tinted: tinted
    )

    // 3. Soft shadow separating front window from back window
    let frontRect = CGRect(x: 176, y: 302, width: 588, height: 476)
    let frontPath = CGPath(roundedRect: frontRect, cornerWidth: 54, cornerHeight: 54, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: rgba(0x000000, 0.82))
    ctx.addPath(frontPath)
    ctx.setFillColor(rgba(0x070A12, 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // 4. Front desktop window (lower-left)
    let frontFill = makeGradient(
        tinted
            ? [(0.0, 0x222222, 0.96), (0.55, 0x141414, 0.97), (1.0, 0x0B0B0B, 0.98)]
            : [(0.0, 0x172033, 0.96), (0.55, 0x0C111D, 0.97), (1.0, 0x070A12, 0.98)]
    )
    let frontStroke = makeGradient(
        tinted
            ? [(0.0, 0xFFFFFF, 0.96), (0.35, 0xC8C8C8, 0.88), (1.0, 0x8A8A8A, 0.72)]
            : [(0.0, 0xEFF6FF, 0.96), (0.28, 0x60A5FA, 0.92), (1.0, 0x2563EB, 0.78)]
    )
    drawRoundedWindow(
        in: ctx,
        rect: frontRect,
        radius: 54,
        fillGradient: frontFill,
        strokeGradient: frontStroke,
        strokeWidth: 6.0,
        glowColor: tinted ? rgba(0xD4D4D4, 0.35) : rgba(0x3B82F6, 0.52),
        glowBlur: 24,
        dividerColor: tinted ? rgba(0xFFFFFF, 0.18) : rgba(0x93C5FD, 0.18),
        drawSheen: true,
        drawDots: true,
        tinted: tinted
    )

    // 5. Glowing electric cobalt ">" chevron
    let chevron = CGMutablePath()
    chevron.move(to: CGPoint(x: 380, y: 492))
    chevron.addLine(to: CGPoint(x: 472, y: 580))
    chevron.addLine(to: CGPoint(x: 380, y: 668))

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 28, color: tinted ? rgba(0xFFFFFF, 0.45) : rgba(0x2563EB, 0.95))
    ctx.addPath(chevron)
    ctx.setStrokeColor(tinted ? rgba(0xFFFFFF, 1.0) : rgba(0x3B82F6, 1.0))
    ctx.setLineWidth(34.0)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(chevron)
    ctx.setLineWidth(34.0)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let chevronGrad = makeGradient(
        tinted
            ? [(0.0, 0xFFFFFF, 1.0), (1.0, 0xD4D4D4, 1.0)]
            : [(0.0, 0x60A5FA, 1.0), (0.55, 0x3B82F6, 1.0), (1.0, 0x2563EB, 1.0)]
    )
    ctx.drawLinearGradient(
        chevronGrad,
        start: CGPoint(x: 380, y: 492),
        end: CGPoint(x: 472, y: 668),
        options: []
    )
    ctx.restoreGState()

    // Specular inner core on ">"
    ctx.saveGState()
    ctx.addPath(chevron)
    ctx.setStrokeColor(tinted ? rgba(0xFFFFFF, 0.65) : rgba(0x93C5FD, 0.55))
    ctx.setLineWidth(8.0)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()

    // 6. Glowing electric mint "_" underscore
    let barRect = CGRect(x: 498, y: 646, width: 110, height: 32)
    let barPath = CGPath(roundedRect: barRect, cornerWidth: 16, cornerHeight: 16, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 28, color: tinted ? rgba(0xE5E5E5, 0.40) : rgba(0x10B981, 0.95))
    ctx.addPath(barPath)
    ctx.setFillColor(tinted ? rgba(0xE5E5E5, 1.0) : rgba(0x34D399, 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(barPath)
    ctx.clip()
    let mintGrad = makeGradient(
        tinted
            ? [(0.0, 0xD4D4D4, 1.0), (1.0, 0xFFFFFF, 1.0)]
            : [(0.0, 0x34D399, 1.0), (1.0, 0x6EE7B7, 1.0)]
    )
    ctx.drawLinearGradient(
        mintGrad,
        start: CGPoint(x: barRect.minX, y: barRect.midY),
        end: CGPoint(x: barRect.maxX, y: barRect.midY),
        options: []
    )
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    let fm = FileManager.default
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Failed to create PNG destination at \(path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("Failed to write PNG to \(path)")
    }
}

let appIconDir = "\(assetsDir)/AppIcon.appiconset"
let previewDir = "\(assetsDir)/AppIconPreview.imageset"

let full1024 = renderIcon(size: 1024, variant: .fullColor)
let tinted1024 = renderIcon(size: 1024, variant: .tinted)
let preview256 = renderIcon(size: 256, variant: .fullColor)

writePNG(full1024, to: "\(appIconDir)/AppIcon-Light.png")
writePNG(full1024, to: "\(appIconDir)/AppIcon-Dark.png")
writePNG(tinted1024, to: "\(appIconDir)/AppIcon-Tinted.png")
writePNG(preview256, to: "\(previewDir)/AppIconPreview.png")

print("[icon] Generated OLED Obsidian + Cobalt Dark Edition icons in \(assetsDir)")
