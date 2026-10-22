import AppKit
import CoreGraphics

// ============================================================================
// 生成 App 图标（1024）与菜单栏 template 图标
// 设计：两枚叠放的白色键帽，一枚「中」一枚「A」，表达"在两种输入法之间切换"
// ============================================================================

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func savePNG(_ rep: NSBitmapImageRep, to path: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

func newRep(_ px: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil,
                     pixelsWide: px, pixelsHigh: px,
                     bitsPerSample: 8, samplesPerPixel: 4,
                     hasAlpha: true, isPlanar: false,
                     colorSpaceName: .deviceRGB,
                     bytesPerRow: 0, bitsPerPixel: 0)!
}

func centeredText(_ text: String, font: NSFont, color: NSColor, in rect: NSRect, dy: CGFloat = 0) {
    let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let size = (text as NSString).size(withAttributes: attr)
    let origin = NSPoint(x: rect.midX - size.width / 2,
                         y: rect.midY - size.height / 2 + dy)
    (text as NSString).draw(at: origin, withAttributes: attr)
}

func cjkFont(_ size: CGFloat) -> NSFont {
    NSFont(name: "PingFangSC-Semibold", size: size)
        ?? NSFont(name: "HiraginoSans-W6", size: size)
        ?? .boldSystemFont(ofSize: size)
}

func latinFont(_ size: CGFloat) -> NSFont {
    NSFont(name: "HelveticaNeue-Bold", size: size)
        ?? .boldSystemFont(ofSize: size)
}

// MARK: - App 图标

func renderAppIcon(px: Int) -> NSBitmapImageRep {
    let rep = newRep(px)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.shouldAntialias = true

    let S = CGFloat(px)
    let scale = S / 1024.0

    // 背景圆角方块 + 渐变
    let bgRect = NSRect(x: 0, y: 0, width: S, height: S)
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: 230 * scale, yRadius: 230 * scale)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.38, green: 0.31, blue: 0.90, alpha: 1.0),
        NSColor(srgbRed: 0.24, green: 0.52, blue: 0.99, alpha: 1.0),
    ])!
    gradient.draw(in: bg, angle: -65)

    // 顶部斜向柔光（用渐变叠加，避免硬边）
    let sheen = bg
    sheen.addClip()
    let sheenGradient = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.16),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    sheenGradient.draw(in: NSRect(x: 0, y: S * 0.35, width: S, height: S * 0.65), angle: -90)

    func keycap(_ rect: NSRect, radius: CGFloat, fill: NSColor,
                text: String, textColor: NSColor, font: NSFont, shadow: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        if shadow {
            let sh = NSShadow()
            sh.shadowColor = NSColor.black.withAlphaComponent(0.28)
            sh.shadowBlurRadius = 44 * scale
            sh.shadowOffset = NSSize(width: 0, height: -14 * scale)
            sh.set()
        }
        fill.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        // 键帽内高光边
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor.white.withAlphaComponent(shadow ? 0.35 : 0.55).setStroke()
        let inner = NSBezierPath(roundedRect: rect.insetBy(dx: 3 * scale, dy: 3 * scale),
                                 xRadius: radius - 3 * scale, yRadius: radius - 3 * scale)
        inner.lineWidth = 3 * scale
        inner.stroke()
        NSGraphicsContext.restoreGraphicsState()

        centeredText(text, font: font, color: textColor, in: rect, dy: -6 * scale)
    }

    // 后键帽：A（半透明白）
    let backRect = NSRect(x: 400 * scale, y: 448 * scale, width: 380 * scale, height: 380 * scale)
    keycap(backRect, radius: 92 * scale,
           fill: NSColor.white.withAlphaComponent(0.26),
           text: "A", textColor: NSColor.white.withAlphaComponent(0.92),
           font: latinFont(196 * scale), shadow: false)

    // 前键帽：中（实心白）
    let frontRect = NSRect(x: 232 * scale, y: 252 * scale, width: 380 * scale, height: 380 * scale)
    keycap(frontRect, radius: 92 * scale,
           fill: NSColor.white,
           text: "中", textColor: NSColor(srgbRed: 0.27, green: 0.36, blue: 0.86, alpha: 1.0),
           font: cjkFont(208 * scale), shadow: true)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - 菜单栏 template 图标（双向箭头）

func renderMenuBar(px: Int) -> NSBitmapImageRep {
    let rep = newRep(px)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.shouldAntialias = true

    let S = CGFloat(px)
    let u = S / 18.0            // 以 18pt 为设计基准
    NSColor.black.setFill()
    NSColor.black.setStroke()

    func arrow(from: CGPoint, to: CGPoint, width: CGFloat, head: CGFloat) {
        let line = NSBezierPath()
        line.lineWidth = width
        line.lineCapStyle = .round
        line.lineJoinStyle = .round
        line.move(to: from)
        line.line(to: to)
        line.stroke()

        // 箭头方向按实际走向判断，避免倒钩画反
        let dx: CGFloat = (to.x > from.x) ? 1 : -1
        let h = NSBezierPath()
        h.lineWidth = width
        h.lineCapStyle = .round
        h.lineJoinStyle = .round
        h.move(to: CGPoint(x: to.x - dx * head, y: to.y + head * 0.82))
        h.line(to: to)
        h.line(to: CGPoint(x: to.x - dx * head, y: to.y - head * 0.82))
        h.stroke()
    }

    arrow(from: CGPoint(x: 2.8 * u, y: 6.7 * u),
          to: CGPoint(x: 15.2 * u, y: 6.7 * u),
          width: 1.8 * u, head: 2.3 * u)
    arrow(from: CGPoint(x: 15.2 * u, y: 11.3 * u),
          to: CGPoint(x: 2.8 * u, y: 11.3 * u),
          width: 1.8 * u, head: 2.3 * u)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

savePNG(renderAppIcon(px: 1024), to: outDir + "/icon_1024.png")
savePNG(renderMenuBar(px: 18), to: outDir + "/MenuBarIcon.png")
savePNG(renderMenuBar(px: 36), to: outDir + "/MenuBarIcon@2x.png")
