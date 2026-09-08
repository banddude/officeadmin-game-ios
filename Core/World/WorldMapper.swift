//  WorldMapper.swift
//  OfficeAdminGame
//
//  The pure API-records -> world-entities transform, per the table in
//  docs/ARCHITECTURE.md:
//    project with an address     -> site at its real coordinates + phase marker
//    crew schedule / clock state -> crew characters at job or office
//    approval request            -> mail on the desk (a quest)
//    invoice / receivable        -> money stacks + whiteboard notes
//  No networking, no geocoding, no rendering — those live beside it
//  (GameStore orchestrates fetches, AddressGeocoder fills missing coords,
//  the scenes draw). Deterministic given inputs, so fixtures test it fully.

import CoreLocation
import Foundation

struct WorldInputs {
    var projectDetails: [OAProjectDetail] = []
    var shifts: [OAScheduledShift] = []          // today's window
    var clock: OAClockSnapshot?
    var approvals: [OAApprovalRequest] = []      // pending only
    var invoices: [OAInvoice] = []
    var invoiceSummary: OAInvoiceSummary?
    var playerProfileName: String?
    /// Host of the connected server (e.g. "officeadmin.io") — lets the crew
    /// map recognize the server's own automation accounts.
    var serverHost: String? = nil
    var now: Date = Date()
}

enum WorldMapper {

    static func map(_ inputs: WorldInputs) -> WorldState {
        WorldState(
            sites: sites(inputs),
            crew: crew(inputs),
            mail: mail(inputs),
            money: money(inputs),
            whiteboard: whiteboard(inputs),
            playerName: playerName(inputs))
    }

    // MARK: Sites

    static func sites(_ inputs: WorldInputs) -> [WorldSite] {
        let scheduledBySite = Dictionary(grouping: todaysShifts(inputs), by: { $0.projectId ?? "" })

        // Approvals point at bills/expenses/...; when the entity is an invoice
        // we can link it to a customer, and through them to that customer's
        // site — so mail visibly waits at the job it belongs to, not just on
        // the desk.
        let invoiceContact = WorldMapper.invoiceContact(inputs)
        let approvalsByContact = Dictionary(grouping: inputs.approvals) { req -> String? in
            guard req.entityType == "invoice" else { return nil }
            return invoiceContact[req.entityId]
        }

        var result: [WorldSite] = inputs.projectDetails.compactMap { project in
            guard let phase = WorldSite.Phase(rawStatus: project.status) else { return nil }

            var coordinate: CLLocationCoordinate2D?
            if let lat = project.siteLat, let lng = project.siteLng {
                let c = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                if WorldRules.isPlausible(c) { coordinate = c }
            }

            let progress: Int? = {
                guard let percents = project.milestones?.compactMap({ $0.progressPercent }),
                      !percents.isEmpty else { return nil }
                return percents.reduce(0, +) / percents.count
            }()

            let siteScheduled = scheduledBySite[project.id]?
                .compactMap { $0.employeeName ?? $0.contactName } ?? []

            let waiting = project.contact.map { approvalsByContact[$0.id]?.count ?? 0 } ?? 0

            return WorldSite(
                id: project.id,
                name: project.name,
                scopeLabel: project.category?.trimmingCharacters(in: .whitespacesAndNewlines),
                customerName: project.contact?.name,
                phase: phase,
                coordinate: coordinate,
                pendingGeocodeAddress: coordinate == nil ? (project.siteAddress?.isEmpty == false ? project.siteAddress : nil) : nil,
                budgetCents: project.fixedPrice ?? project.budget,
                billedCents: project.totalBilled,
                progressPercent: progress,
                crewPresent: [],
                crewScheduled: Array(siteScheduled),
                waitingMailCount: waiting)
        }

        // Who is standing here RIGHT NOW (running clock entries).
        if let clock = inputs.clock {
            for employee in clock.employees {
                guard let running = employee.runningEntry,
                      let idx = result.firstIndex(where: { $0.id == running.projectId }) else { continue }
                result[idx].crewPresent.append(employee.name)
            }
        }

        return result.sorted {
            ($0.phase.sortOrder, $0.name) < ($1.phase.sortOrder, $1.name)
        }
    }

