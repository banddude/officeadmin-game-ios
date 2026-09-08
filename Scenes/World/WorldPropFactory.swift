//  WorldPropFactory.swift
//  OfficeAdminGame
//
//  Procedural, original geometry for the world diorama, in the approved
//  mockup's palette: warm cream blocks, sage parks, terracotta roofs, a
//  turquoise water band in the west, tiny stylized buildings per job site,
//  the Mediterranean Shaffer office, and little hard-hat characters.
//  Everything is boxes, spheres, cylinders, and text — no image assets, so
//  nothing here has a license question. Mike's real art replaces this layer
//  through WorldArtProviding where it can, without changing construction.

import RealityKit
import UIKit

// MARK: - Palette (the approved mockup)

enum WorldPalette {
    static let ground = UIColor(red: 0.87, green: 0.84, blue: 0.78, alpha: 1)   // pale street gray
    static let block = UIColor(red: 0.91, green: 0.86, blue: 0.75, alpha: 1)    // warm sandy block
    static let park = UIColor(red: 0.78, green: 0.84, blue: 0.70, alpha: 1)     // sage patch
    static let water = UIColor(red: 0.42, green: 0.74, blue: 0.82, alpha: 1)    // turquoise
    static let sand = UIColor(red: 0.93, green: 0.87, blue: 0.72, alpha: 1)
    static let path = UIColor(red: 0.95, green: 0.91, blue: 0.82, alpha: 1)
    static let stucco = UIColor(red: 0.96, green: 0.93, blue: 0.86, alpha: 1)   // office white
    static let terracotta = UIColor(red: 0.80, green: 0.48, blue: 0.33, alpha: 1)
    static let wood = UIColor(red: 0.55, green: 0.42, blue: 0.30, alpha: 1)
    static let canopy = UIColor(red: 0.42, green: 0.58, blue: 0.38, alpha: 1)
    static let canopyDark = UIColor(red: 0.34, green: 0.50, blue: 0.34, alpha: 1)
    static let pinRed = UIColor(red: 0.80, green: 0.27, blue: 0.22, alpha: 1)
    static let ink = UIColor(red: 0.24, green: 0.20, blue: 0.16, alpha: 1)
    static let skin = UIColor(red: 0.96, green: 0.85, blue: 0.72, alpha: 1)
    static let vest = UIColor(red: 0.93, green: 0.72, blue: 0.33, alpha: 1)     // safety mustard
    static let hardHat = UIColor(red: 0.97, green: 0.96, blue: 0.92, alpha: 1)
    static let sky = UIColor(red: 0.66, green: 0.82, blue: 0.90, alpha: 1)

    /// Wall tint for a site building: its phase color softened toward cream,
    /// so the board stays pastel even when phases differ.
    static func wall(for phase: WorldSite.Phase) -> UIColor {
        blend(UIColor(Theme.phaseColor(phase)), toward: block, fraction: 0.55)
    }

    static func blend(_ a: UIColor, toward b: UIColor, fraction: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = fraction
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t,
                       blue: b1 + (b2 - b1) * t, alpha: 1)
    }
}

// MARK: - Deterministic noise (stable scenery per board)

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func float(in range: ClosedRange<Float>) -> Float {
        Float.random(in: range, using: &self)
    }

    mutating func chance(_ probability: Double) -> Bool {
        Double.random(in: 0...1, using: &self) < probability
    }

    static func seed(from parts: [String]) -> UInt64 {
        var hash: UInt64 = 5381
        for part in parts.sorted() {
            for scalar in part.unicodeScalars {
                hash = (hash &* 33) &+ UInt64(scalar.value)
            }
        }
        return hash
    }
}

// MARK: - Factory

enum WorldPropFactory {

    // MARK: Pieces

    static func box(_ size: SIMD3<Float>, _ color: UIColor,
                    at position: SIMD3<Float> = .zero,
                    rotationY: Float? = nil) -> Entity {
        let entity = Entity()
        entity.components.set(ModelComponent(
            mesh: .generateBox(size: size),
            materials: [SimpleMaterial(color: color, isMetallic: false)]))
        entity.position = position
        if let rotationY { entity.orientation = simd_quatf(angle: rotationY, axis: [0, 1, 0]) }
        return entity
    }

