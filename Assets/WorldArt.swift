//  WorldArt.swift
//  OfficeAdminGame
//
//  Replaceable hooks for original 2D art arriving separately:
//
//  (1) Transparent in-world attention/object sprites — the floating glyphs
//      that mark things needing Mike in the world (envelope/approval,
//      estimate, invoice/payment, permit, inspection, message/question).
//  (2) Paper/signage surfaces — textures for paper props and decals on the
//      office and jobsite geometry (envelopes, letters, sticky notes, signs,
//      the whiteboard).
//
//  Scenes depend on WorldArtProviding, never on placeholder drawing details.
//  The default provider is procedural. A real asset-catalog provider can be
//  injected later without changing scene construction. Characters are not
//  part of this hook and stay procedural placeholders for now.

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

    // MARK: (2) Paper / signage / decal surfaces

    enum SurfaceKind: String, CaseIterable {
        case envelope
        case letter
        case stickyNote
        case officeSign
        case officeWhiteboard
        case jobsiteSign
        case jobsiteDecal
    }

    /// A surface for 3D props and flat decals. `image` is transparent-capable
    /// and becomes a RealityKit texture when supplied by the provider.
    struct Surface {
        let tint: UIColor
        let image: UIImage?
    }

    static let provider: any WorldArtProviding = ProceduralWorldArtProvider()
}

protocol WorldArtProviding: AnyObject {
    func attentionSprite(_ kind: WorldArt.AttentionKind, side: CGFloat) -> UIImage
    func surface(_ kind: WorldArt.SurfaceKind) -> WorldArt.Surface
}

final class ProceduralWorldArtProvider: WorldArtProviding {
    private let cache = NSCache<NSString, UIImage>()

    func attentionSprite(_ kind: WorldArt.AttentionKind, side: CGFloat = 120) -> UIImage {
        let key = "attn|\(kind.rawValue)|\(side)"
        if let cached = cache.object(forKey: key as NSString) { return cached }

        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: format)
        let image = renderer.image { _ in
            let inset = side * 0.12
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
            drawSymbol(symbol, tint: tint, in: CGRect(
                x: inset * 0.9,
                y: inset * 0.9,
                width: side - inset * 1.8,
                height: side - inset * 1.8))
        }
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    func surface(_ kind: WorldArt.SurfaceKind) -> WorldArt.Surface {
        let tint: UIColor
        switch kind {
        case .envelope: tint = UIColor(red: 0.98, green: 0.95, blue: 0.88, alpha: 1)
        case .letter: tint = UIColor(red: 0.64, green: 0.28, blue: 0.22, alpha: 1)
        case .stickyNote: tint = UIColor(red: 0.98, green: 0.87, blue: 0.45, alpha: 1)
        case .officeSign, .jobsiteSign: tint = UIColor(Theme.parchment)
        case .officeWhiteboard: tint = UIColor(white: 0.98, alpha: 1)
        case .jobsiteDecal: tint = UIColor(Theme.sky)
        }
        return WorldArt.Surface(tint: tint, image: nil)
    }

    private func drawSymbol(_ name: String, tint: UIColor, in rect: CGRect) {
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