    // MARK: Crew

    static func crew(_ inputs: WorldInputs) -> [WorldCrewMember] {
        guard let clock = inputs.clock else { return [] }
        let runningByUser = Dictionary(uniqueKeysWithValues:
            clock.employees.compactMap { emp in
                emp.runningEntry.map { (emp.userId, $0) }
            })
        // Where each employee is HEADED today: the earliest not-yet-done shift
        // still ahead of us (only shifts later today count — tomorrow is not
        // "on the road").
        let calendar = Calendar(identifier: .gregorian)
        let upcomingByUser: [String: OAScheduledShift] = {
            var best: [String: OAScheduledShift] = [:]
            for shift in todaysShifts(inputs) {
                guard let user = shift.employeeUserId,
                      shift.status != "cancelled", shift.status != "no_show",
                      shift.scheduledEnd > inputs.now,
                      calendar.isDate(shift.scheduledStart, inSameDayAs: inputs.now) else { continue }
                if best[user] == nil || best[user]!.scheduledStart > shift.scheduledStart {
                    best[user] = shift
                }
            }
            return best
        }()
        // Where they already were today: a shift that has ended still says
        // which job had them, so tonight's board shows today's work standing
        // at the site it happened on.
        let earlierByUser: [String: OAScheduledShift] = {
            var best: [String: OAScheduledShift] = [:]
            for shift in todaysShifts(inputs) {
                guard let user = shift.employeeUserId,
                      shift.status != "cancelled", shift.status != "no_show",
                      shift.scheduledEnd <= inputs.now else { continue }
                if best[user] == nil || best[user]!.scheduledStart > shift.scheduledStart {
                    best[user] = shift
                }
            }
            return best
        }()

        let siteNames = Dictionary(uniqueKeysWithValues:
            inputs.projectDetails.map { ($0.id, $0.name) })

        return clock.employees.compactMap { employee in
            let isPlayer = employee.userId == clock.currentUserId
            let running = runningByUser[employee.userId]
            let isClockedIn = running != nil

            let assignment: WorldCrewMember.Assignment
            if let running {
                assignment = .atSite(siteID: running.projectId,
                                     siteName: running.projectName)
            } else if let upcoming = upcomingByUser[employee.userId],
                      let siteID = upcoming.projectId {
                assignment = .onRoad(toSiteID: siteID,
                                     siteName: upcoming.projectName ?? siteNames[siteID] ?? "a job")
            } else if let earlier = earlierByUser[employee.userId],
                      let siteID = earlier.projectId {
                assignment = .atSite(siteID: siteID,
                                     siteName: earlier.projectName ?? siteNames[siteID] ?? "a job")
            } else {
                assignment = .office
            }

            return WorldCrewMember(id: employee.userId,
                                   name: employee.name,
                                   role: employee.role,
                                   email: employee.email,
                                   assignment: assignment,
                                   isPlayer: isPlayer,
                                   isClockedIn: isClockedIn,
                                   isServiceAccount: WorldCrewMember.serviceAccount(
                                       email: employee.email,
                                       serverHost: inputs.serverHost))
        }
        .sorted { a, b in
            if a.isPlayer != b.isPlayer { return a.isPlayer }
            if a.isClockedIn != b.isClockedIn { return a.isClockedIn }
            return a.name < b.name
        }
    }

    // MARK: Mail

