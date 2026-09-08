//  WorldBoard.swift
//  OfficeAdminGame
//
//  The ground the game is played on. Real site coordinates are projected
//  onto a local plane (Web Mercator, in meters) and scaled to fit a
//  comfortable stylized board with padding — the world reads as a cozy
//  diorama, not a survey map. Pure value types: no rendering, no networking,
//  so layouts are deterministic and unit-testable.
//
//  Board axes: +x is east, +y is SOUTH (so the scene maps board y straight
//  onto RealityKit z, north away from the camera). When nothing geocodes,
//  the board still exists around the Los Angeles center with just the office.

import CoreLocation
import Foundation
import simd

// MARK: - Rectangles on the ground

/// An axis-aligned rectangle on the board plane.
struct BoardRect: Equatable {
    var center: SIMD2<Float>
    var halfExtents: SIMD2<Float>

    init(center: SIMD2<Float>, halfExtents: SIMD2<Float>) {
        self.center = center
        self.halfExtents = abs(halfExtents)
    }

    /// A rect from min/max corners (any order).
    init(min: SIMD2<Float>, max: SIMD2<Float>) {
        let lo = simd_min(min, max)
        let hi = simd_max(min, max)
        self.init(center: (lo + hi) / 2, halfExtents: (hi - lo) / 2)
    }

    static func size(_ width: Float, _ depth: Float, at center: SIMD2<Float>) -> BoardRect {
        BoardRect(center: center, halfExtents: SIMD2(width / 2, depth / 2))
    }

    var minX: Float { center.x - halfExtents.x }
    var maxX: Float { center.x + halfExtents.x }
    var minY: Float { center.y - halfExtents.y }
    var maxY: Float { center.y + halfExtents.y }

    func contains(_ p: SIMD2<Float>, pad: Float = 0) -> Bool {
        p.x >= minX - pad && p.x <= maxX + pad &&
        p.y >= minY - pad && p.y <= maxY + pad
    }

    func expanded(by pad: Float) -> BoardRect {
        BoardRect(center: center, halfExtents: halfExtents + SIMD2(pad, pad))
    }

    /// Do two rects overlap, counting `gap` meters of required clearance?
    func overlaps(_ other: BoardRect, gap: Float = 0) -> Bool {
        abs(center.x - other.center.x) < halfExtents.x + other.halfExtents.x + gap &&
        abs(center.y - other.center.y) < halfExtents.y + other.halfExtents.y + gap
    }

    /// Nearest point on or inside the rect to `p` (on the boundary when `p`
    /// is outside; `p` itself when inside).
    func clampPoint(_ p: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(min(max(p.x, minX), maxX), min(max(p.y, minY), maxY))
    }
}

// MARK: - The board

