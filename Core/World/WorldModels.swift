//  WorldModels.swift
//  OfficeAdminGame
//
//  The world the API is mapped INTO. These are value types describing what
//  exists in the game — sites, crew, mail, money — with no rendering and no
//  networking, so WorldMapper can be pure and unit-tested against fixtures.

import CoreLocation
import Foundation

// MARK: - Rules

/// Cross-cutting domain rules the mapper and scenes share.
enum WorldRules {
    /// Project statuses that exist as placed sites in the world. Completed
    /// jobs fade out of the world; lost/archived never appear.
    static let liveSiteStatuses = ["lead", "estimating", "bid_sent", "active", "on_hold"]

    /// How many days out an invoice counts as "coming due" on the whiteboard.
    static let whiteboardComingDueDays = 7

    /// Plausible coordinate bounds (roughly California-sized box) — a guard
    /// against garbage lat/lng in the data placing a site in space.
    static func isPlausible(_ c: CLLocationCoordinate2D) -> Bool {
        abs(c.latitude) <= 90 && abs(c.longitude) <= 180 &&
        !(c.latitude == 0 && c.longitude == 0)
    }
}

// MARK: - Sites

/// A job site placed on the real-world map, from one project.
struct WorldSite: Identifiable, Equatable {
    let id: String                 // project id
    let name: String
    /// A short real-data scope label for the map pin. Today this is the
    /// project's category; a richer scope field can replace it later.
    let scopeLabel: String?
    let customerName: String?
    let phase: Phase
    /// Real-world coordinate, from the project record when it has one, else
    /// geocoded later from `pendingGeocodeAddress` (nil until then).
    var coordinate: CLLocationCoordinate2D?
    var pendingGeocodeAddress: String?
    let budgetCents: Int?
    let billedCents: Int?
    /// Mean of milestone progressPercent (0-100), nil when no milestones.
    let progressPercent: Int?
    /// Crew clocked in here right now (names).
    var crewPresent: [String]
    /// Crew scheduled here today (names), when not currently clocked in.
    var crewScheduled: [String]
    /// Approvals waiting that belong to this site's customer.
    var waitingMailCount: Int

    enum Phase: String, Equatable {
        case lead, estimating, bidSent = "bid_sent", active, onHold = "on_hold"

        init?(rawStatus: String) {
            self.init(rawValue: rawStatus)
        }

        /// Marker look: sites rise as they firm up.
        var sortOrder: Int {
            switch self {
            case .lead: return 0
            case .estimating: return 1
            case .bidSent: return 2
            case .onHold: return 3
            case .active: return 4
            }
        }

        var label: String {
            switch self {
            case .lead: return "Lead"
            case .estimating: return "Estimating"
            case .bidSent: return "Bid sent"
            case .onHold: return "On hold"
            case .active: return "Active job"
            }
        }
    }

    static func == (lhs: WorldSite, rhs: WorldSite) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Crew

/// A person in the world — crew, Mike, Maricar — placed where the data says
/// they are right now.
struct WorldCrewMember: Identifiable, Equatable {
    let id: String                 // users.id
    let name: String
    let role: String?
    let email: String?
    let assignment: Assignment
    let isPlayer: Bool
    /// True when a running time entry puts them on a site right now.
    let isClockedIn: Bool
    /// True for the server's own automation accounts, which are people-shaped
    /// in the member list but never stand anywhere. Computed at map time.
    let isServiceAccount: Bool

    enum Assignment: Equatable {
        case atSite(siteID: String, siteName: String)
        case office
        /// Scheduled to be somewhere later today (shown as walking there).
        case onRoad(toSiteID: String, siteName: String)
        case offToday
    }

    var assignmentSiteID: String? {
        switch assignment {
        case .atSite(let siteID, _): return siteID
        case .onRoad(let siteID, _): return siteID
        case .office, .offToday: return nil
        }
    }

