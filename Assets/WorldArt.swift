//  WorldArt.swift
//  OfficeAdminGame
//
//  THE asset hooks for Mike's original 2D art (arriving separately):
//
//  (1) Transparent in-world attention/object sprites — the floating glyphs
//      that mark things needing Mike in the world (envelope/approval,
//      estimate, invoice/payment, permit, inspection, message/question).
//  (2) Paper/signage surfaces — textures for paper props and decals on the
//      office and jobsite geometry (envelopes, letters, sticky notes, signs,
//      the whiteboard).
//
//  Everything below is a PROCEDURAL PLACEHOLDER and must stay swappable:
//  scenes may only get art through WorldArt, never by drawing their own or
//  embedding image files. When the real art lands, replace the bodies of
//  `attentionSprite` and `paperSurface` (e.g. loading from the asset
//  catalog / bundle) and the whole world picks it up. Characters are not
//  here: they stay procedural placeholders per direction until their own
//  pass (see the roadmap issues).

import UIKit

enum WorldArt {

    // MARK: (1) Attention sprites

    enum AttentionKind: String, CaseIterable {
        case approval        // envelope/approval — a pending approval request
        case estimate        // estimate/bid being worked
        case invoicePayment  // invoice/receivable/payment event
        case permit          // permit needed or arrived
        case inspection      // inspection scheduled/failed
        case message         // unread client message / open question
    }

    /// A transparent sprite, roughly square, ~120pt, drawn at the requested
    /// scale. Placeholder: a paper glyph with a kind-specific badge.
    static func attentionSprite(_ kind: AttentionKind, side: CGFloat = 120) -> UIImage {
        let key = "attn|\(kind.rawValue)|\(side)"
        if let cached = cache.object(forKey: key as NSString) { return cached }

        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            let cg = ctx.cgContext
            let inset = side * 0.12

            // Paper diamond that reads at world scale.
            let paper = UIBezierPath()
            paper.move(to: CGPoint(x: side / 2, y: inset * 0.6))
            paper.addLine(to: CGPoint(x: side - inset, y: side / 2))
            paper.addLine(to: CGPoint(x: side / 2, y: side - inset * 0.6))
            paper.addLine(to: CGPoint(x: inset, y: side / 2))
            paper.close()
            UIColor(Theme.parchment).setFill()
            paper.fill()
            UIColor(Theme.ink).withAlphaComponent(0.2).setStroke()
            paper.lineWidth = side * 0.02
            paper.stroke()

            // Kind badge: distinct glyph + tint so kinds read at a glance.
            let (symbol, tint): (String, UIColor) = {
                switch kind {
                case .approval: return ("envelope.fill", UIColor(Theme.brick))
                case .estimate: return ("ruler.fill", UIColor(red: 0.47, green: 0.63, blue: 0.47, alpha: 1))
                case .invoicePayment: return ("banknote.fill", UIColor(red: 0.93, green: 0.72, blue: 0.33, alpha: 1))
                case .permit: return ("checkmark.seal.fill", UIColor(red: 0.62, green: 0.80, blue: 0.90, alpha: 1))
                case .inspection: return ("magnifyingglass.circle.fill", UIColor(red: 0.72, green: 0.55, blue: 0.76, alpha: 1))
                case .message: return ("bubble.left.fill", UIColor(red: 0.86, green: 0.55, blue: 0.45, alpha: 1))
                }
            }()
            drawSymbol(symbol, tint: tint, in: CGRect(x: inset * 0.9, y: inset * 0.9,
                                                      width: side - inset * 1.8, height: side - inset * 1.8))
        }
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    // MARK: (2) Paper / signage surfaces

    enum PaperKind: String, CaseIterable {
        case envelope
        case letter
        case stickyNote
        case sign
        case whiteboard
    }

    /// A surface for 3D props: a flat tint today, optionally an image to map
    /// as a texture (nil until real art lands — the scenes handle both).
    struct PaperSurface {
        let tint: UIColor
        let image: UIImage?
    }

    static func paperSurface(_ kind: PaperKind) -> PaperSurface {
        // Placeholder palette; when Mike's art arrives, return it as `image`
        // and the props become textured without any scene changes.
        let tint: UIColor
        switch kind {
        case .envelope: tint = UIColor(red: 0.98, green: 0.95, blue: 0.88, alpha: 1)
        case .letter: tint = UIColor(red: 0.64, green: 0.28, blue: 0.22, alpha: 1)
        case .stickyNote: tint = UIColor(red: 0.98, green: 0.87, blue: 0.45, alpha: 1)
        case .sign: tint = UIColor(Theme.parchment)
        case .whiteboard: tint = UIColor(white: 0.98, alpha: 1)
        }
        return PaperSurface(tint: tint, image: nil)
    }

    // MARK: - Shared cache + symbol drawing

    private static let cache = NSCache<NSString, UIImage>()

    /// SF Symbol drawn filled — placeholder glyphs only (system symbols are
    /// fine to render at runtime; they are not shipped as image assets).
    private static func drawSymbol(_ name: String, tint: UIColor, in rect: CGRect) {
        let config = UIImage.SymbolConfiguration(pointSize: min(rect.width, rect.height) * 0.72,
                                                 weight: .bold)
        guard let base = UIImage(systemName: name, withConfiguration: config) else { return }
        let rendered = base.withTintColor(tint, renderingMode: .alwaysOriginal)
        let size = rendered.size
        let scale = min(rect.width / size.width, rect.height / size.height)
        let drawRect = CGRect(x: rect.midX - size.width * scale / 2,
                              y: rect.midY - size.height * scale / 2,
                              width: size.width * scale,
                              height: size.height * scale)
        rendered.draw(in: drawRect)
    }
}
