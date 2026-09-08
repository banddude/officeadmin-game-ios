//  WorldBoardTests.swift
//  OfficeAdminGame
//
//  The board layout and walking rules — pure functions, so they're tested
//  straight against known coordinates and hand-built rects.

import CoreLocation
import simd
import XCTest
@testable import OfficeAdminGame

final class WorldBoardTests: XCTestCase {

    // MARK: - Mercator projection

    func testMercatorMetersForOneDegree() {
        // East-west: 0.01° of longitude is ~1113.19 m anywhere.
        let a = WorldBoard.mercatorMeters(CLLocationCoordinate2D(latitude: 34.05, longitude: -118.30))
        let b = WorldBoard.mercatorMeters(CLLocationCoordinate2D(latitude: 34.05, longitude: -118.29))
        XCTAssertEqual(b.x - a.x, 1113.19, accuracy: 0.5)

        // North-south at LA's latitude the Mercator stretches by 1/cos(lat).
        let c = WorldBoard.mercatorMeters(CLLocationCoordinate2D(latitude: 34.06, longitude: -118.30))
        let stretch = 1 / cos(34.05 * .pi / 180)
        XCTAssertEqual(c.y - a.y, 1113.19 * stretch, accuracy: 2.0)
    }

    // MARK: - Layout

    private func site(_ id: String, name: String = "Site",
                      lat: Double, lng: Double,
                      category: String? = nil,
                      status: String = "active") -> WorldSite {
        WorldSite(id: id, name: name, scopeLabel: category, customerName: nil,
                  phase: WorldSite.Phase(rawStatus: status)!,
                  coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                  pendingGeocodeAddress: nil, budgetCents: nil, billedCents: nil,
                  progressPercent: nil, crewPresent: [], crewScheduled: [],
                  waitingMailCount: 0)
    }

    func testLayoutPlacesEastAndNorthCorrectly() throws {
        let board = WorldBoard(sites: [
            site("west", lat: 34.05, lng: -118.30),
            site("east", lat: 34.05, lng: -118.10),
            site("north", lat: 34.09, lng: -118.20),
        ])
        let west = try XCTUnwrap(board.sitePositions["west"])
        let east = try XCTUnwrap(board.sitePositions["east"])
        let north = try XCTUnwrap(board.sitePositions["north"])
        XCTAssertGreaterThan(east.x, west.x, "east of = larger board x")
        XCTAssertLessThan(north.y, (west.y + east.y) / 2,
                          "board y is south, so north of center is smaller y")
    }

    func testLayoutFitsPaddedBoardAndKeepsProportions() throws {
        // A NE/SW diagonal: both ends land away from the office's SE corner,
        // so nothing gets shoved and proportions survive the fit exactly.
        let board = WorldBoard(sites: [
            site("ne", lat: 34.32, lng: -117.84),
            site("sw", lat: 33.78, lng: -118.24),
        ])
        let ne = try XCTUnwrap(board.sitePositions["ne"])
        let sw = try XCTUnwrap(board.sitePositions["sw"])

        let regionMin = SIMD2(-WorldBoard.size.x / 2 + WorldBoard.sceneryWidth,
                              -WorldBoard.size.y / 2 + WorldBoard.padding)
        let regionMax = SIMD2(WorldBoard.size.x / 2 - WorldBoard.padding,
                              WorldBoard.size.y / 2 - WorldBoard.padding)
        for p in [ne, sw] {
            XCTAssertGreaterThan(p.x, regionMin.x - 0.5, "site x east of the scenery band")
            XCTAssertLessThan(p.x, regionMax.x + 0.5, "site x inside the padded board")
            XCTAssertGreaterThan(p.y, regionMin.y - 0.5)
            XCTAssertLessThan(p.y, regionMax.y + 0.5)
        }

        // A single uniform scale means board proportions == mercator proportions.
        let spanX = abs(ne.x - sw.x), spanY = abs(ne.y - sw.y)
        let meters = WorldBoard.mercatorMeters(CLLocationCoordinate2D(latitude: 34.32, longitude: -117.84))
        let other = WorldBoard.mercatorMeters(CLLocationCoordinate2D(latitude: 33.78, longitude: -118.24))
        let meterRatio = abs(other.x - meters.x) / abs(other.y - meters.y)
        XCTAssertEqual(spanX / spanY, Float(meterRatio), accuracy: 0.02 * Float(meterRatio))
    }

