//  WorldBoardTests.swift
//  OfficeAdminGame
//
//  The board layout and walking rules — pure functions, so they're tested
//  straight against known coordinates and hand-built rects.

import CoreLocation
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