    /// A squashed sphere — iOS 17 has no short-cylinder generator and pins,
    /// pots, hats and pucks are all discs anyway.
    static func disc(radius: Float, thickness: Float, _ color: UIColor,
                     at position: SIMD3<Float> = .zero) -> Entity {
        let entity = Entity()
        entity.components.set(ModelComponent(
            mesh: .generateSphere(radius: radius),
            materials: [SimpleMaterial(color: color, isMetallic: false)]))
        entity.scale = SIMD3(1, thickness / (radius * 2), 1)
        entity.position = position
        return entity
    }

    static func cylinder(radius: Float, height: Float, _ color: UIColor,
                         at position: SIMD3<Float> = .zero) -> Entity {
        let entity = Entity()
        entity.components.set(ModelComponent(
            mesh: .generateCylinder(height: height, radius: radius),
            materials: [SimpleMaterial(color: color, isMetallic: false)]))
        entity.position = position
        return entity
    }

    /// Centered text mesh (extruded, unlit so labels stay readable).
    static func text(_ string: String, height: Float, color: UIColor,
                     weight: UIFont.Weight = .bold) -> Entity {
        let entity = Entity()
        let mesh = MeshResource.generateText(
            string,
            extrusionDepth: 0.02,
            font: .systemFont(ofSize: CGFloat(height), weight: weight),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byWordWrapping)
        entity.components.set(ModelComponent(mesh: mesh, materials: [UnlitMaterial(color: color)]))
        if let bounds = entity.components[ModelComponent.self]?.mesh.bounds {
            entity.position = -SIMD3(bounds.center.x, bounds.center.y, bounds.center.z)
        }
        return entity
    }

    // MARK: Trees

    static func tree(rng: inout SeededGenerator) -> Entity {
        let tree = Entity()
        let trunk = cylinder(radius: 0.11, height: 0.8, WorldPalette.wood, at: SIMD3(0, 0.4, 0))
        tree.addChild(trunk)
        let canopyColor = rng.chance(0.5) ? WorldPalette.canopy : WorldPalette.canopyDark
        let canopy = Entity()
        canopy.components.set(ModelComponent(
            mesh: .generateSphere(radius: rng.float(in: 0.42...0.58)),
            materials: [SimpleMaterial(color: canopyColor, isMetallic: false)]))
        canopy.scale = SIMD3(1, rng.float(in: 0.85...1.05), 1)
        canopy.position = SIMD3(0, 1.05, 0)
        tree.addChild(canopy)
        let puff = disc(radius: 0.3, thickness: 0.34, canopyColor,
                        at: SIMD3(rng.float(in: -0.25...0.25), 1.25, rng.float(in: -0.2...0.2)))
        tree.addChild(puff)
        return tree
    }

    // MARK: Ground board