    func testFallbackToLosAngelesWhenNothingGeocodes() {
        let board = WorldBoard(sites: [
            site("no-coords", lat: 0, lng: 0).noCoordinate(),
        ])
        XCTAssertTrue(board.usedFallbackOrigin)
        XCTAssertEqual(board.origin.latitude, WorldBoard.losAngelesCenter.latitude, accuracy: 0.0001)
        XCTAssertTrue(board.sitePositions.isEmpty)
        XCTAssertGreaterThan(board.officePosition.x, 0)
        XCTAssertGreaterThan(board.officePosition.y, 0, "office lives in the south-east corner")
        XCTAssertFalse(board.officeFootprint.contains(.zero))
    }

    func testCoincidentSitesAreSeparated() {
        let board = WorldBoard(sites: [
            site("one", lat: 34.05, lng: -118.24, category: "New build"),
            site("two", lat: 34.05, lng: -118.24, category: "New build"),
        ])
        let one = board.buildingFootprints["one"]
        let two = board.buildingFootprints["two"]
        XCTAssertNotNil(one)
        XCTAssertNotNil(two)
        XCTAssertFalse(one!.overlaps(two!),
                       "two projects at the same address still get their own buildings")
        XCTAssertEqual(board.sitePositions["one"], one!.center,
                       "positions follow nudged footprints")
    }

    func testSitesNeverBuryTheOfficeLot() throws {
        // Two sites whose bounding box puts one of them in the office corner:
        // it gets shoved, but the office keeps its lot.
        let board = WorldBoard(sites: [
            site("nw", lat: 34.32, lng: -118.44),
            site("se", lat: 33.78, lng: -118.04, category: "New build"),
        ])
        for rect in board.buildingFootprints.values {
            XCTAssertFalse(rect.overlaps(board.officeFootprint, gap: WorldBoard.buildingGap),
                           "the office keeps its corner")
        }
        let se = try XCTUnwrap(board.sitePositions["se"])
        XCTAssertGreaterThan(se.x, 0, "the south-east site stays in the eastern half")
    }

    // MARK: - Geography-preserving spread

