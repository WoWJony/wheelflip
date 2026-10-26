import AppKit
import Foundation

// Render an illustrated feature tour with real UI fixtures and the app's pure
// scroll policy. No event tap, desktop recording, or live settings are involved.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let fm = FileManager.default
let fps = 20
let duration = 15

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
let ink = color(0x252C28)
let muted = color(0x717A72)
let paper = color(0xF6F5F0)
let red = color(0xBD4D40)
let green = color(0x367B65)
let line = color(0xE1E4DC)

func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat,
          size: CGFloat, weight: NSFont.Weight = .regular, fill: NSColor = ink,
          height: CGFloat = 90) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.lineSpacing = 4
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: fill, .paragraphStyle: paragraph,
    ]
    NSAttributedString(string: value, attributes: attributes)
        .draw(in: NSRect(x: x, y: y, width: width, height: height))
}

func box(_ rect: NSRect, radius: CGFloat = 20, fill: NSColor = .white,
         stroke: NSColor? = nil) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    if let stroke {
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

func loadImage(_ path: String) -> NSImage {
    guard let image = NSImage(contentsOf: root.appendingPathComponent(path)) else {
        fatalError("Missing artwork: \(path)")
    }
    return image
}
let icon = loadImage("app/WheelFlip/Resources/Assets.xcassets/AppIconV2.appiconset/icon_512x512.png")
let panels = ["en": loadImage("docs/assets/panel-en.png"), "zh": loadImage("docs/assets/panel-zh.png")]
let ruleLists = ["en": loadImage("docs/assets/rules-en.png"), "zh": loadImage("docs/assets/rules-zh.png")]

func image(_ image: NSImage, in rect: NSRect) {
    image.draw(in: rect, from: .zero, operation: .sourceOver,
               fraction: 1, respectFlipped: true, hints: nil)
}

func pill(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat,
          fill: NSColor = color(0xE9EDE5), foreground: NSColor = muted) {
    box(NSRect(x: x, y: y, width: width, height: 36), radius: 18, fill: fill)
    text(value, x + 14, y + 7, width - 28, size: 16, weight: .medium, fill: foreground, height: 24)
}

func panel(_ lang: String, x: CGFloat, y: CGFloat, width: CGFloat) {
    let shot = panels[lang]!
    let height = width * shot.size.height / shot.size.width
    box(NSRect(x: x - 10, y: y - 10, width: width + 20, height: height + 20),
        radius: 24, fill: color(0xDDE2D9))
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height),
                 xRadius: 16, yRadius: 16).addClip()
    image(shot, in: NSRect(x: x, y: y, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
}

func canvas(width: Int, height: Int, destination: URL, draw: () -> Void) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    context.cgContext.translateBy(x: 0, y: CGFloat(height))
    context.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    NSGraphicsContext.current?.imageInterpolation = .high
    paper.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    draw()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
}

func cover(_ lang: String) throws {
    let zh = lang == "zh"
    try canvas(width: 1280, height: 640,
               destination: output.appendingPathComponent("social-preview-\(lang).png")) {
        box(NSRect(x: 736, y: 0, width: 544, height: 640), radius: 0, fill: color(0xE9EDE5))
        image(icon, in: NSRect(x: 48, y: 40, width: 90, height: 90))
        text("WheelFlip", 148, 63, 450, size: 36, weight: .bold)
        text(zh ? "鼠标滚轮，" : "Mouse wheel,", 64, 180, 650, size: 67, weight: .bold)
        text(zh ? "按你的习惯。" : "your way.", 64, 263, 650, size: 67, weight: .bold, fill: red)
        text(zh ? "触控板保持自然滚动。\n每个应用，可以有自己的方向。" :
             "Keep your trackpad natural.\nChoose a direction for each app.",
             68, 377, 620, size: 27, height: 96)
        pill("macOS 14+", x: 68, y: 505, width: 128)
        pill(zh ? "免费 · MIT 开源" : "Free & open source", x: 208, y: 505, width: zh ? 174 : 202)
        text("github.com/WoWJony/wheelflip", 68, 575, 650, size: 23, weight: .medium, fill: muted)
        panel(lang, x: 787, y: 112, width: 422)
        text(zh ? "原生菜单栏应用 · 无需账号" : "Native menu bar app · No account",
             787, 552, 460, size: 20, fill: muted)
    }
}

