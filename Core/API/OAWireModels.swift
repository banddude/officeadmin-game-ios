//  OAWireModels.swift
//  OfficeAdminGame
//
//  Codable structs matching the OfficeAdmin /api/v1 wire format EXACTLY as
//  the server serializes it (drizzle rows + ok()/paginatedResponse() helpers).
//  Field-for-field notes:
//    - money is integer CENTS everywhere; durations integer MINUTES.
//    - timestamps are ISO-8601 with milliseconds ("2026-09-06T18:22:31.120Z").
//    - bare dates are "YYYY-MM-DD" strings — kept as String, not Date.
//    - numeric Postgres columns (siteLat/siteLng) arrive as STRINGS on the
//      project detail route but as NUMBERS on /time/clock projects.
//    - envelopes vary: {data, pagination} for list routes, the object itself
//      for /me, {shifts}, {project}, {request}, and the clock snapshot.
//  Unknown keys are ignored, so server additions don't break decoding.

import Foundation

// MARK: - Shared decoding

enum OAWire {
    /// JSONDecoder that reads OfficeAdmin timestamps (ISO-8601, optional
    /// fractional seconds) into Date, and tolerates both string and number
    /// encodings where the server is inconsistent.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let s = try container.decode(String.self)
            if let date = OAWire.parseISO(s) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unparseable timestamp: \(s)")
        }
        return d
    }()

    static func parseISO(_ s: String) -> Date? {
        if s.count == 10 { return nil } // bare YYYY-MM-DD is not a timestamp
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }

    /// "YYYY-MM-DD" -> Date at noon UTC (stable for due-date math).
    static func parseBareDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]; c.hour = 12
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)
    }
}

/// Flexible Double that decodes from JSON number OR numeric string.
@propertyWrapper
struct OAWireDouble: Decodable {
    let wrappedValue: Double?
    init(wrappedValue: Double?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
        } else if let d = try? container.decode(Double.self) {
            wrappedValue = d
        } else if let s = try? container.decode(String.self) {
            wrappedValue = Double(s)
        } else {
            wrappedValue = nil
        }
    }
}

// MARK: - Pagination envelope

struct OAPaginated<T: Decodable>: Decodable {
    let data: [T]
    let pagination: Pagination?

    struct Pagination: Decodable {
        let page: Int
        let limit: Int
        let total: Int
        let totalPages: Int
    }
}

// MARK: - /api/v1/me  (bare object)

struct OAMe: Decodable {
    let userId: String
    let organizationId: String
    let role: String
    let isSiteAdmin: Bool?
    let permissions: [String]?
}

// MARK: - /api/v1/user/profile

struct OAUserProfileEnvelope: Decodable {
    let user: OAUserProfile
}

struct OAUserProfile: Decodable {
    let id: String
    let name: String?
    let email: String
    let image: String?
}

// MARK: - Projects

struct OAProjectListItem: Decodable, Identifiable {
    let id: String
    let name: String
    let status: String
    let priority: String?
    let billingType: String?
    let color: String?
    let budget: Int?
    let totalBilled: Int?
    let startDate: String?
    let endDate: String?
    let category: String?
    let tags: [String]?
    let updatedAt: String?
    let contact: ContactRef?

    struct ContactRef: Decodable {
        let id: String
        let name: String
    }
}

struct OAProjectDetailEnvelope: Decodable {
    let project: OAProjectDetail
}

struct OAProjectDetail: Decodable, Identifiable {
    let id: String
    let name: String
    let status: String
    let priority: String?
    let billingType: String?
    let color: String?
    let budget: Int?
    let fixedPrice: Int?
    let totalBilled: Int?
    let startDate: String?
    let endDate: String?
    let category: String?
    let siteAddress: String?
    @OAWireDouble var siteLat: Double?
    @OAWireDouble var siteLng: Double?
    let contact: ContactRef?
    let milestones: [Milestone]?

