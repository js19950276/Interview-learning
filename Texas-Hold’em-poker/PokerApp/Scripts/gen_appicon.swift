// 生成 PokerApp 的 App 图标（iOS 1024 全出血不透明 + macOS 1024 圆角带边距）。
// 用法：swift gen_appicon.swift <输出目录>
// 产物：appicon-ios.png / appicon-macos.png，导入 Assets.xcassets/AppIcon.appiconset

import AppKit

let outDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: ".")

// MARK: - 基础

// NSGraphicsContext(bitmapImageRep:) 不接受无 alpha 的 3 通道 rep，统一走 CGContext：
// iOS 变体用 noneSkipLast（PNG 无 alpha 通道，App Store 要求），macOS 用 premultipliedLast
func makeContext(_ px: Int, opaque: Bool) -> (CGContext, NSGraphicsContext) {
    let bitmapInfo = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue
                            : CGImageAlphaInfo.premultipliedLast.rawValue
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: bitmapInfo)!
    ctx.interpolationQuality = .high
    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    return (ctx, nsCtx)
}

func savePNG(_ ctx: CGContext, _ name: String) throws {
    let image = ctx.makeImage()!
    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try data.write(to: outDir.appendingPathComponent(name))
    print("wrote \(name)")
}

// 深绿绒面径向渐变：中心亮、四周暗，模拟赌桌灯光
func drawFelt(ctx: CGContext, rect: CGRect) {
    let colors = [NSColor(calibratedRed: 0.16, green: 0.46, blue: 0.28, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.04, green: 0.20, blue: 0.12, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors, locations: [0, 1])!
    ctx.drawRadialGradient(grad,
                           startCenter: CGPoint(x: rect.midX, y: rect.midY * 1.1),
                           startRadius: 0,
                           endCenter: CGPoint(x: rect.midX, y: rect.midY),
                           endRadius: rect.width * 0.75,
                           options: [])
}

// MARK: - 扑克牌

struct CardSpec {
    let center: CGPoint      // 牌中心（画布坐标，原点左下）
    let angleDeg: CGFloat    // 逆时针为正
    let suit: String         // "♠" / "♥"
    let color: NSColor
}

func roundedRectPath(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawCard(_ spec: CardSpec, scale: CGFloat) {
    let ctx = NSGraphicsContext.current!.cgContext
    // 牌面尺寸 440×616（2.5:3.5），随 scale 缩放
    let w: CGFloat = 440 * scale, h: CGFloat = 616 * scale
    let r: CGFloat = 52 * scale

    ctx.saveGState()
    // 投影方向统一用世界坐标（先设 shadow 再旋转），两张牌的影子才会朝同一个方向
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 34 * scale,
                  color: NSColor.black.withAlphaComponent(0.40).cgColor)
    let tf = NSAffineTransform()
    tf.translateX(by: spec.center.x, yBy: spec.center.y)
    tf.rotate(byDegrees: spec.angleDeg)
    tf.concat()
    let body = roundedRectPath(NSRect(x: -w / 2, y: -h / 2, width: w, height: h), radius: r)
    NSColor.white.setFill()
    body.fill()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    NSColor(calibratedWhite: 0.82, alpha: 1).setStroke()
    body.lineWidth = 3 * scale
    body.stroke()

    // 角标：A + 花色（牌局部坐标，左上）
    let m: CGFloat = 44 * scale
    let rank = NSAttributedString(string: "A", attributes: [
        .font: NSFont.systemFont(ofSize: 150 * scale, weight: .bold),
        .foregroundColor: spec.color,
    ])
    rank.draw(at: NSPoint(x: -w / 2 + m, y: h / 2 - m - 150 * scale))
    let cornerSuit = NSAttributedString(string: spec.suit, attributes: [
        .font: NSFont.systemFont(ofSize: 110 * scale, weight: .bold),
        .foregroundColor: spec.color,
    ])
    cornerSuit.draw(at: NSPoint(x: -w / 2 + m + 6 * scale, y: h / 2 - m - 150 * scale - 134 * scale))

    // 中央大花色
    let big = NSAttributedString(string: spec.suit, attributes: [
        .font: NSFont.systemFont(ofSize: 300 * scale, weight: .bold),
        .foregroundColor: spec.color,
    ])
    let bs = big.size()
    big.draw(at: NSPoint(x: -bs.width / 2, y: -bs.height / 2 - 30 * scale))

    ctx.restoreGState()
}

// MARK: - 两个变体

let cards: [CardSpec] = [
    .init(center: CGPoint(x: 400, y: 512), angleDeg: -13, suit: "♥", color: .systemRed),
    .init(center: CGPoint(x: 596, y: 486), angleDeg: 9, suit: "♠", color: .black),
]

// iOS：全出血不透明（App Store 要求无 alpha 通道）
do {
    let (ctx, nsCtx) = makeContext(1024, opaque: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    ctx.setAllowsAntialiasing(true)
    drawFelt(ctx: ctx, rect: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    for c in cards { drawCard(c, scale: 1) }
    NSGraphicsContext.restoreGraphicsState()
    try savePNG(ctx, "appicon-ios.png")
}

// macOS：圆角主体 + 边距 + 投影（系统不自动切角，需自带形状；允许 alpha）
do {
    let (ctx, nsCtx) = makeContext(1024, opaque: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    let body = NSRect(x: 92, y: 92, width: 840, height: 840)   // ~82px 边距
    let shape = roundedRectPath(body, radius: 186)             // 近 squircle 圆角

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 36,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
    shape.fill()
    ctx.restoreGState()

    ctx.saveGState()
    shape.addClip()
    // 牌在圆角内要整体缩小居中
    drawFelt(ctx: ctx, rect: body)
    let s: CGFloat = 0.80
    for c in cards {
        drawCard(CardSpec(center: CGPoint(x: (c.center.x - 512) * s + 512,
                                          y: (c.center.y - 512) * s + 512),
                          angleDeg: c.angleDeg, suit: c.suit, color: c.color),
                 scale: s)
    }
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    try savePNG(ctx, "appicon-macos.png")
}