    /// REAL project coordinates (from GeocodeSeed.json) spanning the state —
    /// Bay Area, Central Valley, the LA basin (where most jobs sit) and San
    /// Diego: after the board makes it walkable, well-separated jobs keep
    /// their true RELATIVE directions (the Bay stays north-west of San Diego,
    /// Orange County stays east of the basin), every building stays within a
    /// walk of its true projected point, and nothing interpenetrates.
    func testBearingsSurviveSpreading() throws {
        let sites = [
            site("novato", lat: 38.1099, lng: -122.5665),     // 819 Olive St
            site("sanjose", lat: 37.2345, lng: -121.7874),    // 6578 Santa Teresa Blvd
            site("coalinga", lat: 36.1353, lng: -120.3278),   // 1921 Mercantile Ln
            site("fowler", lat: 36.6349, lng: -119.6737),     // 658 E Adams Ave
            site("simi", lat: 34.2709, lng: -118.7705),       // 1492 E Los Angeles Ave
            site("santaclarita", lat: 34.4390, lng: -118.5719),// 24930 Avenue Stanford
            site("palisades", lat: 34.0483, lng: -118.5252),  // 1030 Swarthmore Ave
            site("encino", lat: 34.1574, lng: -118.5040),     // 17010 Rancho St
            site("pasadena", lat: 34.1616, lng: -118.3036),   // 215 Thompson Ave
            site("downtown", lat: 34.0935, lng: -118.3241),   // 1232 N El Centro Ave
            site("downey", lat: 33.9255, lng: -118.1298),     // 12126 Lakewood Blvd
            site("orange", lat: 33.8134, lng: -117.8664),     // 1577 N Main St
            site("sandiego", lat: 32.7018, lng: -117.0663),   // 6130 Skyline Drive
        ]
        let board = WorldBoard(sites: sites)

        // Mirror the board's own fit math to know each site's TRUE projected
        // point (the cloud's bounding box seated at the region center).
        let coords = sites.compactMap(\.coordinate)
        let lat = coords.map(\.latitude).reduce(0, +) / Double(coords.count)
        let lng = coords.map(\.longitude).reduce(0, +) / Double(coords.count)
        let centroid = WorldBoard.mercatorMeters(CLLocationCoordinate2D(latitude: lat, longitude: lng))
        let regionMin = SIMD2(-WorldBoard.size.x / 2 + WorldBoard.sceneryWidth,
                              -WorldBoard.size.y / 2 + WorldBoard.padding)
        let regionMax = SIMD2(WorldBoard.size.x / 2 - WorldBoard.padding,
                              WorldBoard.size.y / 2 - WorldBoard.padding)
        let regionCenter = (regionMin + regionMax) / 2
        let usable = regionMax - regionMin - SIMD2(WorldBoard.fitMargin * 2, WorldBoard.fitMargin * 2)
        let meters = sites.map { WorldBoard.mercatorMeters($0.coordinate!) - centroid }
        var lo = SIMD2<Double>.zero, hi = SIMD2<Double>.zero
        for m in meters {
            lo = simd_min(lo, SIMD2<Double>(m)); hi = simd_max(hi, SIMD2<Double>(m))
        }
        let span = hi - lo
        let scale = min(usable.x / Float(max(span.x, 0.001)),
                        usable.y / Float(max(span.y, 0.001)), 12)
        let cloudCenter = (lo + hi) / 2
        let anchors = Dictionary(uniqueKeysWithValues: meters.enumerated().map { i, m in
            (sites[i].id, regionCenter + SIMD2<Float>(m - cloudCenter) * scale * SIMD2<Float>(1, -1))
        })

        // Every building stays within a walk of its true point, on the board.
        let layoutMin = SIMD2(-WorldBoard.size.x / 2 + WorldBoard.sceneryWidth,
                              -WorldBoard.size.y / 2 + 3.0)
        let layoutMax = WorldBoard.size / 2 - SIMD2(Float(3.0), Float(3.0))
        for s in sites {
            let p = try XCTUnwrap(board.sitePositions[s.id], "\(s.id) placed")
            let anchor = try XCTUnwrap(anchors[s.id])
            XCTAssertLessThan(simd_distance(p, anchor), 22,
                              "\(s.id) stays near its true point")
            XCTAssertGreaterThan(p.x, layoutMin.x - 0.5, "\(s.id) in layout")
            XCTAssertLessThan(p.x, layoutMax.x + 0.5, "\(s.id) in layout")
            XCTAssertGreaterThan(p.y, layoutMin.y - 0.5, "\(s.id) in layout")
            XCTAssertLessThan(p.y, layoutMax.y + 0.5, "\(s.id) in layout")
        }

        // State-scale geography: pairs well-separated in truth keep their
        // true relative direction on the board (this is the property that
        // makes the world read "accurate to where each job is in CA").
        var maxTrueSeparation: Float = 0
        for i in sites.indices {
            for j in i + 1..<sites.count {
                maxTrueSeparation = max(maxTrueSeparation,
                                        simd_distance(anchors[sites[i].id]!, anchors[sites[j].id]!))
            }
        }
        for i in sites.indices {
            for j in i + 1..<sites.count {
                let a = anchors[sites[i].id]!, b = anchors[sites[j].id]!
                guard simd_distance(a, b) >= maxTrueSeparation * 0.65 else { continue }
                let pa = try XCTUnwrap(board.sitePositions[sites[i].id])
                let pb = try XCTUnwrap(board.sitePositions[sites[j].id])
                let trueBearing = atan2(b.y - a.y, b.x - a.x)
                let boardBearing = atan2(pb.y - pa.y, pb.x - pa.x)
                var delta = abs(boardBearing - trueBearing)
                if delta > .pi { delta = 2 * .pi - delta }
                XCTAssertLessThan(delta, 0.8,
                                  "\(sites[i].id)→\(sites[j].id) keeps its true direction (delta \(delta * 180 / .pi)°)")
            }
        }

        // And no two buildings interpenetrate anywhere.
        let rects = board.buildingFootprints.values.map { $0 }
        for i in rects.indices {
            for j in i + 1..<rects.count {
                XCTAssertFalse(rects[i].overlaps(rects[j]),
                               "buildings \(i)/\(j) clear each other")
            }
        }
    }