    struct ContactRef: Decodable {
        let id: String
        let name: String
    }

    struct Milestone: Decodable {
        let id: String
        let title: String?
        let progressPercent: Int?
    }
}

// MARK: - Approval requests

struct OAApprovalRequest: Decodable, Identifiable {
    let id: String
    let entityType: String        // bill | expense | invoice | journal_entry | purchase_order
    let entityId: String
    let status: String            // pending | approved | rejected | cancelled
    let currentStepOrder: Int?
    let createdAt: Date
    let updatedAt: Date?
    let workflow: Workflow?
    let requestedBy: MemberRef?

    struct Workflow: Decodable {
        let name: String?
        let steps: [Step]?

        struct Step: Decodable {
            let stepOrder: Int?
            let approver: MemberRef?
        }
    }

    struct MemberRef: Decodable {
        let id: String
        let userId: String?
        let role: String?
        let user: UserRef?

        struct UserRef: Decodable {
            let id: String
            let name: String?
            let email: String?
        }
    }
}

struct OAApprovalActionEnvelope: Decodable {
    let request: OAApprovalRequest
}

// MARK: - Invoices

struct OAInvoice: Decodable, Identifiable {
    let id: String
    let invoiceNumber: String
    let contactId: String
    let issueDate: String          // YYYY-MM-DD
    let dueDate: String            // YYYY-MM-DD
    let status: String             // draft | sent | partial | paid | overdue | void (+legacy)
    let subtotal: Int?
    let taxTotal: Int?
    let total: Int?
    let amountPaid: Int?
    let amountDue: Int?
    let currencyCode: String?
    let sentAt: Date?
    let paidAt: Date?
    let contact: ContactRef?

    struct ContactRef: Decodable {
        let id: String
        let name: String
        let email: String?
    }
}

struct OAInvoiceSummary: Decodable {
    let totalCount: Int?
    let outstanding: Int?
    let outstandingCount: Int?
    let overdue: Int?
    let overdueCount: Int?
    let aging: [String: Int]?
}

// MARK: - Contacts

struct OAContact: Decodable, Identifiable {
    let id: String
    let name: String
    let email: String?
    let phone: String?
    let mobile: String?
    let type: String?            // customer | supplier | both
    let isSubcontractor: Bool?
    let roles: [String]?
}

// MARK: - Time clock (crew-wide snapshot)

struct OAClockSnapshot: Decodable {
    let organizationId: String
    let currentUserId: String
    let employees: [Employee]
    let projects: [Project]

    struct Employee: Decodable, Identifiable {
        let memberId: String
        let userId: String
        let name: String
        let email: String
        let image: String?
        let role: String?
        let runningEntry: RunningEntry?

        var id: String { userId }
    }

    struct RunningEntry: Decodable {
        let id: String
        let employeeUserId: String
        let projectId: String
        let projectName: String
        let startAt: Date
        let minutes: Int?
        let breakMinutes: Int?
        let status: String?
        let notes: String?
    }

    struct Project: Decodable, Identifiable {
        let id: String
        let name: String
        let color: String?
        let billingType: String?
        let contactId: String?
        let category: String?
        @OAWireDouble var siteLat: Double?
        @OAWireDouble var siteLng: Double?
    }
}

// MARK: - Scheduled shifts

struct OAScheduledShiftsEnvelope: Decodable {
    let shifts: [OAScheduledShift]
}

struct OAScheduledShift: Decodable, Identifiable {
    let id: String
    let employeeUserId: String?
    let employeeName: String?
    let contactId: String?
    let contactName: String?
    let eventType: String?        // shift | subcontractor | delivery
    let projectId: String?
    let projectName: String?
    let projectContactName: String?
    let projectSiteAddress: String?
    let scheduledStart: Date
    let scheduledEnd: Date
    let notes: String?
    let status: String?           // planned | in_progress | completed | no_show | cancelled
}