    /// The whole ground: base slab, water band in the west with a sand strip,
    /// a grid of cream blocks whose gaps read as streets, sage parks, and
    /// trees — laid out around the site footprints and the office lot.
    static func groundBoard(board: WorldBoard, rng: inout SeededGenerator) -> Entity {
        let root = Entity(name: "ground")

        // Base slab (streets show through the block gaps).
        let slab = box(SIMD3(board.size.x, 0.6, board.size.y), WorldPalette.ground,
                       at: SIMD3(0, -0.3, 0))
        slab.generateCollisionShapes(recursive: false)
        root.addChild(slab)

        // Water band along the west edge, sunk just below street level.
        let waterWidth = board.size.x * 0.16
        let water = box(SIMD3(waterWidth, 0.5, board.size.y - 2), WorldPalette.water,
                        at: SIMD3(-board.size.x / 2 + waterWidth / 2, -0.18, 0))
        root.addChild(water)
        // A brighter shoreline, then sand.
        let shine = box(SIMD3(1.1, 0.5, board.size.y - 2),
                        WorldPalette.blend(WorldPalette.water, toward: .white, fraction: 0.45),
                        at: SIMD3(-board.size.x / 2 + waterWidth - 0.4, -0.14, 0))
        root.addChild(shine)
        let beach = box(SIMD3(2.2, 0.52, board.size.y - 2), WorldPalette.sand,
                        at: SIMD3(-board.size.x / 2 + waterWidth + 0.9, -0.08, 0))
        root.addChild(beach)

        // City blocks. The gaps between them are the streets.
        let pitch: Float = 7.4
        let blockHalf: Float = 2.85
        let firstX = -board.size.x / 2 + waterWidth + 3.4
        var x = firstX + pitch / 2
        while x < board.size.x / 2 - 3.0 {
            var y = -board.size.y / 2 + pitch / 2
            while y < board.size.y / 2 - 3.0 {
                defer { y += pitch }
                let rect = BoardRect.size(blockHalf * 2 + 2.4, blockHalf * 2 + 2.4,
                                          at: SIMD2(x, y))
                // Keep the office lot and every building pad clear.
                if rect.overlaps(board.officeFootprint, gap: 1.4) { continue }
                if board.buildingFootprints.values.contains(where: { $0.overlaps(rect, gap: 0.4) }) {
                    continue
                }
                let isPark = rng.chance(0.28)
                let color = isPark ? WorldPalette.park : WorldPalette.block
                root.addChild(box(SIMD3(blockHalf * 2, 0.14, blockHalf * 2), color,
                                  at: SIMD3(x, 0.07, y)))
                if isPark {
                    let trees = rng.chance(0.5) ? 2 : 1
                    for _ in 0..<trees {
                        let tree = tree(rng: &rng)
                        tree.position = SIMD3(x + rng.float(in: -1.6...1.6), 0,
                                              y + rng.float(in: -1.6...1.6))
                        root.addChild(tree)
                    }
                } else if rng.chance(0.22) {
                    let tree = tree(rng: &rng)
                    tree.position = SIMD3(x + rng.float(in: -1.8...1.8), 0, y - blockHalf + 0.5)
                    root.addChild(tree)
                }
            }
            x += pitch
        }

        // A little path from the office door to the board's south edge.
        let pathStart = board.officeDoorPoint
        root.addChild(box(SIMD3(1.8, 0.15, board.size.y / 2 - pathStart.y + 1.5),
                          WorldPalette.path,
                          at: SIMD3(pathStart.x, 0.075,
                                    (pathStart.y + board.size.y / 2) / 2 + 0.75)))
        return root
    }

    // MARK: Site buildings

