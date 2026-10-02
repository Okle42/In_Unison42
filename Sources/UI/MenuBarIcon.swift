// MenuBarIcon.swift — 選單列圖示（第 B 輪：有裝置在等校正時加提示點）
//
// 做法：模式的 SF Symbol（hifispeaker.2／film／gamecontroller…）右上角挖一圈透明、再畫一個實心小點（像 SF Symbols 的 .badge 變體）。
// 整張仍是 template image：選單列自動套淺色／深色、按下反白都正確（不自己決定顏色，避免在某種選單列背景上看不見）。
// 點開面板後頂部顯示原因與「立即校正」（Panel.swift AttentionBanner）。
import AppKit
import SwiftUI

@MainActor
enum MenuBarIcon {
    private static var cache: [String: NSImage] = [:]

    /// symbol：AppState.menuBarSymbol；badge：AppState.menuBarNeedsAttention
    static func image(symbol: String, badge: Bool) -> NSImage {
        let key = "\(symbol)|\(badge)"
        if let img = cache[key] { return img }
        let img = make(symbol: symbol, badge: badge)
        cache[key] = img
        return img
    }

    static func make(symbol: String, badge: Bool) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "In_Unison42")?.withSymbolConfiguration(cfg)
                ?? NSImage(systemSymbolName: "hifispeaker.2", accessibilityDescription: "In_Unison42") else { return NSImage() }
        guard badge else { base.isTemplate = true; return base }
        let dot: CGFloat = 6, ring: CGFloat = 1.5
        // 右上角留一點空間給提示點（點的中心在原圖右上角附近，稍微超出）
        let size = NSSize(width: base.size.width + dot / 2, height: base.size.height + dot / 4)
        let img = NSImage(size: size, flipped: false) { rect in
            base.draw(in: NSRect(x: 0, y: 0, width: base.size.width, height: base.size.height),
                      from: .zero, operation: .sourceOver, fraction: 1)
            let c = NSPoint(x: rect.maxX - dot / 2, y: rect.maxY - dot / 2)
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            // 先挖掉一圈（點和圖示之間留縫，避免黏在一起看不出是點）
            ctx.setBlendMode(.clear)
            let r0 = dot / 2 + ring
            ctx.fillEllipse(in: CGRect(x: c.x - r0, y: c.y - r0, width: 2 * r0, height: 2 * r0))
            ctx.setBlendMode(.normal)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - dot / 2, y: c.y - dot / 2, width: dot, height: dot))
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "In_Unison42：有裝置需要校正"
        return img
    }

    /// 離屏輸出（自測／截圖用）：template 圖以指定顏色畫在指定背景上
    static func renderPNG(symbol: String, badge: Bool, dark: Bool, to url: URL, scale: CGFloat = 4) -> Bool {
        let img = make(symbol: symbol, badge: badge)
        let w = Int((img.size.width + 8) * scale), h = Int((img.size.height + 8) * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        // template：用 alpha 當遮罩，塗上選單列文字色
        let tinted = NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r)
            (dark ? NSColor.white : NSColor.black).set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: 4 * scale, y: 4 * scale, width: img.size.width * scale, height: img.size.height * scale))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// 提示點那一塊有沒有畫出來（自測：右上角中心像素不透明、挖縫處透明）
    static func badgePixelsOK(symbol: String) -> Bool {
        let img = make(symbol: symbol, badge: true)
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: NSAffineTransform()]) else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        let sx = CGFloat(rep.pixelsWide) / img.size.width, sy = CGFloat(rep.pixelsHigh) / img.size.height
        func alpha(_ x: CGFloat, _ yFromTop: CGFloat) -> CGFloat {
            rep.colorAt(x: Int(x * sx), y: Int(yFromTop * sy))?.alphaComponent ?? 0
        }
        let dot: CGFloat = 6
        let cx = img.size.width - dot / 2, cyTop = dot / 2
        return alpha(cx, cyTop) > 0.9 && alpha(cx - dot / 2 - 0.75, cyTop) < 0.1
    }
}
