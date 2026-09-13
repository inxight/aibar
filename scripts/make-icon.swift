#!/usr/bin/env swift
// 앱 아이콘을 그려 Resources/AppIcon.icns 로 만든다.
//
//   swift scripts/make-icon.swift
//
// 디자인: 어두운 squircle 바탕에 사용량 게이지 세 줄.
// 이 앱이 메뉴바에 숫자 세 개를 보여준다는 것을 그대로 그림으로 옮겼다.

import AppKit

// MARK: - 색

let backgroundTop = NSColor(srgbRed: 0.22, green: 0.21, blue: 0.24, alpha: 1)
let backgroundBottom = NSColor(srgbRed: 0.09, green: 0.08, blue: 0.10, alpha: 1)
let claudeOrange = NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)

/// 게이지 세 줄. (채운 비율, 색)
let gauges: [(fill: CGFloat, color: NSColor)] = [
    (0.35, claudeOrange),
    (0.90, claudeOrange.blended(withFraction: 0.25, of: .white) ?? claudeOrange),
    (0.65, NSColor(white: 0.92, alpha: 1)),
]

// MARK: - 그리기

func drawIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        guard let context = NSGraphicsContext.current?.cgContext else { return true }

        // 아이콘 실제 그림은 캔버스 전체를 채우지 않는다. macOS 관례대로 약간 여백을 둔다.
        let inset = size * 0.055
        let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        // Apple 아이콘에 가까운 모서리 비율.
        let radius = plate.width * 0.2237

        let platePath = CGPath(
            roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil
        )

        context.saveGState()
        context.addPath(platePath)
        context.clip()
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [backgroundTop.cgColor, backgroundBottom.cgColor] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: plate.minX, y: plate.maxY),
                end: CGPoint(x: plate.maxX, y: plate.minY),
                options: []
            )
        }
        context.restoreGState()

        // 게이지 — 트랙 위에 채운 부분을 얹는다. 작은 크기에서도 뭉개지지 않게 굵게 잡는다.
        let barHeight = plate.height * 0.115
        let spacing = plate.height * 0.085
        let totalHeight = barHeight * CGFloat(gauges.count) + spacing * CGFloat(gauges.count - 1)
        let leftInset = plate.width * 0.16
        let trackWidth = plate.width - leftInset * 2
        var y = plate.midY + totalHeight / 2 - barHeight

        for gauge in gauges {
            let track = CGRect(x: plate.minX + leftInset, y: y, width: trackWidth, height: barHeight)
            context.addPath(CGPath(
                roundedRect: track,
                cornerWidth: barHeight / 2, cornerHeight: barHeight / 2,
                transform: nil
            ))
            context.setFillColor(NSColor(white: 1, alpha: 0.16).cgColor)
            context.fillPath()

            // 채운 부분이 모서리보다 짧아지면 모양이 깨지므로 최소 폭을 둔다.
            let filledWidth = max(barHeight, trackWidth * gauge.fill)
            let filled = CGRect(x: track.minX, y: y, width: filledWidth, height: barHeight)
            context.addPath(CGPath(
                roundedRect: filled,
                cornerWidth: barHeight / 2, cornerHeight: barHeight / 2,
                transform: nil
            ))
            context.setFillColor(gauge.color.cgColor)
            context.fillPath()

            y -= barHeight + spacing
        }

        return true
    }
}

// MARK: - 파일로 굽기

func png(from image: NSImage, pixels: Int) -> Data? {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    representation.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    drawIcon(size: CGFloat(pixels)).draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels)
    )
    NSGraphicsContext.restoreGraphicsState()

    return representation.representation(using: .png, properties: [:])
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// icns 가 요구하는 크기 묶음.
let entries: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for entry in entries {
    guard let data = png(from: drawIcon(size: CGFloat(entry.pixels)), pixels: entry.pixels) else {
        FileHandle.standardError.write(Data("\(entry.name) 생성 실패\n".utf8))
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent("\(entry.name).png"))
}

let resources = root.appendingPathComponent("Resources")
try? FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = [
    "-c", "icns", iconset.path,
    "-o", resources.appendingPathComponent("AppIcon.icns").path,
]
try convert.run()
convert.waitUntilExit()

guard convert.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil 실패\n".utf8))
    exit(1)
}
print("완료: Resources/AppIcon.icns")