    static func mail(_ inputs: WorldInputs) -> [WorldMailItem] {
        let invoiceContact = WorldMapper.invoiceContact(inputs)
        let contactSite = WorldMapper.contactSite(inputs)
        return inputs.approvals
            .filter { $0.status == "pending" }
            .map { request in
                WorldMailItem(
                    id: request.id,
                    kind: WorldMailItem.Kind(rawEntityType: request.entityType) ?? .expense,
                    workflowName: request.workflow?.name ?? "",
                    fromName: request.requestedBy?.user?.name,
                    createdAt: request.createdAt,
                    stepOrder: request.currentStepOrder ?? 1,
                    siteID: request.entityType == "invoice"
                        ? invoiceContact[request.entityId].flatMap { contactSite[$0] }
                        : nil)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: Money

    static func money(_ inputs: WorldInputs) -> WorldMoneyState {
        if let s = inputs.invoiceSummary {
            return WorldMoneyState(
                outstandingCents: s.outstanding ?? 0,
                outstandingCount: s.outstandingCount ?? 0,
                overdueCents: s.overdue ?? 0,
                overdueCount: s.overdueCount ?? 0)
        }
        // Fallback: derive from the invoice list (statuses sent/partial/overdue).
        let open = inputs.invoices.filter { ["sent", "partial", "overdue"].contains($0.status) }
        let overdue = open.filter { $0.status == "overdue" }
        return WorldMoneyState(
            outstandingCents: open.reduce(0) { $0 + ($1.amountDue ?? $1.total ?? 0) },
            outstandingCount: open.count,
            overdueCents: overdue.reduce(0) { $0 + ($1.amountDue ?? $1.total ?? 0) },
            overdueCount: overdue.count)
    }

    // MARK: Whiteboard

    static func whiteboard(_ inputs: WorldInputs) -> [WorldWhiteboardNote] {
        let calendar = Calendar(identifier: .gregorian)
        let invoiceContact = WorldMapper.invoiceContact(inputs)
        let contactSite = WorldMapper.contactSite(inputs)
        return inputs.invoices
            .filter { ["sent", "partial", "overdue"].contains($0.status) && ($0.amountDue ?? 0) > 0 }
            .compactMap { invoice in
                guard let due = OAWire.parseBareDate(invoice.dueDate) else { return nil }
                let days = calendar.dateComponents([.day],
                                                   from: calendar.startOfDay(for: due),
                                                   to: calendar.startOfDay(for: inputs.now)).day ?? 0
                let state: WorldWhiteboardNote.State
                if days > 0 { state = .overdue(days: days) }
                else if days >= -WorldRules.whiteboardComingDueDays { state = .comingDue(days: -days) }
                else { state = .current }
                // Only pin the board with invoices that need eyes: overdue or
                // coming due. Current-term ones are just coins in the stack.
                guard case .current = state else {
                    return WorldWhiteboardNote(id: invoice.id,
                                               invoiceNumber: invoice.invoiceNumber,
                                               customerName: invoice.contact?.name ?? "Customer",
                                               dueDate: due,
                                               amountDueCents: invoice.amountDue ?? invoice.total ?? 0,
                                               state: state,
                                               siteID: invoiceContact[invoice.id].flatMap { contactSite[$0] })
                }
                return nil
            }
            .sorted { a, b in
                (a.isUrgent ? 0 : 1, a.dueDate.timeIntervalSince1970) <
                (b.isUrgent ? 0 : 1, b.dueDate.timeIntervalSince1970)
            }
    }

    // MARK: Helpers

    /// Customer contact id -> their project, so records that only know a
    /// contact (invoices, approvals) can find the job site they belong to.
    static func contactSite(_ inputs: WorldInputs) -> [String: String] {
        Dictionary(inputs.projectDetails.compactMap { project in
            project.contact.map { ($0.id, project.id) }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Invoice id -> the customer it bills.
    private static func invoiceContact(_ inputs: WorldInputs) -> [String: String] {
        Dictionary(uniqueKeysWithValues: inputs.invoices.map { ($0.id, $0.contactId) })
    }

    private static func todaysShifts(_ inputs: WorldInputs) -> [OAScheduledShift] {
        let calendar = Calendar(identifier: .gregorian)
        return inputs.shifts.filter {
            ($0.eventType == nil || $0.eventType == "shift")
                && calendar.isDate($0.scheduledStart, inSameDayAs: inputs.now)
        }
    }

    private static func playerName(_ inputs: WorldInputs) -> String? {
        if let name = inputs.playerProfileName, !name.isEmpty { return name }
        guard let clock = inputs.clock,
              let me = clock.employees.first(where: { $0.userId == clock.currentUserId }) else { return nil }
        return me.name
    }
}