    /// One stylized building for one project, styled by its real category:
    /// solar roofs, EV charger posts, construction cranes, scaffolds. The
    /// building's footprint matches WorldBoard.buildingSize so the geometry
    /// a walker collides with is the geometry they see.
    static func building(for site: WorldSite, footprint: BoardRect) -> Entity {
        let group = Entity(name: "site:\(site.id)")
        let wall = WorldPalette.wall(for: site.phase)
        let scope = (site.scopeLabel ?? "").lowercased()
        let size = SIMD3(footprint.halfExtents.x * 2, height(for: site), footprint.halfExtents.y * 2)

        // Pad grounds the building on the block.
        let pad = box(SIMD3(size.x + 1.4, 0.12, size.z + 1.4), WorldPalette.sand,
                      at: SIMD3(0, 0.06, 0))
        group.addChild(pad)

        let body = box(size, wall, at: SIMD3(0, size.y / 2 + 0.1, 0))
        body.generateCollisionShapes(recursive: false)
        group.addChild(body)

        // Chunky terracotta cap — the low-poly roof line of the mockup.
        let roof = box(SIMD3(size.x + 0.5, 0.36, size.z + 0.5), WorldPalette.terracotta,
                       at: SIMD3(0, size.y + 0.28, 0))
        group.addChild(roof)
        let roofTop = box(SIMD3(size.x - 0.7, 0.24, size.z - 0.7),
                          WorldPalette.blend(WorldPalette.terracotta, toward: .white, fraction: 0.22),
                          at: SIMD3(0, size.y + 0.56, 0))
        group.addChild(roofTop)

        // Face the street: door and warm windows on the south side.
        let door = box(SIMD3(0.8, 1.15, 0.08), WorldPalette.ink,
                       at: SIMD3(0, 0.68, size.z / 2 + 0.02))
        group.addChild(door)
        for wx in [-size.x / 4, size.x / 4] {
            group.addChild(box(SIMD3(0.7, 0.6, 0.06), WorldPalette.vest,
                               at: SIMD3(wx, size.y * 0.62, size.z / 2 + 0.02)))
        }

        // Category flourishes from the real scope.
        if scope.contains("solar") {
            for sx in [-size.x / 4, size.x / 4] {
                let panel = box(SIMD3(1.5, 0.05, 1.0), WorldPalette.water,
                                at: SIMD3(sx, size.y + 0.78, -0.1))
                panel.orientation = simd_quatf(angle: -0.4, axis: [1, 0, 0])
                group.addChild(panel)
            }
        }
        if scope.contains("ev") || scope.contains("charger") {
            for (i, cx) in [-1.0, 0.0, 1.0].enumerated() {
                let post = box(SIMD3(0.16, 0.9, 0.16), WorldPalette.ink,
                               at: SIMD3(Float(cx), 0.55, size.z / 2 + 0.9))
                group.addChild(post)
                group.addChild(disc(radius: 0.2, thickness: 0.06,
                                    i % 2 == 0 ? WorldPalette.canopy : WorldPalette.vest,
                                    at: SIMD3(Float(cx), 1.05, size.z / 2 + 0.9)))
            }
        }
        if scope.contains("new build") || scope.contains("construction") ||
            scope.contains("tenant improvement") {
            // A little tower crane over the site.
            let mast = box(SIMD3(0.14, 3.4, 0.14), WorldPalette.vest,
                           at: SIMD3(size.x / 2 - 0.5, 1.8, -size.z / 2 + 0.5))
            group.addChild(mast)
            let jib = box(SIMD3(2.6, 0.12, 0.12), WorldPalette.vest,
                          at: SIMD3(size.x / 2 - 1.2, 3.5, -size.z / 2 + 0.5))
            group.addChild(jib)
            group.addChild(box(SIMD3(0.09, 0.7, 0.09), WorldPalette.ink,
                               at: SIMD3(size.x / 2 - 2.2, 3.1, -size.z / 2 + 0.5)))
        }
        if scope.contains("renovation") || scope.contains("remodel") || scope.contains("repair") {
            // Scaffold along the west face.
            for sy in [-size.z / 2 + 0.3, 0, size.z / 2 - 0.3] {
                group.addChild(box(SIMD3(0.1, 1.9, 0.1), WorldPalette.wood,
                                   at: SIMD3(-size.x / 2 - 0.35, 1.05, Float(sy))))
            }
            group.addChild(box(SIMD3(0.5, 0.08, size.z), WorldPalette.wood,
                               at: SIMD3(-size.x / 2 - 0.35, 2.0, 0)))
        }

        group.position = SIMD3(footprint.center.x, 0, footprint.center.y)
        return group
    }

    private static func height(for site: WorldSite) -> Float {
        let scope = (site.scopeLabel ?? "").lowercased()
        var h: Float
        switch site.phase {
        case .active: h = 3.4
        case .bidSent: h = 3.0
        case .estimating: h = 2.7
        case .onHold: h = 2.4
        case .lead: h = 2.0
        }
        if scope.contains("new build") || scope.contains("construction") { h = 2.6 } // under construction
        if scope.contains("solar") { h = 2.9 }
        return h
    }

    /// Where the pin and the label float: over the roof cap.
    static func rooflineHeight(for site: WorldSite) -> Float {
        height(for: site) + 0.95
    }

    /// The red bolt pin on its pole — the site marker of the mockup.
    static func sitePin(aboveRoofAt y: Float) -> Entity {
        let pin = Entity()
        let pole = cylinder(radius: 0.045, height: 1.15, WorldPalette.stucco, at: SIMD3(0, 0.57, 0))
        pin.addChild(pole)
        let head = disc(radius: 0.3, thickness: 0.26, WorldPalette.pinRed, at: SIMD3(0, 1.3, 0))
        pin.addChild(head)
        // A white diamond reads as the bolt mark at diorama scale.
        let bolt = box(SIMD3(0.1, 0.17, 0.04), .white, at: SIMD3(0, 1.3, 0.26))
        bolt.orientation = simd_quatf(angle: 0.7, axis: [0, 0, 1])
        pin.addChild(bolt)
        pin.position = SIMD3(0, y, 0)
        return pin
    }