func arrow(x: CGFloat, y: CGFloat, down: Bool, fill: NSColor) {
    let sign: CGFloat = down ? 1 : -1
    let path = NSBezierPath()
    path.lineWidth = 5
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: NSPoint(x: x, y: y - sign * 17))
    path.line(to: NSPoint(x: x, y: y + sign * 17))
    path.move(to: NSPoint(x: x - 10, y: y + sign * 7))
    path.line(to: NSPoint(x: x, y: y + sign * 17))
    path.line(to: NSPoint(x: x + 10, y: y + sign * 7))
    fill.setStroke()
    path.stroke()
}

func policyRow(name: String, symbol: String, y: CGFloat, continuous: Bool = false,
               override: ScrollRuleMode? = nil, time: Double, lang: String) {
    let zh = lang == "zh"
    let decision = FlipPolicy.decide(defaultFlip: true, override: override,
                                     eventKind: continuous ? .continuous : .discrete)
    let input = ScrollFields(isContinuous: continuous, deltaAxis1: 1, deltaAxis2: 0,
                             pointDeltaAxis1: 1, pointDeltaAxis2: 0,
                             fixedPtDeltaAxis1: 1, fixedPtDeltaAxis2: 0)
    let result = decision.flips ? ScrollFlip.flipped(input)! : input
    let tint = decision.flips ? red : green
    box(NSRect(x: 56, y: y, width: 586, height: 108), fill: .white, stroke: line)
    box(NSRect(x: 76, y: y + 26, width: 56, height: 56), radius: 16,
        fill: tint.withAlphaComponent(0.08))
    if let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 28, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        image(symbolImage.withSymbolConfiguration(configuration)!,
              in: NSRect(x: 89, y: y + 39, width: 30, height: 30))
    }
    text(name, 150, y + 23, 210, size: 25, weight: .semibold)
    text(decision.flips ? (zh ? "反转" : "Reverse") : (zh ? "保持原方向" : "Keep direction"),
         150, y + 59, 230, size: 18, fill: tint)
    text(zh ? "输入" : "Input", 369, y + 15, 80, size: 14, fill: muted)
    text(zh ? "输出" : "Output", 502, y + 15, 90, size: 14, fill: muted)
    let movement = CGFloat(sin(time * 3.3)) * 7
    arrow(x: 390, y: y + 65 + movement, down: true, fill: color(0xA9B0A8))
    text("→", 438, y + 44, 50, size: 26, fill: muted)
    arrow(x: 530, y: y + 65 + (decision.flips ? -movement : movement),
          down: result.deltaAxis1 > 0, fill: tint)
}

