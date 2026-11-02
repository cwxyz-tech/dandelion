// Dandelion - screenshot markup: the marks (arrows, boxes, highlights, text, blur) and how they're drawn.
// No windows here, so it can be tested on its own.
// MIT License. See LICENSE.

import AppKit
import CoreImage

enum MarkKind: String, CaseIterable, Identifiable {
    case arrow, box, highlight, text, blur
    var id: String { rawValue }
    var title: String {
        switch self {
        case .arrow: return "Arrow"
        case .box: return "Box"
        case .highlight: return "Highlight"
        case .text: return "Text"
        case .blur: return "Blur"
        }
    }
    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .box: return "rectangle"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .blur: return "square.grid.3x3.fill"
        }
    }
}

struct Mark: Identifiable, Equatable {
    let id = UUID()
    var kind: MarkKind
    /// Image pixels, top-left origin.
    var a: CGPoint
    var b: CGPoint
    var color: Int
    var text = ""

    var rect: CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

enum MarkPalette {
    static let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .black, .white]
}

/// Draws markup into a top-left-origin context whose units are image pixels. Used for the screen and the saved file,
/// so what you see is exactly what gets saved.
enum MarkDrawer {
    static let ci = CIContext()

    static func lineWidth(_ imageSize: CGSize) -> CGFloat { max(4, max(imageSize.width, imageSize.height) / 260) }

    static func draw(_ marks: [Mark], in ctx: CGContext, imageSize: CGSize, pixelated: [UUID: CGImage]) {
        let w = lineWidth(imageSize)
        for m in marks {
            let color = MarkPalette.colors[max(0, min(m.color, MarkPalette.colors.count - 1))]
            ctx.saveGState()
            switch m.kind {
            case .arrow:
                drawArrow(m.a, m.b, width: w, color: color.cgColor, in: ctx)
            case .box:
                ctx.setShadow(offset: .zero, blur: w * 1.2, color: NSColor.black.withAlphaComponent(0.3).cgColor)
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(w)
                ctx.addPath(CGPath(roundedRect: m.rect, cornerWidth: w * 1.5, cornerHeight: w * 1.5, transform: nil))
                ctx.strokePath()
            case .highlight:
                ctx.setBlendMode(.multiply)
                ctx.setFillColor(color.withAlphaComponent(0.4).cgColor)
                ctx.fill(m.rect)
            case .text:
                drawText(m.text, at: m.a, color: color, size: max(18, max(imageSize.width, imageSize.height) / 45), in: ctx)
            case .blur:
                if let piece = pixelated[m.id] {
                    // CGContext draws images bottom-up; flip just for this piece
                    ctx.translateBy(x: m.rect.minX, y: m.rect.maxY)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(piece, in: CGRect(origin: .zero, size: m.rect.size))
                } else {
                    ctx.setFillColor(NSColor.gray.withAlphaComponent(0.35).cgColor)
                    ctx.fill(m.rect)
                    ctx.setStrokeColor(NSColor.white.cgColor)
                    ctx.setLineWidth(max(1.5, w / 3))
                    ctx.setLineDash(phase: 0, lengths: [w, w])
                    ctx.stroke(m.rect)
                }
            }
            ctx.restoreGState()
        }
    }

    private static func drawArrow(_ a: CGPoint, _ b: CGPoint, width w: CGFloat, color: CGColor, in ctx: CGContext) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(1, hypot(dx, dy))
        let ux = dx / len, uy = dy / len
        let head = min(len * 0.6, w * 4.5)
        let half = head * 0.62
        let base = CGPoint(x: b.x - ux * head, y: b.y - uy * head)
        ctx.setShadow(offset: .zero, blur: w * 1.2, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        ctx.setLineCap(.round)
        ctx.setLineWidth(w)
        ctx.move(to: a)
        ctx.addLine(to: CGPoint(x: base.x + ux * w * 0.5, y: base.y + uy * w * 0.5))
        ctx.strokePath()
        ctx.move(to: b)
        ctx.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
        ctx.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
        ctx.closePath()
        ctx.fillPath()
    }

    private static func drawText(_ text: String, at p: CGPoint, color: NSColor, size: CGFloat, in ctx: CGContext) {
        guard !text.isEmpty else { return }
        let light = color == .white || color == .systemYellow
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: light ? NSColor.black : NSColor.white,
        ]
        let str = text as NSString
        let s = str.size(withAttributes: attrs)
        let pad = size * 0.35
        let box = CGRect(x: p.x, y: p.y, width: s.width + pad * 2, height: s.height + pad * 1.2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ctx.setShadow(offset: .zero, blur: size * 0.3, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        color.setFill()
        NSBezierPath(roundedRect: box, xRadius: size * 0.3, yRadius: size * 0.3).fill()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        str.draw(at: CGPoint(x: p.x + pad, y: p.y + pad * 0.6), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The image with its marks, at full resolution.
    static func render(_ image: CGImage, marks: [Mark], pixelated: [UUID: CGImage]) -> CGImage? {
        let w = image.width, h = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        draw(marks, in: ctx, imageSize: CGSize(width: w, height: h), pixelated: pixelated)
        return ctx.makeImage()
    }

    /// The pixelated stand-in for a blurred area (rect in image pixels, top-left origin).
    static func pixelate(_ image: CGImage, rect: CGRect) -> CGImage? {
        let r = CGRect(x: rect.minX, y: CGFloat(image.height) - rect.maxY, width: rect.width, height: rect.height).integral
        guard r.width >= 2, r.height >= 2, let f = CIFilter(name: "CIPixellate") else { return nil }
        let block = max(10, max(r.width, r.height) / 12)
        // blur first, so each block is the average of its area: pixellating alone keeps one real pixel per block,
        // which can leave text readable
        let mixed = CIImage(cgImage: image).clampedToExtent().applyingGaussianBlur(sigma: block * 0.7)
        f.setValue(mixed, forKey: kCIInputImageKey)
        f.setValue(block, forKey: kCIInputScaleKey)
        f.setValue(CIVector(x: r.midX, y: r.midY), forKey: kCIInputCenterKey)
        guard let out = f.outputImage?.cropped(to: r) else { return nil }
        return ci.createCGImage(out, from: r)
    }
}

/// One open screenshot being marked up.
