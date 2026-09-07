//  WorldMapperTests.swift
//  OfficeAdminGameTests
//
//  WorldMapper against fixture JSON captured from the real /api/v1 wire
//  shapes (envelopes, cents, ISO-ms timestamps, stringified lat/lng). The
//  "now" of each map is pinned so crew placement and whiteboard dates are
//  deterministic.

import XCTest
@testable import OfficeAdminGame

final class WorldMapperTests: XCTestCase {

    // Fixture "now": 2026-09-07 16:30 UTC — Mike is clocked in (started
    // 14:32Z), Nick's 15:00Z shift is underway, Kimura's invoice is 11 days
    // overdue, Whitfield's is due in 3 days.
    private let now = OAWire.parseISO("2026-09-07T16:30:00.000Z")!

    private lazy var inputs: WorldInputs = WorldInputs(
        projectDetails: [
            load("projects-detail", as: OAProjectDetailEnvelope.self).project,
            load("projects-detail-no-coords", as: OAProjectDetailEnvelope.self).project,
        ],
        shifts: load("scheduled-shifts", as: OAScheduledShiftsEnvelope.self).shifts,
        clock: load("clock", as: OAClockSnapshot.self),
        approvals: load("approval-requests", as: OAPaginated<OAApprovalRequest>.self).data,
        invoices: load("invoices", as: OAPaginated<OAInvoice>.self).data,
        invoiceSummary: load("invoice-summary", as: OAInvoiceSummary.self),
        playerProfileName: nil,
        now: now)

    private lazy var world: WorldState = WorldMapper.map(inputs)

    // MARK: Wire decoding

    func testPaginatedEnvelopeDecodes() throws {
        let projects = load("projects-list", as: OAPaginated<OAProjectListItem>.self)
        XCTAssertEqual(projects.data.count, 3)
        XCTAssertEqual(projects.pagination?.total, 3)
        XCTAssertEqual(projects.data[0].contact?.name, "Kenji Kimura")
        XCTAssertEqual(projects.data[0].budget, 875_000, "money arrives in cents")
    }

    func testProjectDetailDecodesStringCoordinates() throws {
        let detail = load("projects-detail", as: OAProjectDetailEnvelope.self).project
        XCTAssertEqual(detail.siteLat, 34.1017, "numeric columns arrive as strings")
        XCTAssertEqual(detail.siteLng, -118.3391)
        XCTAssertEqual(detail.siteAddress, "1840 N Highland Ave, Los Angeles, CA 90028")
        XCTAssertEqual(detail.milestones?.count, 2)
    }

    func testTimestampsWithMillisecondsDecode() throws {
        let approvals = load("approval-requests", as: OAPaginated<OAApprovalRequest>.self).data
        XCTAssertEqual(approvals[0].createdAt, OAWire.parseISO("2026-09-06T18:22:31.120Z"))
    }

    // MARK: Sites

    func testSitePlacedAtRealCoordinates() throws {
        let kimura = try XCTUnwrap(world.sites.first { $0.name.contains("Kimura") })
        let coordinate = try XCTUnwrap(kimura.coordinate)
        XCTAssertEqual(coordinate.latitude, 34.1017, accuracy: 0.0001)
        XCTAssertEqual(coordinate.longitude, -118.3391, accuracy: 0.0001)
        XCTAssertEqual(kimura.phase, .active)
        XCTAssertEqual(kimura.scopeLabel, "Service upgrade")
        XCTAssertEqual(kimura.customerName, "Kenji Kimura")
    }

    func testSiteWithoutCoordinatesWaitsForGeocoding() throws {
        let whitfield = try XCTUnwrap(world.sites.first { $0.name.contains("Whitfield") })
        XCTAssertNil(whitfield.coordinate)
        XCTAssertEqual(whitfield.pendingGeocodeAddress,
                       "1428 N Beverly Glen Blvd, Los Angeles, CA 90077")
        XCTAssertEqual(world.sitesNeedingGeocoding.count, 1)
    }

    func testMilestoneProgressAverages() throws {
        let kimura = try XCTUnwrap(world.sites.first { $0.name.contains("Kimura") })
        XCTAssertEqual(kimura.progressPercent, 80, "(100 + 60) / 2")
    }

    func testCrewPresentAttachedToSite() throws {
        let kimura = try XCTUnwrap(world.sites.first { $0.name.contains("Kimura") })
        XCTAssertEqual(kimura.crewPresent, ["Mike Shaffer"], "running clock entry puts him on the site")
        XCTAssertEqual(kimura.crewScheduled, [], "tomorrow's shift does not schedule anyone today")

        let whitfield = try XCTUnwrap(world.sites.first { $0.name.contains("Whitfield") })
        XCTAssertEqual(whitfield.crewScheduled, ["Nick Brandon"], "today's shift schedules Nick there")
    }

    func testInvoiceApprovalWaitsAtCustomerSite() throws {
        let kimura = try XCTUnwrap(world.sites.first { $0.name.contains("Kimura") })
        XCTAssertEqual(kimura.waitingMailCount, 1,
                       "the pending invoice approval for Kenji waits at his site")
    }

    // MARK: Crew