    /// The site's name/scope label card, floating over the building.
    static func siteLabel(for site: WorldSite) -> Entity {
        let group = Entity()
        let name = text(site.name, height: 0.30, color: WorldPalette.ink)
        let scope = text((site.scopeLabel ?? site.phase.label).uppercased(),
                         height: 0.155,
                         color: WorldPalette.blend(WorldPalette.ink, toward: .white, fraction: 0.35),
                         weight: .semibold)

        let nameWidth = name.components[ModelComponent.self]?.mesh.bounds.max.x ?? 1.0
        let scopeWidth = scope.components[ModelComponent.self]?.mesh.bounds.max.x ?? 1.0
        let plateWidth = max(nameWidth, scopeWidth) + 0.34
        let plate = box(SIMD3(plateWidth, 0.66, 0.05), WorldPalette.stucco, at: .zero)
        group.addChild(plate)

        name.position += SIMD3(0, 0.13, 0.04)
        scope.position += SIMD3(0, -0.17, 0.04)
        group.addChild(name)
        group.addChild(scope)
        return group
    }

    // MARK: The Shaffer office

    /// The home node: white stucco, terracotta roof, sage awning, sign over
    /// the door, a flag out front. Its door sits at board.officeDoorPoint.
    static func office(board: WorldBoard) -> Entity {
        let group = Entity(name: "office")
        let footprint = board.officeFootprint
        let w = footprint.halfExtents.x * 2
        let d = footprint.halfExtents.y * 2
        let h: Float = 3.2

        let body = box(SIMD3(w, h, d), WorldPalette.stucco, at: SIMD3(0, h / 2, 0))
        body.generateCollisionShapes(recursive: false)
        group.addChild(body)
        group.addChild(box(SIMD3(w + 0.7, 0.5, d + 0.7), WorldPalette.terracotta,
                           at: SIMD3(0, h + 0.25, 0)))
        group.addChild(box(SIMD3(w - 1.2, 0.3, d - 1.2),
                           WorldPalette.blend(WorldPalette.terracotta, toward: .white, fraction: 0.2),
                           at: SIMD3(0, h + 0.62, 0)))

        // The door, centered on the south face, at officeDoorPoint.
        let doorZ = d / 2 + 0.04
        group.addChild(box(SIMD3(1.3, 2.0, 0.1), WorldPalette.wood,
                           at: SIMD3(0, 1.05, doorZ)))
        // Sage awning over the door.
        group.addChild(box(SIMD3(2.2, 0.12, 1.0), WorldPalette.canopy,
                           at: SIMD3(0, 2.35, doorZ + 0.4)))
        // Warm windows either side of the door.
        for wx in [-w / 4 - 0.4, w / 4 + 0.4] {
            group.addChild(box(SIMD3(1.0, 0.85, 0.06), WorldPalette.vest,
                               at: SIMD3(Float(wx), 1.7, doorZ)))
        }

        // "SHAFFER CONSTRUCTION" over the awning.
        let sign = text("SHAFFER CONSTRUCTION", height: 0.24, color: WorldPalette.ink)
        let signWidth = sign.components[ModelComponent.self]?.mesh.bounds.max.x ?? 3.0
        group.addChild(box(SIMD3(signWidth + 0.4, 0.44, 0.06),
                           WorldPalette.blend(WorldPalette.block, toward: .white, fraction: 0.35),
                           at: SIMD3(0, 2.85, doorZ + 0.02)))
        sign.position += SIMD3(0, 2.85, doorZ + 0.06)
        group.addChild(sign)

        // Flag pole with a pennant, and a chalkboard A-frame by the door.
        let flag = cylinder(radius: 0.05, height: 2.6, WorldPalette.stucco,
                            at: SIMD3(w / 2 - 0.8, 1.3, d / 2 + 1.6))
        group.addChild(flag)
        group.addChild(box(SIMD3(0.7, 0.3, 0.03), .white,
                           at: SIMD3(w / 2 - 0.8 + 0.36, 2.45, d / 2 + 1.6)))
        let boardSign = box(SIMD3(0.9, 0.6, 0.06), WorldPalette.blend(WorldPalette.canopyDark, toward: .black, fraction: 0.25),
                            at: SIMD3(-w / 2 + 1.0, 0.75, d / 2 + 0.8))
        group.addChild(boardSign)
        for lx in [-0.35, 0.35] {
            group.addChild(box(SIMD3(0.05, 0.5, 0.05), WorldPalette.wood,
                               at: SIMD3(-w / 2 + 1.0 + Float(lx), 0.25, d / 2 + 0.9)))
        }

        group.position = SIMD3(footprint.center.x, 0, footprint.center.y)
        return group
    }

