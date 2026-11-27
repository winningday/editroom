import AppKit
import CoreImage

/// One caption as it's drawn: its words, which one is lit (the one being said), and when. Drawn in the
/// output's own frame, after any crop to another shape, so captions stay whole and in place on a
/// vertical or square export of a wide sequence.
struct CaptionLayer {
    let start: Double
    let end: Double
    let words: [String]
    let lit: Int?
    let style: CaptionStyle

    /// The caption placed on a frame of this size.
    func image(output: CGSize) -> CIImage? {
        CaptionRenderer.image(words: words, lit: lit, style: style, output: output)
    }
}

enum CaptionRenderer {
    /// Each caption, split by word when the word being said lights up.
    static func layers(_ blocks: [CaptionBlock], style: CaptionStyle) -> [CaptionLayer] {
        var out: [CaptionLayer] = []
        for b in blocks {
            let words = b.words.map(\.text)
            guard style.highlight, words.count > 1 else {
                out.append(CaptionLayer(start: b.start, end: b.end, words: words, lit: style.highlight ? 0 : nil, style: style))
                continue
            }
            for (i, w) in b.words.enumerated() {
                let start = i == 0 ? b.start : w.start
                let end = i + 1 < b.words.count ? b.words[i + 1].start : b.end
                guard end > start else { continue }
                out.append(CaptionLayer(start: start, end: end, words: words, lit: i, style: style))
            }
        }
        return out
    }

    private struct Key: Hashable {
        let words: [String]
        let lit: Int?
        /// The style, less its height in the frame (placed after drawing).
        let style: CaptionStyle
        let w: Int
        let h: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Key: CIImage] = [:]

    /// The caption, centred across the frame at the style's height. Drawn once and kept.
    static func image(words: [String], lit: Int?, style: CaptionStyle, output: CGSize) -> CIImage? {
        guard !words.isEmpty, output.width > 0, output.height > 0 else { return nil }
        var look = style
        look.y = 0
        let key = Key(words: words, lit: lit, style: look, w: Int(output.width), h: Int(output.height))
        lock.lock()
        let hit = cache[key]
        lock.unlock()
        let drawn = hit ?? draw(words: words, lit: lit, style: style, output: output)
        guard let drawn else { return nil }
        if hit == nil {
            lock.lock()
            if cache.count > 400 { cache.removeAll() }
            cache[key] = drawn
            lock.unlock()
        }
        // Centred, its middle at the style's height, kept inside the frame.
        let e = drawn.extent
        let cy = (1 - style.y) * output.height
        let y = min(max(cy - e.height / 2, 0), output.height - e.height)
        return drawn.transformed(by: CGAffineTransform(translationX: ((output.width - e.width) / 2).rounded(), y: y.rounded()))
    }

    /// Heavy words in the text colour, with an outline if it has one, the lit one in the highlight colour.
    private static func draw(words: [String], lit: Int?, style: CaptionStyle, output: CGSize) -> CIImage? {
        let pt = CGFloat(style.size) * min(output.width, output.height) / 1080
        let ns = { (c: RGBA) in NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }
        let font = NSFont.systemFont(ofSize: pt, weight: .heavy)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        func text(fill: Bool) -> NSAttributedString {
            let s = NSMutableAttributedString()
            for (i, w) in words.enumerated() {
                // A little wider than a plain space: the outline eats into the gap.
                // Chinese is written without spaces.
                if i > 0, SubtitleText.needsSpace(words[i - 1], w) { s.append(NSAttributedString(string: " ", attributes: [.font: font, .kern: pt * 0.06])) }
                var attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para]
                if fill {
                    attrs[.foregroundColor] = ns(i == lit ? style.highlightColor : style.textColor)
                } else {
                    attrs[.foregroundColor] = ns(style.outlineColor)
                    attrs[.strokeColor] = ns(style.outlineColor)
                    attrs[.strokeWidth] = 22.0
                }
                s.append(NSAttributedString(string: w, attributes: attrs))
            }
            s.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: s.length))
            return s
        }
        let fill = text(fill: true), outline = text(fill: false)
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let bounds = fill.boundingRect(with: CGSize(width: output.width * 0.86, height: .greatestFiniteMagnitude), options: opts)
        let pad = ceil(pt * 0.3)
        let tw = ceil(bounds.width), th = ceil(bounds.height)
        let w = Int(tw + pad * 2), h = Int(th + pad * 2)
        guard w > 0, h > 0, w < 16384, h < 16384,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.setLineJoin(.round)
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        let r = CGRect(x: pad, y: pad, width: tw, height: th)
        if style.outline { outline.draw(with: r, options: opts) }
        fill.draw(with: r, options: opts)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }
}