    /// A dense metro cluster blooms OUTWARD from its true spot: every
    /// building keeps (roughly) its own bearing from the center, nothing is
    /// re-packed into a village grid, and duplicate addresses still split.
    func testClusterBloomsAlongTrueBearings() throws {
        // Ten jobs inside a couple of kilometers of DTLA, plus a San Diego
        // outlier so the fit doesn't blow the cluster up to board size.
        var sites = (0..<10).map { i in
            site("la\(i)", lat: 34.05 + Double(i) * 0.002, lng: -118.25 + Double(i % 3) * 0.002)
        }
        sites.append(site("sd", lat: 32.70, lng: -117.07))
        let board = WorldBoard(sites: sites)

        XCTAssertEqual(board.buildingFootprints.count, 11, "all placed")
        let rects = board.buildingFootprints.values.map { $0 }
        for i in rects.indices {
            for j in i + 1..<rects.count {
                XCTAssertFalse(rects[i].overlaps(rects[j]), "cluster buildings stay clear")
            }
        }
        // The bloom keeps the cluster LOCAL: every LA building stays north of
        // the San Diego one (board y is south).
        let sdY = try XCTUnwrap(board.sitePositions["sd"]).y
        for i in 0..<10 {
            let y = try XCTUnwrap(board.sitePositions["la\(i)"]).y
            XCTAssertLessThan(y, sdY, "la\(i) stays north of San Diego")
        }
    }

    /// Same world in any order → identical board: the layout is a function of
    /// geography, not of the API's reply order.
    func testLayoutIsDeterministicUnderShuffledInput() {
        let sites = [
            site("a", lat: 38.11, lng: -122.57), site("b", lat: 34.05, lng: -118.25),
            site("c", lat: 32.70, lng: -117.07), site("d", lat: 36.14, lng: -120.33),
            site("e", lat: 34.27, lng: -118.77), site("f", lat: 33.81, lng: -117.87),
        ]
        let one = WorldBoard(sites: sites)
        let two = WorldBoard(sites: sites.reversed())
        XCTAssertEqual(one.sitePositions, two.sitePositions,
                       "site order does not change the board")
    }

    func testBuildingSizeFollowsCategoryAndPhase() {
        let base = WorldBoard.buildingSize(category: nil, phase: .active)
        let solar = WorldBoard.buildingSize(category: "Solar install", phase: .active)
        let lead = WorldBoard.buildingSize(category: nil, phase: .lead)
        XCTAssertGreaterThan(solar.x, base.x, "solar roofs read wider")
        XCTAssertLessThan(lead.x, base.x, "leads are still just an idea")
        XCTAssertLessThan(lead.y, base.y)
    }

    // MARK: - Walking

    private let block = BoardRect.size(2, 2, at: SIMD2(Float(2.2), Float(0)))
    private let bounds = BoardRect.size(
        WorldBoard.size.x - 4.8, WorldBoard.size.y - 4.8, at: .zero)

    func testClampKeepsPointInside() {
        let p = WorldWalk.clamp(SIMD2(Float(50), Float(-40)), to: bounds)
        XCTAssertEqual(p.x, WorldBoard.size.x / 2 - 2.4)
        XCTAssertEqual(p.y, -(WorldBoard.size.y / 2 - 2.4))
    }