    func testClockedInPlayerAtSite() throws {
        let mike = try XCTUnwrap(world.crew.first { $0.isPlayer })
        XCTAssertEqual(mike.name, "Mike Shaffer")
        XCTAssertTrue(mike.isClockedIn)
        guard case .atSite(let siteID, let siteName) = mike.assignment else {
            return XCTFail("expected Mike on site, got \(mike.assignment)")
        }
        XCTAssertEqual(siteID, "0b1c2d3e-4f50-4a1b-8c2d-9e0f1a2b3c4d")
        XCTAssertTrue(siteName.contains("Kimura"))
    }

    func testCrewWithTodaysShiftIsOnTheRoad() throws {
        let nick = try XCTUnwrap(world.crew.first { $0.name == "Nick Brandon" })
        XCTAssertFalse(nick.isClockedIn)
        guard case .onRoad(let siteID, _) = nick.assignment else {
            return XCTFail("expected Nick on the road, got \(nick.assignment)")
        }
        XCTAssertEqual(siteID, "aa11bb22-cc33-4d44-8e55-ff6677889900",
                       "today's shift, not tomorrow's")
    }

    func testUnassignedCrewInTheOffice() throws {
        let maricar = try XCTUnwrap(world.crew.first { $0.name.contains("Maricar") })
        XCTAssertEqual(maricar.assignment, .office)
    }

    // MARK: Mail

    func testPendingApprovalsBecomeMail() {
        XCTAssertEqual(world.mail.count, 2, "approved requests never reach the desk")
        XCTAssertEqual(Set(world.mail.map(\.kind)),
                       [.invoice, .purchaseOrder])
        XCTAssertEqual(world.mail[0].kind, .invoice, "newest mail on top")
        XCTAssertEqual(world.mail[0].workflowName, "Large invoices")
        XCTAssertEqual(world.mail[0].fromName, "Mike Shaffer")
        XCTAssertEqual(world.mail[0].envelopeTitle, "Invoice — Large invoices")
    }

    // MARK: Money as world state

    func testMoneyStateFromSummary() {
        XCTAssertEqual(world.money.outstandingCents, 2_561_125)
        XCTAssertEqual(world.money.outstandingCount, 2)
        XCTAssertEqual(world.money.overdueCents, 2_016_125)
        XCTAssertEqual(world.money.overdueCount, 1)
        XCTAssertTrue(world.money.hasOverdue)
    }

    func testMoneyStateFallbackFromInvoiceList() {
        var noSummary = inputs
        noSummary.invoiceSummary = nil
        let money = WorldMapper.money(noSummary)
        XCTAssertEqual(money.outstandingCount, 2, "sent + overdue, paid excluded")
        XCTAssertEqual(money.overdueCount, 1)
    }

    func testWhiteboardPinsOverdueAndComingDue() throws {
        XCTAssertEqual(world.whiteboard.count, 2, "paid and far-future invoices stay off the board")
        let overdue = try XCTUnwrap(world.whiteboard.first)
        XCTAssertEqual(overdue.invoiceNumber, "INV-00123")
        XCTAssertTrue(overdue.isUrgent)
        guard case .overdue(let days) = overdue.state else {
            return XCTFail("expected overdue state")
        }
        XCTAssertEqual(days, 11)
        XCTAssertEqual(world.whiteboard.last?.invoiceNumber, "INV-00124")
    }

    func testAttentionCountSeesMailAndOverdue() {
        XCTAssertEqual(world.attentionCount, 3, "2 mail + 1 overdue")
    }

    // MARK: Player identity

    func testPlayerNameFallsBackToClockRoster() {
        XCTAssertEqual(world.playerName, "Mike Shaffer")
    }

    func testRuntimeEnvironmentBuildsNonPersistentCredentials() throws {
        let credentials = try XCTUnwrap(GameCredentials.fromEnvironment([
            GameCredentials.baseURLEnvironmentKey: "https://officeadmin.example",
            GameCredentials.apiKeyEnvironmentKey: "dk_test_only",
            GameCredentials.organizationIDEnvironmentKey: "org-test",
        ]))
        XCTAssertEqual(credentials.baseURL.absoluteString, "https://officeadmin.example")
        XCTAssertEqual(credentials.apiKey, "dk_test_only")
        XCTAssertEqual(credentials.organizationId, "org-test")
    }

    func testRuntimeEnvironmentRequiresURLAndKey() {
        XCTAssertNil(GameCredentials.fromEnvironment([:]))
        XCTAssertNil(GameCredentials.fromEnvironment([
            GameCredentials.baseURLEnvironmentKey: "https://officeadmin.example",
        ]))
    }

    // MARK: - Fixture helpers

    private func fixture<T: Decodable>(_ name: String, as type: T.Type = T.self) -> T {
        load(name, as: type)
    }

    private func load<T: Decodable>(_ name: String, as type: T.Type) -> T {
        do {
            return try OAWire.decoder.decode(T.self, from: try data(name))
        } catch {
            fatalError("fixture \(name) failed to decode as \(type): \(error)")
        }
    }

    private func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: WorldMapperTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"),
                                "missing fixture \(name).json")
        return try Data(contentsOf: url)
    }

}