func frame(_ index: Int, lang: String, directory: URL) throws {
    let time = Double(index) / Double(fps)
    let chapter = min(2, Int(time / 5))
    let zh = lang == "zh"
    try canvas(width: 1280, height: 720,
               destination: directory.appendingPathComponent(String(format: "%04d.png", index))) {
        image(icon, in: NSRect(x: 44, y: 23, width: 70, height: 70))
        text("WheelFlip", 121, 43, 300, size: 29, weight: .bold)
        pill(zh ? "15 秒功能演示" : "15-second feature tour", x: 958, y: 39, width: 266)
        let headings = zh ? ["鼠标滚轮，按你的习惯。", "每个应用，可以有自己的方向。", "一个小工具，解决一个小烦恼。"] :
            ["Mouse wheel reversed.", "A rule for every app.", "Small app. Ready to try."]
        let subtitles = zh ? ["触控板依然保持自然滚动。", "预览保持原方向，终端反转。", "免费开源，下载后就能开始安装。"] :
            ["Your trackpad keeps its direction.", "Keep Preview. Reverse Terminal.", "Free and open source. No Xcode needed."]
        text(headings[chapter], 56, 140, 700, size: zh ? 38 : 45, weight: .bold)
        text(subtitles[chapter], 58, 206, 660, size: 23, fill: muted)

        if chapter == 0 {
            policyRow(name: zh ? "普通鼠标" : "Mouse wheel", symbol: "computermouse", y: 290,
                      time: time, lang: lang)
            policyRow(name: zh ? "触控板" : "Trackpad", symbol: "rectangle.and.hand.point.up.left", y: 416,
                      continuous: true, time: time, lang: lang)
            panel(lang, x: 756, y: 155, width: 440)
            text(zh ? "实际界面 · 演示应用数据" : "Actual UI · Sample app data", 756, 602, 460,
                 size: 17, fill: muted)
        } else if chapter == 1 {
            policyRow(name: "Preview", symbol: "doc.richtext", y: 290,
                      override: .forceOff, time: time, lang: lang)
            policyRow(name: "Terminal", symbol: "terminal", y: 416,
                      override: .forceOn, time: time, lang: lang)
            let shot = ruleLists[lang]!
            box(NSRect(x: 684, y: 280, width: 548, height: 183), radius: 18,
                fill: .white, stroke: line)
            // A clipped viewport shows the real list's two configured rows.
            // The source screenshot is retained unchanged in docs/assets/.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: NSRect(x: 690, y: 286, width: 536, height: 171),
                         xRadius: 13, yRadius: 13).addClip()
            image(shot, in: NSRect(x: 690, y: 286, width: 536,
                                  height: 536 * shot.size.height / shot.size.width))
            NSGraphicsContext.restoreGraphicsState()
            text(zh ? "应用规则列表 · 实际界面局部" : "App rules · Actual UI detail", 702, 492, 510,
                 size: 19, fill: muted)
            text(zh ? "规则跟随实际接收滚动的应用。" : "Rules follow the app receiving the scroll.",
                 702, 529, 510, size: 19, fill: muted)
        } else {
            image(icon, in: NSRect(x: 43, y: 283, width: 148, height: 148))
            box(NSRect(x: 218, y: 312, width: 360, height: 75), radius: 20, fill: red)
            text(zh ? "下载 · 免费使用" : "Download free", 250, 330, 310, size: 28, weight: .semibold, fill: .white)
            text("github.com/WoWJony/wheelflip", 58, 459, 680, size: 28, weight: .medium)
            text(zh ? "macOS 14+ · Apple 芯片 + Intel" : "macOS 14+ · Apple silicon + Intel", 58, 512, 660,
                 size: 22, fill: muted)
            text(zh ? "首版尚未经过 Apple 公证，安装说明已附上。" : "First release is not Apple-notarized. Setup guide included.",
                 58, 557, 680, size: 17, fill: muted)
            panel(lang, x: 790, y: 175, width: 402)
            text(zh ? "MIT 开源 · 本机运行 · 无需账号" : "MIT license · Runs locally · No account", 771, 589, 460,
                 size: 18, fill: muted)
        }
        text(zh ? "滚动效果为示意；规则结果来自应用实际逻辑。" : "Illustrated motion · Direction calculated by WheelFlip's actual rule logic",
             58, 657, 1120, size: 15, fill: muted, height: 25)
        box(NSRect(x: 56, y: 694, width: 1168, height: 4), radius: 2, fill: line)
        box(NSRect(x: 56, y: 694, width: max(4, 1168 * CGFloat(time / 15)), height: 4), radius: 2, fill: red)
    }
}

try fm.createDirectory(at: output, withIntermediateDirectories: true)
for lang in ["en", "zh"] {
    try cover(lang)
    let directory = output.appendingPathComponent("frames-\(lang)")
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    for index in 0..<(fps * duration) {
        try autoreleasepool { try frame(index, lang: lang, directory: directory) }
    }
    print("Rendered \(lang): 15 seconds at \(fps) fps")
}