/// One laid-out world: every geocoded site at a board position, its building
/// footprint, and the office in its corner. Built from `WorldSite`s only.
struct WorldBoard {
    /// The full ground board (x east-west, y north-south), centered at 0.
    /// Portrait diorama proportions: narrow enough that the whole width fits
    /// a phone screen at a low, mockup-like camera; deep enough that the
    /// near ground fills the bottom of the frame instead of leaving sea and
    /// sky margins around a tabletop.
    static let size = SIMD2<Float>(40, 64)
    /// Sites are laid out inside the board inset by this much.
    static let padding: Float = 6.5
    /// The west edge is scenery (ocean and beach, like the mockup) — sites
    /// are laid out east of it. Mirrors the ground's water band width.
    static let sceneryWidth: Float = size.x * 0.16 + 3.2
    /// Where the world sits when no site geocodes.
    static let losAngelesCenter = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)
    /// Building footprints never come closer than this to each other.
    static let buildingGap: Float = 1.1
    /// The site-cloud fit leaves this much of the region unused on each side,
    /// so a site's BUILDING (not just its center point) lands inside the
    /// region — otherwise edge sites get clamped and proportions break.
    static let fitMargin: Float = 3.4

    /// Board position per site id.
    let sitePositions: [String: SIMD2<Float>]
    /// Building footprint per site id (matches the scene's building size).
    let buildingFootprints: [String: BoardRect]
    /// The Shaffer office, always in the south-east corner.
    let officePosition: SIMD2<Float>
    let officeFootprint: BoardRect
    /// Where the player may stand (board inset from its edges).
    let walkableRect: BoardRect
    /// The Mercator origin the projection used (interesting, not load-bearing).
    let origin: CLLocationCoordinate2D
    /// True when no site geocoded and the LA fallback anchored the board.
    let usedFallbackOrigin: Bool

    init(sites: [WorldSite]) {
        // Deterministic order so a shuffled API reply lays out identically.
        let geocoded = sites
            .filter { $0.coordinate.map(WorldRules.isPlausible) == true }
            .sorted { ($0.id, $0.name) < ($1.id, $1.name) }

        usedFallbackOrigin = geocoded.isEmpty
        origin = WorldBoard.centroid(of: geocoded) ?? WorldBoard.losAngelesCenter

        let originMeters = WorldBoard.mercatorMeters(origin)

        // The region sites may occupy: padded, and clear of the ocean.
        let regionMin = SIMD2(-WorldBoard.size.x / 2 + WorldBoard.sceneryWidth,
                              -WorldBoard.size.y / 2 + WorldBoard.padding)
        let regionMax = SIMD2(WorldBoard.size.x / 2 - WorldBoard.padding,
                              WorldBoard.size.y / 2 - WorldBoard.padding)
        let regionCenter = (regionMin + regionMax) / 2

        // Project every site to meters around the origin, then fit the whole
        // cloud into the padded board (east of the scenery band) with a
        // single uniform scale.
        var unitsPerMeter: Float = 1
        var positions: [String: SIMD2<Float>] = [:]
        if !geocoded.isEmpty {
            let meters = geocoded.map { site in
                (id: site.id, m: WorldBoard.mercatorMeters(site.coordinate!) - originMeters)
            }
            var lo = SIMD2<Float>.zero, hi = SIMD2<Float>.zero
            for item in meters {
                lo = simd_min(lo, SIMD2<Float>(item.m))
                hi = simd_max(hi, SIMD2<Float>(item.m))
            }
            // usable = region minus the fit margin ON EACH SIDE, so a cloud
            // that fills `usable` leaves room for its buildings' halves.
            let usable = regionMax - regionMin - SIMD2(WorldBoard.fitMargin * 2, WorldBoard.fitMargin * 2)
            let span = hi - lo
            // Scale to fit (a degenerate cluster keeps a sane human scale).
            if span.x > 0.001 || span.y > 0.001 {
                unitsPerMeter = min(
                    usable.x / max(span.x, 0.001),
                    usable.y / max(span.y, 0.001),
                    12) // a tight cluster of sites stays a tight cluster
            }
            let cloudCenter = (lo + hi) / 2 * unitsPerMeter
            for item in meters {
                let b = SIMD2<Float>(item.m) * unitsPerMeter - cloudCenter
                // Board y is south; Mercator meters y grows north.
                positions[item.id] = regionCenter + SIMD2(b.x, -b.y)
            }
        }

        // The office lives toward the south-east corner, seated so its door
        // (on the south face) stays inside the walkable board.
        officePosition = SIMD2(
            WorldBoard.size.x / 2 - 6.6,
            WorldBoard.size.y / 2 - 8.6)
        officeFootprint = BoardRect.size(9.0, 7.0, at: officePosition)
        walkableRect = BoardRect(
            min: -WorldBoard.size / 2 + SIMD2(2.4, 2.4),
            max: WorldBoard.size / 2 - SIMD2(2.4, 2.4))

        // Footprints from board positions, then spread overlaps OUTWARD ALONG
        // each site's true bearing so the relative geography the projection
        // produced survives being made walkable (dense metro clusters bloom
        // radially instead of being re-packed into a generic village).
        // When the full address list crowds the board, footprints shrink a
        // little (the scene builds meshes from footprints, so visuals follow).
        let buildingScale = WorldBoard.footprintScale(for: geocoded)
        var footprints: [String: BoardRect] = [:]
        for site in geocoded {
            guard let p = positions[site.id] else { continue }
            let size = WorldBoard.buildingSize(category: site.scopeLabel,
                                               phase: site.phase) * buildingScale
            footprints[site.id] = BoardRect.size(size.x, size.y, at: p)
        }
        // Bearings radiate from the cloud's MEDIAN anchor, not its bounding
        // box center: one far outlier (a Bay Area job) drags the box center
        // most of the way out of town, which would seat the whole LA basin in
        // a single south-east lane. The median stays inside the dense cluster
        // where the work is, so metro sites fan out in every direction and
        // far cities sit at their true bearings FROM the metro — how a CA map
        // is actually read.
        let medianAnchor = WorldBoard.medianAnchor(of: positions)
        WorldBoard.spreadAlongBearings(&footprints,
                                       anchors: positions,
                                       around: medianAnchor,
                                       office: officeFootprint)

        // Positions follow their (possibly nudged) footprints.
        for (id, rect) in footprints { positions[id] = rect.center }
        sitePositions = positions
        buildingFootprints = footprints
    }

    init() {
        self.init(sites: [])
    }

    /// All footprints a walker must go around (buildings + the office).
    var obstacles: [BoardRect] {
        Array(buildingFootprints.values) + [officeFootprint]
    }

    /// The office door: the middle of the office's south face, just outside.
    var officeDoorPoint: SIMD2<Float> {
        SIMD2(officePosition.x, officeFootprint.maxY + 0.9)
    }

    // MARK: Building size by what the project is

    /// The robust center of the site cloud: median x, median y of the true
    /// anchors. Unlike a bounding box (or mean), one far-flung job cannot
    /// drag it out of the metro the work concentrates in.
    static func medianAnchor(of positions: [String: SIMD2<Float>]) -> SIMD2<Float> {
        guard !positions.isEmpty else { return .zero }
        let xs = positions.values.map(\.x).sorted()
        let ys = positions.values.map(\.y).sorted()
        let mid = xs.count / 2
        let medianX = xs.count % 2 == 1 ? xs[mid] : (xs[mid - 1] + xs[mid]) / 2
        let medianY = ys.count % 2 == 1 ? ys[mid] : (ys[mid - 1] + ys[mid]) / 2
        return SIMD2(medianX, medianY)
    }

    /// How much footprints shrink when the board is too crowded for every
    /// building at full size. A dozen sites keep full size; the full real
    /// list (~42 addressed jobs) shrinks ~10-15% — perceptible only side by
    /// side, and the whole board stays walkable instead of clogged.
    static func footprintScale(for sites: [WorldSite]) -> Float {
        guard sites.count > 4 else { return 1 }
        let layoutMin = SIMD2(-WorldBoard.size.x / 2 + WorldBoard.sceneryWidth,
                              -WorldBoard.size.y / 2 + 3.0)
        let layoutMax = WorldBoard.size / 2 - SIMD2(Float(3.0), Float(3.0))
        let usable = (layoutMax.x - layoutMin.x) * (layoutMax.y - layoutMin.y)
        let officeArea: Float = 9.0 * 7.0 * 1.6
        // Radial packing fills roughly two thirds of the circle area it needs.
        let available = max((usable - officeArea) * 0.65, 1)
        var needed: Float = 0
        for site in sites {
            let size = WorldBoard.buildingSize(category: site.scopeLabel, phase: site.phase)
            let radius = simd_length(size) / 2 + WorldBoard.buildingGap / 2
            needed += .pi * radius * radius
        }
        return needed <= available ? 1 : max(sqrt(available / needed), 0.62)
    }

    /// Footprint of one site's building, from its real category and phase.
    /// The scene builds its mesh from the same numbers, so the geometry a
    /// walker collides with is the geometry they see.
    static func buildingSize(category: String?, phase: WorldSite.Phase) -> SIMD2<Float> {
        let scope = (category ?? "").lowercased()
        var width: Float = 4.6, depth: Float = 4.6
        if scope.contains("solar") { width = 5.2; depth = 4.0 }
        if scope.contains("ev") || scope.contains("charger") { width = 3.6; depth = 4.8 }
        if scope.contains("new build") || scope.contains("construction") || scope.contains("tenant improvement") {
            width = 5.6; depth = 5.0
        }
        if scope.contains("renovation") || scope.contains("remodel") { width = 5.0; depth = 4.2 }
        // Leads are still just an idea — a smaller presence on the board.
        if phase == .lead { width *= 0.72; depth *= 0.72 }
        return SIMD2(width, depth)
    }

    // MARK: Projection

    /// Web Mercator, in meters: the standard local-plane start line.
    static func mercatorMeters(_ c: CLLocationCoordinate2D) -> SIMD2<Double> {
        let earthRadius = 6_378_137.0
        let x = earthRadius * c.longitude * .pi / 180
        let y = earthRadius * log(tan(.pi / 4 + c.latitude * .pi / 180 / 2))
        return SIMD2(x, y)
    }

    private static func centroid(of sites: [WorldSite]) -> CLLocationCoordinate2D? {
        let coords = sites.compactMap(\.coordinate)
        guard !coords.isEmpty else { return nil }
        let lat = coords.map(\.latitude).reduce(0, +) / Double(coords.count)
        let lng = coords.map(\.longitude).reduce(0, +) / Double(coords.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// Resolve building overlaps WITHOUT re-shuffling the map, preserving the
    /// relative geography the projection produced. Buildings seat on a fixed
    /// rectangular LATTICE whose cells clear the largest footprint, so
    /// neighbors can never interpenetrate (by construction — there is no
    /// re-packing pass to bend geography). Each site takes the free lattice
    /// cell nearest its TRUE projected anchor; sites seat
    /// farthest-from-median first, so far-flung jobs land on their true spots
    /// almost exactly and a dense metro cluster fills the cells around where
    /// the metro actually is. The honesty traded away is cell granularity:
    /// sites closer together than one cell (the crushed metro at state
    /// scale) sit in adjacent cells in deterministic order — their cluster
    /// shape tracks truth, their exact offsets do not.
    private static func spreadAlongBearings(_ rects: inout [String: BoardRect],
                                            anchors: [String: SIMD2<Float>],
                                            around center: SIMD2<Float>,
                                            office: BoardRect) {
        let layoutMin = SIMD2(-WorldBoard.size.x / 2 + WorldBoard.sceneryWidth,
                              -WorldBoard.size.y / 2 + 3.0)
        let layoutMax = WorldBoard.size / 2 - SIMD2(Float(3.0), Float(3.0))

        // Cell size clears the LARGEST footprint (all cells equivalent),
        // plus the building gap on both sides.
        let widest = rects.values.reduce(Float(0)) { max($0, $1.halfExtents.x * 2) }
        let maxDepth = rects.values.reduce(Float(0)) { max($0, $1.halfExtents.y * 2) }

        func fits(_ c: SIMD2<Float>, _ rect: BoardRect) -> Bool {
            let half = rect.halfExtents
            let inLayout = c.x - half.x >= layoutMin.x && c.x + half.x <= layoutMax.x &&
                c.y - half.y >= layoutMin.y && c.y + half.y <= layoutMax.y
            guard inLayout else { return false }
            let candidate = BoardRect(center: c, halfExtents: half)
            return !candidate.overlaps(office, gap: WorldBoard.buildingGap)
        }

        // A rectangular lattice sized to the largest footprint (plus the gap
        // on both sides): one cell per building, ever, so neighbors can never
        // interpenetrate. The board is portrait; a plain grid packs it far
        // better than a hex one, whose wide columns waste the narrow deck.
        let cellWidth = widest + WorldBoard.buildingGap * 2
        let cellDepth = maxDepth + WorldBoard.buildingGap * 2
        func cellCenter(_ i: Int, _ j: Int) -> SIMD2<Float> {
            SIMD2(cellWidth * Float(i), cellDepth * Float(j))
        }
        func nearestCell(to p: SIMD2<Float>) -> (i: Int, j: Int) {
            (Int((p.x / cellWidth).rounded()), Int((p.y / cellDepth).rounded()))
        }

        var taken = Set<String>()
        func seat(_ id: String, _ i: Int, _ j: Int) {
            taken.insert("\(i),\(j)")
            rects[id]?.center = cellCenter(i, j)
        }

        // Deterministic order: farthest true anchor from the median first —
        // outer truth anchors the board, the metro fills in last.
        let order = rects.keys.sorted {
            let da = simd_distance(anchors[$0] ?? center, center)
            let db = simd_distance(anchors[$1] ?? center, center)
            return da != db ? da > db : $0 < $1
        }

        for id in order {
            guard let rect = rects[id] else { continue }
            let anchor = anchors[id] ?? center
            let home = nearestCell(to: anchor)

            // Ring 0 is the home cell; each Chebyshev ring after wraps it.
            // Candidates within a ring are tried nearest-to-truth first
            // (distance, then angle, then cell coords — all deterministic).
            var seatedHere = false
            search: for ring in 0...12 {
                var ringCells: [(i: Int, j: Int)] = []
                if ring == 0 {
                    ringCells.append(home)
                } else {
                    for di in -ring...ring {
                        for dj in -ring...ring where max(abs(di), abs(dj)) == ring {
                            ringCells.append((home.i + di, home.j + dj))
                        }
                    }
                }
                let candidates = ringCells
                    .filter { !taken.contains("\($0.i),\($0.j)") }
                    .map { cell -> (cell: (i: Int, j: Int), c: SIMD2<Float>, d: Float, a: Float) in
                        let c = cellCenter(cell.i, cell.j)
                        let delta = c - anchor
                        return (cell, c, simd_length(delta), atan2(delta.y, delta.x))
                    }
                    .filter { fits($0.c, rect) }
                    .sorted { ($0.d, $0.a, $0.cell.i, $0.cell.j) < ($1.d, $1.a, $1.cell.i, $1.cell.j) }
                if let best = candidates.first {
                    seat(id, best.cell.i, best.cell.j)
                    seatedHere = true
                    break search
                }
            }

            // A board with no cell left (far more sites than today): clamp
            // the true point and let the geometry be as honest as it can.
            if !seatedHere {
                rects[id]?.center = SIMD2(
                    min(max(anchor.x, layoutMin.x + rect.halfExtents.x), layoutMax.x - rect.halfExtents.x),
                    min(max(anchor.y, layoutMin.y + rect.halfExtents.y), layoutMax.y - rect.halfExtents.y))
            }
        }
    }
}

// MARK: - Walking (pure movement + targeting)

/// Movement and targeting rules the world scene runs every frame — pure, so
/// the feel of walking is testable without a renderer.
enum WorldWalk {
    /// The walker's collision radius.
    static let playerRadius: Float = 0.65
    /// Close enough to a walk target to stop.
    static let stopRadius: Float = 0.45

    /// Clamp a point into a rect.
    static func clamp(_ p: SIMD2<Float>, to rect: BoardRect) -> SIMD2<Float> {
        rect.clampPoint(p)
    }

    /// Does a circle at `center` (radius `radius`) overlap the rect?
    static func overlaps(rect: BoardRect, circle center: SIMD2<Float>, radius: Float) -> Bool {
        let q = rect.clampPoint(center)
        return simd_distance(q, center) < radius
    }

    /// Move by `delta`, sliding around obstacles instead of sticking: each
    /// axis is tried alone and skipped when it would collide. Keeps diagonal
    /// approach useful and corners forgiving.
    static func slide(from p: SIMD2<Float>, delta: SIMD2<Float>,
                      obstacles: [BoardRect], bounds: BoardRect,
                      radius: Float = WorldWalk.playerRadius) -> SIMD2<Float> {
        var next = p
        let stepX = SIMD2<Float>(delta.x, 0)
        if !obstacles.contains(where: { overlaps(rect: $0, circle: p + stepX, radius: radius) }) {
            next += stepX
        }
        let stepY = SIMD2<Float>(0, delta.y)
        if !obstacles.contains(where: { overlaps(rect: $0, circle: next + stepY, radius: radius) }) {
            next += stepY
        }
        return clamp(next, to: bounds)
    }

    /// A good place to stand near a rect: the boundary point nearest `from`,
    /// pushed `standoff` meters further out. From inside the rect, exit via
    /// the nearest face.
    static func approachPoint(for rect: BoardRect, from p: SIMD2<Float>,
                              standoff: Float = 2.4) -> SIMD2<Float> {
        let q = rect.clampPoint(p)
        var out: SIMD2<Float>
        if rect.contains(p) {
            // Exit through whichever face is closest.
            let distances = [p.y - rect.minY, rect.maxY - p.y, p.x - rect.minX, rect.maxX - p.x]
            switch distances.indices.min(by: { distances[$0] < distances[$1] })! {
            case 0: out = SIMD2(p.x, rect.minY - standoff)
            case 1: out = SIMD2(p.x, rect.maxY + standoff)
            case 2: out = SIMD2(rect.minX - standoff, p.y)
            default: out = SIMD2(rect.maxX + standoff, p.y)
            }
        } else {
            var dir = p - q
            if simd_length(dir) < 0.001 { dir = SIMD2(0, 1) }
            out = q + normalize(dir) * standoff
        }
        return out
    }

    /// One step toward a target at `speed` for `dt`. Returns the new
    /// position, whether the walk is done, and the travel heading in radians
    /// (atan2-style: 0 = +y/south, positive = clockwise toward +x/east).
    static func stepToward(from p: SIMD2<Float>, target: SIMD2<Float>,
                           speed: Float, dt: Float,
                           stopRadius: Float = WorldWalk.stopRadius)
    -> (position: SIMD2<Float>, arrived: Bool, heading: Float?) {
        let delta = target - p
        let distance = simd_length(delta)
        guard distance > stopRadius else { return (p, true, nil) }
        let stepLength = min(speed * dt, distance)
        let heading = atan2(delta.x, delta.y)
        return (p + delta / distance * stepLength, stepLength >= distance, heading)
    }

    /// What a tap on the ground means: the building under the finger, or the
    /// tapped point itself. `tapSlop` forgives near-misses on small buildings.
    static func resolveTap(_ p: SIMD2<Float>,
                           footprints: [(id: String, rect: BoardRect)],
                           tapSlop: Float = 1.2) -> WalkTarget {
        let hit = footprints.first { $0.rect.contains(p, pad: tapSlop) }
        return hit.map { .site($0.id) } ?? .point(p)
    }

    /// The nearest site within `maxDistance` of a point, if any.
    static func nearestSite(to p: SIMD2<Float>,
                            positions: [(String, SIMD2<Float>)],
                            maxDistance: Float) -> String? {
        positions
            .filter { simd_distance($0.1, p) <= maxDistance }
            .min { simd_distance($0.1, p) < simd_distance($1.1, p) }?.0
    }
}

/// Where a tap sends the player.
enum WalkTarget: Equatable {
    case point(SIMD2<Float>)
    case site(String)
}