    func testSlideGoesAroundObstaclesOneAxisAtATime() {
        // Headed straight into the block: x is blocked, y still moves.
        var next = WorldWalk.slide(from: .zero, delta: SIMD2(Float(1), Float(0.5)),
                                   obstacles: [block], bounds: bounds)
        XCTAssertEqual(next.x, 0, "the blocked axis does not move")
        XCTAssertEqual(next.y, 0.5)

        // Free direction passes through untouched.
        next = WorldWalk.slide(from: .zero, delta: SIMD2(Float(0), Float(2)),
                               obstacles: [block], bounds: bounds)
        XCTAssertEqual(next, SIMD2(Float(0), Float(2)))
    }

    func testApproachPointStandsOutsideTheBuilding() {
        // From the east: stop on the east face, standoff meters out.
        var point = WorldWalk.approachPoint(for: block, from: SIMD2(Float(10), Float(0)),
                                            standoff: 2)
        XCTAssertEqual(point.x, block.maxX + 2, accuracy: 0.001)
        XCTAssertEqual(point.y, 0, accuracy: 0.001)

        // From inside: leave through the nearest face.
        point = WorldWalk.approachPoint(for: block, from: SIMD2(Float(2.5), Float(0)),
                                        standoff: 2)
        XCTAssertEqual(point.x, block.maxX + 2, accuracy: 0.001,
                       "nearest face for x = 2.5 is the east one")
    }

    func testStepTowardMovesStopsAndReportsHeading() {
        let (p1, arrived1, heading1) = WorldWalk.stepToward(
            from: .zero, target: SIMD2(Float(10), Float(0)), speed: 5, dt: 1)
        XCTAssertEqual(p1.x, 5)
        XCTAssertFalse(arrived1)
        XCTAssertEqual(heading1!, .pi / 2, accuracy: 0.001, "heading east")

        let (p2, arrived2, _) = WorldWalk.stepToward(
            from: .zero, target: SIMD2(Float(10), Float(0)), speed: 5, dt: 3)
        XCTAssertEqual(p2.x, 10, "no overshoot: the step is clamped to the target")
        XCTAssertTrue(arrived2)

        let (_, arrived3, heading3) = WorldWalk.stepToward(
            from: .zero, target: SIMD2(Float(0.2), Float(0)), speed: 5, dt: 1)
        XCTAssertTrue(arrived3, "already inside stop radius")
        XCTAssertNil(heading3)
    }

    func testResolveTapPicksBuildingsAndForgivesNearMisses() {
        let footprints = [(id: "b1", rect: BoardRect.size(4, 4, at: SIMD2(Float(5), Float(5))))]
        XCTAssertEqual(WorldWalk.resolveTap(SIMD2(Float(5), Float(5)), footprints: footprints),
                       .site("b1"))
        XCTAssertEqual(WorldWalk.resolveTap(SIMD2(Float(5), Float(7.4)), footprints: footprints),
                       .site("b1"), "within the tap slop")
        XCTAssertEqual(WorldWalk.resolveTap(SIMD2(Float(-20), Float(0)), footprints: footprints),
                       .point(SIMD2(Float(-20), Float(0))))
    }

    func testNearestSiteWithinRadius() {
        let positions: [(String, SIMD2<Float>)] = [
            ("near", SIMD2(Float(5), Float(0))),
            ("far", SIMD2(Float(-9), Float(0))),
        ]
        XCTAssertEqual(WorldWalk.nearestSite(to: SIMD2(Float(4), Float(0)),
                                             positions: positions, maxDistance: 2), "near")
        XCTAssertNil(WorldWalk.nearestSite(to: SIMD2(Float(20), Float(0)),
                                           positions: positions, maxDistance: 2))
    }
}

private extension WorldSite {
    /// Drop the coordinate to model "nothing geocoded".
    func noCoordinate() -> WorldSite {
        var copy = self
        copy.coordinate = nil
        return copy
    }
}
