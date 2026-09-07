//  SiteMarkerArt.swift
//  OfficeAdminGame
//
//  Procedural, original marker art: a small low-poly house drawn with
//  CoreGraphics, tinted by project phase, with tiny crew figures standing at
//  its base and the site name on a paper tag beneath. No image assets —
//  everything is drawn, so nothing here has a license question.

import UIKit

enum SiteMarkerArt {

    /// Draw one site marker. `crewCount` little figures stand at the base
    /// (capped, with +N when more). Cached per key — maps redraw constantly.
    static func marker(phase: WorldSite.Phase, name: String, crewCount: Int, urgent: Bool) -> UIImage {
        let key = "\(phase.rawValue)|\(name)|\(crewCount)|\(urgent)"
        if let cached = cache.object(forKey: key as NSString) { return cached }

        let size = CGSize(width: 148, height: 168)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let house = UIColor(Theme.phaseColor(phase))
            let houseDark = house.darkened(by: 0.28)
            let roof = UIColor(Theme.clay).darkened(by: phase == .active ? 0.0 : 0.10)

            // Ground shadow
            cg.setFillColor(UIColor.black.withAlphaComponent(0.18).cgColor)
            cg.fillEllipse(in: CGRect(x: 34, y: 92, width: 80, height: 16))

            // Body — two facets for a low-poly fold
            let body = CGRect(x: 44, y: 56, width: 60, height: 42)
            cg.setFillColor(house.cgColor)
            cg.fill(body)
            cg.setFillColor(houseDark.cgColor)
            cg.fill(CGRect(x: 74, y: 56, width: 30, height: 42))

            // Roof — chunky triangle with a highlight facet
            let roofPath = UIBezierPath()
            roofPath.move(to: CGPoint(x: 40, y: 58))
            roofPath.addLine(to: CGPoint(x: 74, y: 30))
            roofPath.addLine(to: CGPoint(x: 108, y: 58))
            roofPath.close()
            roof.setFill()
            roofPath.fill()
            let roofShine = UIBezierPath()
            roofShine.move(to: CGPoint(x: 74, y: 30))
            roofShine.addLine(to: CGPoint(x: 108, y: 58))
            roofShine.addLine(to: CGPoint(x: 74, y: 58))
            roofShine.close()
            UIColor(roof).withAlphaComponent(0.75).setFill()
            roofShine.fill()

            // Door + window
            cg.setFillColor(UIColor(Theme.ink).withAlphaComponent(0.55).cgColor)
            cg.fill(CGRect(x: 52, y: 74, width: 12, height: 24))
            cg.setFillColor(UIColor(Theme.honey).cgColor)
            cg.fill(CGRect(x: 84, y: 68, width: 14, height: 12))

            // Attention badge for sites with waiting mail — art via the
            // WorldArt hook (Mike's sprite drops in later, no change here).
            if urgent {
                let badge = WorldArt.attentionSprite(.approval, side: 44)
                badge.draw(at: CGPoint(x: 100, y: 2))
            }

            // Crew figures standing at the base (original placeholders:
            // capsule bodies + heads; real characters are a roadmap item).
            let shown = min(crewCount, 4)
            for i in 0..<shown {
                let x = CGFloat(38 + i * 19)
                let body = CGRect(x: x, y: 104, width: 11, height: 20)
                cg.setFillColor(UIColor(Theme.ink).withAlphaComponent(0.85).cgColor)
                cg.fillEllipse(in: CGRect(x: body.minX + 1, y: body.minY - 9, width: 9, height: 9))
                let shirt = [UIColor(Theme.clay), UIColor(Theme.sage),
                             UIColor(Theme.sky), UIColor(Theme.honey)][i % 4]
                let bodyPath = UIBezierPath(roundedRect: body, cornerRadius: 5)
                shirt.setFill()
                bodyPath.fill()
            }
            if crewCount > 4 {
                drawTag(text: "+\(crewCount - 4)", in: CGRect(x: 114, y: 106, width: 30, height: 18),
                        tint: UIColor(Theme.ink).withAlphaComponent(0.8), cg: cg)
            }

            // Name tag
            drawTag(text: name, in: CGRect(x: 4, y: 132, width: 140, height: 30),
                    tint: UIColor(Theme.parchment), cg: cg)
        }
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    /// A crew chip for the office/roster rendering: a tiny standing figure.
    static func crewFigure(color: UIColor, label: String) -> UIImage {
        let key = "fig|\(label)|\(color.description)"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        let size = CGSize(width: 64, height: 84)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(color.cgColor)
            UIBezierPath(roundedRect: CGRect(x: 20, y: 26, width: 24, height: 40), cornerRadius: 11).fill()
            cg.setFillColor(UIColor(Theme.ink).withAlphaComponent(0.85).cgColor)
            cg.fillEllipse(in: CGRect(x: 24, y: 8, width: 16, height: 16))
            let label = NSAttributedString(string: label, attributes: [
                .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: UIColor(Theme.ink),
            ])
            let textSize = label.size()
            label.draw(at: CGPoint(x: (64 - textSize.width) / 2, y: 70))
        }
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    // MARK: - Helpers

    private static let cache = NSCache<NSString, UIImage>()

    private static func drawTag(text: String, in rect: CGRect, tint: UIColor, cg: CGContext) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 9)
        path.lineWidth = 2
        tint.setFill()
        path.fill()
        UIColor(Theme.ink).withAlphaComponent(0.15).setStroke()
        path.stroke()

        let font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: tint == UIColor(Theme.parchment) ? UIColor(Theme.ink) : .white,
            .paragraphStyle: paragraph,
        ])
        let textSize = attributed.size()
        let textRect = CGRect(x: rect.minX + 4,
                              y: rect.minY + (rect.height - textSize.height) / 2,
                              width: rect.width - 8,
                              height: textSize.height)
        attributed.draw(in: textRect)
    }
}

private extension UIColor {
    func darkened(by fraction: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r * (1 - fraction), green: g * (1 - fraction),
                       blue: b * (1 - fraction), alpha: a)
    }
}