    /// Automation accounts carry mail on the server's own domain (or a
    /// `.local` host). They get API access, not a body on the board.
    static func serviceAccount(email: String?, serverHost: String?) -> Bool {
        guard let email,
              let at = email.lastIndex(of: "@"),
              at < email.index(before: email.endIndex) else { return false }
        let host = String(email[email.index(after: at)...]).lowercased()
        if host.hasSuffix(".local") { return true }
        guard let serverHost = serverHost?.lowercased(), !serverHost.isEmpty else { return false }
        return host == serverHost || host.hasSuffix("." + serverHost)
    }
}

// MARK: - Mail (quests)

/// One piece of mail on the desk = one pending approval request.
struct WorldMailItem: Identifiable, Equatable {
    let id: String                 // approval request id
    let kind: Kind
    let workflowName: String
    let fromName: String?
    let createdAt: Date
    let stepOrder: Int
    /// The job site this piece belongs to (invoice approvals link through the
    /// customer to their project); nil means it waits at the office instead.
    var siteID: String?

    /// What the underlying record is (drives the envelope's wax seal).
    enum Kind: String, Equatable {
        case bill, expense, invoice, journalEntry = "journal_entry", purchaseOrder = "purchase_order"

        init?(rawEntityType: String) {
            self.init(rawValue: rawEntityType)
        }

        var label: String {
            switch self {
            case .bill: return "Bill"
            case .expense: return "Expense"
            case .invoice: return "Invoice"
            case .journalEntry: return "Journal entry"
            case .purchaseOrder: return "Purchase order"
            }
        }
    }

    /// The one-line text on the envelope.
    var envelopeTitle: String {
        let wf = workflowName.isEmpty ? "Approval" : workflowName
        return "\(kind.label) — \(wf)"
    }
}

// MARK: - Money as world state

/// Money shown by the WORLD changing, never by a chart: coin stacks grow with
/// receivables, red letters pile up when overdue.
struct WorldMoneyState: Equatable {
    let outstandingCents: Int
    let outstandingCount: Int
    let overdueCents: Int
    let overdueCount: Int

    static let empty = WorldMoneyState(outstandingCents: 0, outstandingCount: 0,
                                       overdueCents: 0, overdueCount: 0)

    var hasOverdue: Bool { overdueCount > 0 }
}

/// One note stuck on the office whiteboard: an overdue or coming-due invoice.
struct WorldWhiteboardNote: Identifiable, Equatable {
    let id: String                 // invoice id
    let invoiceNumber: String
    let customerName: String
    let dueDate: Date
    let amountDueCents: Int
    let state: State
    /// The customer's job site, when they have one — money trouble shows up
    /// at the job that caused it, not just on the board.
    var siteID: String?

    enum State: Equatable {
        case overdue(days: Int)
        case comingDue(days: Int)
        case current
    }

    /// Sticky-note tint by state — the board reddens as money gets late.
    var isUrgent: Bool {
        if case .overdue = state { return true }
        return false
    }
}

// MARK: - The whole world

/// Everything the mapper produced for one moment in time.
struct WorldState: Equatable {
    var sites: [WorldSite]
    var crew: [WorldCrewMember]
    var mail: [WorldMailItem]
    var money: WorldMoneyState
    var whiteboard: [WorldWhiteboardNote]
    var playerName: String?

    var sitesNeedingGeocoding: [WorldSite] {
        sites.filter { $0.coordinate == nil && $0.pendingGeocodeAddress != nil }
    }

    /// Count of things in the world that need Mike, for a glanceable badge.
    var attentionCount: Int {
        mail.count + money.overdueCount
    }
}

// MARK: - Formatter helpers (shared by scenes)

extension Int {
    /// Cents -> "$1,234" (no cents shown — the world doesn't do decimals).
    var moneyString: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        let dollars = (self as NSNumber).intValue / 100
        return "$" + (f.string(from: NSNumber(value: dollars)) ?? "\(dollars)")
    }
}
