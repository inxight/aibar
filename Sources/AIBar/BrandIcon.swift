import AppKit

/// 미리 변환해 둔 벡터 데이터로 로고 이미지를 만든다.
enum BrandIcon {
    /// Claude 브랜드 주황.
    static let claudeOrange = NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)

    static func path(for provider: Provider) -> [BrandPathElement] {
        switch provider {
        case .claude: return BrandPaths.claude
        case .codex: return BrandPaths.openai
        }
    }

    /// 지정한 한 변 크기의 정사각 이미지를 그린다.
    ///
    /// - Parameter template: true 면 색을 비워 둬 메뉴바가 라이트/다크에 맞게 칠하게 한다.
    static func image(for provider: Provider, size: CGFloat, color: NSColor, template: Bool = false) -> NSImage {
        let elements = path(for: provider)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }

            let scale = size / BrandPaths.viewBox
            // SVG 는 y 가 아래로 증가하고 CoreGraphics 는 위로 증가한다. 뒤집어서 맞춘다.
            context.translateBy(x: 0, y: size)
            context.scaleBy(x: scale, y: -scale)

            let cgPath = CGMutablePath()
            for element in elements {
                switch element {
                case .move(let x, let y):
                    cgPath.move(to: CGPoint(x: x, y: y))
                case .line(let x, let y):
                    cgPath.addLine(to: CGPoint(x: x, y: y))
                case .curve(let c1x, let c1y, let c2x, let c2y, let x, let y):
                    cgPath.addCurve(
                        to: CGPoint(x: x, y: y),
                        control1: CGPoint(x: c1x, y: c1y),
                        control2: CGPoint(x: c2x, y: c2y)
                    )
                case .close:
                    cgPath.closeSubpath()
                }
            }

            context.addPath(cgPath)
            context.setFillColor(color.cgColor)
            // 원본 SVG 가 겹치는 서브패스로 형태를 만들므로 nonZero 로 채운다.
            context.fillPath(using: .winding)
            return true
        }
        image.isTemplate = template
        return image
    }
}
