// Generates the project's own (non-TASCAM) app icon: Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
// Draws a rounded-square tile with a control knob and a small level meter,
// renders every size iconutil needs, and packs them into an .icns.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
let output = root.appendingPathComponent("Resources/AppIcon.icns")

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Tile: macOS-style rounded square with margin, dark slate gradient.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.23, blue: 0.28, alpha: 1),
               ending: NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1))!
        .draw(in: tilePath, angle: -90)

    // Knob: metallic disc with an amber position indicator.
    let knobCenter = NSPoint(x: 430 * s, y: 512 * s)
    let knobR = 210 * s
    let knob = NSBezierPath(ovalIn: NSRect(x: knobCenter.x - knobR, y: knobCenter.y - knobR,
                                           width: knobR * 2, height: knobR * 2))
    NSGradient(starting: NSColor(calibratedWhite: 0.92, alpha: 1),
               ending: NSColor(calibratedWhite: 0.55, alpha: 1))!.draw(in: knob, angle: -60)
    NSColor(calibratedWhite: 0.25, alpha: 1).setStroke()
    knob.lineWidth = 10 * s
    knob.stroke()

    let angle = CGFloat.pi * 0.75          // indicator pointing to upper-left
    let indicator = NSBezierPath()
    indicator.move(to: NSPoint(x: knobCenter.x + cos(angle) * knobR * 0.25,
                               y: knobCenter.y + sin(angle) * knobR * 0.25))
    indicator.line(to: NSPoint(x: knobCenter.x + cos(angle) * knobR * 0.85,
                               y: knobCenter.y + sin(angle) * knobR * 0.85))
    indicator.lineWidth = 34 * s
    indicator.lineCapStyle = .round
    NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.10, alpha: 1).setStroke()
    indicator.stroke()

    // Scale dots around the knob.
    NSColor(calibratedWhite: 0.75, alpha: 1).setFill()
    for i in 0...8 {
        let a = CGFloat.pi * (1.25 - 1.5 * CGFloat(i) / 8)
        let r = knobR + 48 * s
        let p = NSPoint(x: knobCenter.x + cos(a) * r, y: knobCenter.y + sin(a) * r)
        NSBezierPath(ovalIn: NSRect(x: p.x - 11 * s, y: p.y - 11 * s, width: 22 * s, height: 22 * s)).fill()
    }

    // Level meter: five segments, green to amber to red.
    let colors: [NSColor] = [.systemGreen, .systemGreen, .systemGreen, .systemOrange, .systemRed]
    for (i, c) in colors.enumerated() {
        let seg = NSRect(x: 735 * s, y: (300 + CGFloat(i) * 88) * s, width: 90 * s, height: 64 * s)
        c.withAlphaComponent(i < 4 ? 1 : 0.35).setFill()
        NSBezierPath(roundedRect: seg, xRadius: 12 * s, yRadius: 12 * s).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = draw(size: px).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