    // MARK: Characters

    /// A little hard-hat character (Mike, the crew). Faces +z at zero yaw —
    /// the same convention walking headings use. Legs are named so the tick
    /// can swing them; everything is original placeholder geometry.
    static func character(shirt: UIColor, hardHat: Bool = true) -> Entity {
        let character = Entity()
        character.addChild(blobShadow())

        let legL = box(SIMD3(0.13, 0.42, 0.15), WorldPalette.ink, at: SIMD3(-0.1, 0.21, 0))
        legL.name = "legL"
        let legR = box(SIMD3(0.13, 0.42, 0.15), WorldPalette.ink, at: SIMD3(0.1, 0.21, 0))
        legR.name = "legR"
        character.addChild(legL)
        character.addChild(legR)

        let body = Entity()
        body.name = "body"
        body.components.set(ModelComponent(
            mesh: .generateSphere(radius: 0.3),
            materials: [SimpleMaterial(color: shirt, isMetallic: false)]))
        body.scale = SIMD3<Float>(0.95, 1.35, 0.8)
        body.position = SIMD3(0, 0.72, 0)
        character.addChild(body)

        let head = Entity()
        head.components.set(ModelComponent(
            mesh: .generateSphere(radius: 0.21),
            materials: [SimpleMaterial(color: WorldPalette.skin, isMetallic: false)]))
        head.position = SIMD3(0, 1.18, 0)
        character.addChild(head)
        for ex in [-0.075, 0.075] {
            let eye = Entity()
            eye.components.set(ModelComponent(
                mesh: .generateSphere(radius: 0.022),
                materials: [SimpleMaterial(color: WorldPalette.ink, isMetallic: false)]))
            eye.position = SIMD3(Float(ex), 1.21, 0.19)
            character.addChild(eye)
        }

        if hardHat {
            let hat = disc(radius: 0.23, thickness: 0.14, WorldPalette.hardHat,
                           at: SIMD3(0, 1.36, 0))
            character.addChild(hat)
            character.addChild(disc(radius: 0.29, thickness: 0.035, WorldPalette.hardHat,
                                    at: SIMD3(0, 1.31, 0)))
            character.addChild(disc(radius: 0.235, thickness: 0.05, WorldPalette.vest,
                                    at: SIMD3(0, 1.30, 0)))
        }
        return character
    }

    /// A soft blob shadow that grounds a character on the cream blocks.
    private static func blobShadow() -> Entity {
        let shadow = disc(radius: 0.34, thickness: 0.02,
                          UIColor(red: 0.55, green: 0.48, blue: 0.36, alpha: 1))
        shadow.position = SIMD3(0, 0.021, 0)
        return shadow
    }

    // MARK: Attention pickups

    /// A floating sprite post marking something that needs Mike — an envelope
    /// waiting at a site, an invoice due. The sprite art comes from the
    /// injected provider (Mike's art drops in later).
    static func attentionPickup(kind: WorldArt.AttentionKind,
                                artProvider: any WorldArtProviding) -> Entity {
        let group = Entity()
        group.addChild(cylinder(radius: 0.04, height: 0.9, WorldPalette.stucco,
                                at: SIMD3(0, 0.45, 0)))

        let sprite = Entity(name: "sprite")
        let material = SimpleMaterial(color: .white, isMetallic: false)
        if let image = artProvider.attentionSprite(kind, side: 128).cgImage,
           let texture = try? TextureResource.generate(
               from: image, options: TextureResource.CreateOptions(semantic: .color)) {
            material.color = .init(tint: .white, texture: .init(texture))
        }
        // A thin textured box: visible from either side, no culling worries.
        sprite.components.set(ModelComponent(
            mesh: .generateBox(size: SIMD3(0.85, 0.85, 0.02)),
            materials: [material]))
        sprite.position = SIMD3(0, 1.5, 0)
        group.addChild(sprite)
        return group
    }
}
