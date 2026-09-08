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
            // The region sites may occupy: padded, and clear of the ocean.
            let regionMin = SIMD2(-WorldBoard.size.x / 2 + WorldBoard.sceneryWidth,
                                  -WorldBoard.size.y / 2 + WorldBoard.padding)
            let regionMax = SIMD2(WorldBoard.size.x / 2 - WorldBoard.padding,
                                  WorldBoard.size.y / 2 - WorldBoard.padding)
            // usable = region minus the fit margin ON EACH SIDE, so a cloud
            // that fills `usable` leaves room for its buildings' halves.
            let usable = regionMax - regionMin - SIMD2(WorldBoard.fitMargin * 2, WorldBoard.fitMargin * 2)
            let regionCenter = (regionMin + regionMax) / 2
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

        // Footprints from board positions, then push everything apart so no
        // two buildings interpenetrate and none swallows the office.
        var footprints: [String: BoardRect] = [:]
        for site in geocoded {
            guard let p = positions[site.id] else { continue }
            let size = WorldBoard.buildingSize(category: site.scopeLabel,
                                               phase: site.phase)
            footprints[site.id] = BoardRect.size(size.x, size.y, at: p)
        }
        WorldBoard.separate(&footprints, from: officeFootprint)

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

    /// Push building footprints apart (and away from the office) until they
    /// clear each other by `buildingGap`. Deterministic: pairs are visited
    /// in id order and nudged along the short axis each time.
    private static func separate(_ rects: inout [String: BoardRect], from office: BoardRect) {
        let ids = rects.keys.sorted()
        let layoutMin = SIMD2(-WorldBoard.size.x / 2 + WorldBoard.sceneryWidth,
                              -WorldBoard.size.y / 2 + 3.0)
        let layoutMax = WorldBoard.size / 2 - SIMD2(Float(3.0), Float(3.0))
        for _ in 0..<14 {
            var movedAnything = false
            for i in ids.indices {
                for j in i + 1..<ids.count {
                    guard let a = rects[ids[i]], let b = rects[ids[j]] else { continue }
                    if !a.overlaps(b, gap: WorldBoard.buildingGap) { continue }
                    var separation = WorldBoard.separationVector(a: a, b: b,
                                                                  gap: WorldBoard.buildingGap)
                    if separation == .zero {
                        // Perfectly stacked sites: part them deterministically.
                        separation = SIMD2(a.halfExtents.x + b.halfExtents.x + WorldBoard.buildingGap, 0)
                    }
                    rects[ids[i]]?.center -= separation / 2
                    rects[ids[j]]?.center += separation / 2
                    movedAnything = true
                }
            }
            // Keep the office corner sacred: shove sites out of its lot. Each
            // escape axis flips when it would shove the site off the board —
            // on a narrow board there isn't always room on the obvious side.
            for id in ids {
                guard var rect = rects[id], rect.overlaps(office, gap: WorldBoard.buildingGap) else { continue }
                var separation = WorldBoard.separationVector(a: rect, b: office,
                                                              gap: WorldBoard.buildingGap)
                if separation == .zero {
                    separation = SIMD2(-(rect.halfExtents.x + office.halfExtents.x + WorldBoard.buildingGap), 0)
                }
                if rect.center.x + separation.x + rect.halfExtents.x > layoutMax.x ||
                    rect.center.x + separation.x - rect.halfExtents.x < layoutMin.x {
                    separation.x = -separation.x
                }
                if rect.center.y + separation.y + rect.halfExtents.y > layoutMax.y ||
                    rect.center.y + separation.y - rect.halfExtents.y < layoutMin.y {
                    separation.y = -separation.y
                }
                rect.center += separation
                rects[id] = rect
                movedAnything = true
            }
            // And on the board itself.
            for id in ids {
                guard var rect = rects[id] else { continue }
                let clamped = BoardRect(
                    min: simd_max(SIMD2(rect.minX, rect.minY), layoutMin),
                    max: simd_min(SIMD2(rect.maxX, rect.maxY), layoutMax))
                if clamped.center != rect.center { movedAnything = true }
                rect.center = clamped.center
                rects[id] = rect
            }
            if !movedAnything { break }
        }
    }

    /// How much to move `b` along each axis so it clears `a` (positive values).
    private static func separationVector(a: BoardRect, b: BoardRect, gap: Float) -> SIMD2<Float> {
        let dx = a.halfExtents.x + b.halfExtents.x + gap - abs(b.center.x - a.center.x)
        let dy = a.halfExtents.y + b.halfExtents.y + gap - abs(b.center.y - a.center.y)
        let signX: Float = b.center.x >= a.center.x ? 1 : -1
        let signY: Float = b.center.y >= a.center.y ? 1 : -1
        return SIMD2(max(dx, 0) * signX, max(dy, 0) * signY)
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
