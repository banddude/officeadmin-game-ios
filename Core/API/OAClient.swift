//  OAClient.swift
//  OfficeAdminGame
//
//  Typed HTTP client for the OfficeAdmin /api/v1 surface this game needs.
//  Auth mirrors the existing OfficeAdmin iOS client's request shape, with the
//  one difference the game requires: it authenticates with a dk_ API key
//  (Authorization: Bearer dk_...) resolved by lib/api/auth-context.ts, instead
//  of sharing the webview's session cookie jar. Everything else is the same
//  contract: JSON bodies, {error:"..."} failures, x-organization-id on
//  requests, org scoping resolved server-side.

import Foundation

enum OAError: Error, LocalizedError {
    case notConfigured
    case unauthorized(String)
    case http(Int, String)
    case transport(Error)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "The world isn't connected yet. Enter your server address and API key."
        case .unauthorized(let msg):
            return msg.isEmpty ? "That API key wasn't accepted. Check it and try again." : msg
        case .http(let code, let body):
            if let msg = OAClient.serverErrorMessage(body) { return msg }
            return "Server error (\(code))."
        case .transport(let e):
            return e.localizedDescription
        case .decode(let ctx):
            return "The server's answer didn't make sense (\(ctx))."
        }
    }
}

final class OAClient {
    let credentials: GameCredentials
    private let session: URLSession

    /// organizationId resolved from /me (cached); sent as x-organization-id.
    private(set) var resolvedOrganizationId: String?

    init(credentials: GameCredentials, organizationId: String? = nil) {
        self.credentials = credentials
        self.resolvedOrganizationId = organizationId ?? credentials.organizationId
        let cfg = URLSessionConfiguration.default
        cfg.httpShouldSetCookies = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 90
        session = URLSession(configuration: cfg)
    }

    // MARK: - Endpoints

    /// Who am I + which org — used to validate first-launch credentials and
    /// pin x-organization-id. GET /api/v1/me (bare object).
    func me() async throws -> OAMe {
        let me: OAMe = try await get("/api/v1/me")
        resolvedOrganizationId = me.organizationId
        return me
    }

    /// Mike's own name, for the player character. GET /api/v1/user/profile.
    func userProfile() async throws -> OAUserProfile {
        let env: OAUserProfileEnvelope = try await get("/api/v1/user/profile")
        return env.user
    }

    /// Active-pipeline projects (no address on the list route — details carry it).
    /// GET /api/v1/projects?status=...&limit=... -> {data, pagination}.
    func projects(statuses: [String] = WorldRules.liveSiteStatuses, limit: Int = 200) async throws -> [OAProjectListItem] {
        var query = [URLQueryItem(name: "limit", value: String(min(limit, 2000)))]
        if !statuses.isEmpty {
            query.append(URLQueryItem(name: "status", value: statuses.joined(separator: ",")))
        }
        let page: OAPaginated<OAProjectListItem> = try await get("/api/v1/projects", query: query)
        return page.data
    }

    /// Full project row incl. siteAddress / siteLat / siteLng (strings on wire).
    /// GET /api/v1/projects/{id} -> {project}.
    func project(id: String) async throws -> OAProjectDetail {
        let env: OAProjectDetailEnvelope = try await get("/api/v1/projects/\(escapePath(id))")
        return env.project
    }

    /// Pending approvals = the mail pile. GET /api/v1/approval-requests?status=pending.
    func pendingApprovals(limit: Int = 200) async throws -> [OAApprovalRequest] {
        let page: OAPaginated<OAApprovalRequest> = try await get(
            "/api/v1/approval-requests",
            query: [URLQueryItem(name: "status", value: "pending"),
                    URLQueryItem(name: "limit", value: String(min(limit, 2000)))])
        return page.data
    }

    /// Approve / reject / comment on an approval request — the supported write.
    /// POST /api/v1/approval-requests/{id}/action {action, comment?} -> {request}.
    @discardableResult
    func act(onApprovalID id: String, action: String, comment: String? = nil) async throws -> OAApprovalRequest {
        var payload: [String: Any] = ["action": action]
        if let comment, !comment.isEmpty { payload["comment"] = comment }
        let env: OAApprovalActionEnvelope = try await send(
            path: "/api/v1/approval-requests/\(escapePath(id))/action",
            method: "POST", body: payload)
        return env.request
    }

    /// Customer invoices for money-as-world-state. GET /api/v1/invoices.
    func invoices(limit: Int = 200) async throws -> [OAInvoice] {
        let page: OAPaginated<OAInvoice> = try await get(
            "/api/v1/invoices",
            query: [URLQueryItem(name: "limit", value: String(min(limit, 2000)))])
        return page.data
    }

    /// Receivables totals for the office coin stacks. GET /api/v1/invoices/summary.
    func invoiceSummary() async throws -> OAInvoiceSummary {
        try await get("/api/v1/invoices/summary")
    }

    /// Address book (used for client names on site markers). GET /api/v1/contacts.
    func contacts(limit: Int = 200) async throws -> [OAContact] {
        let page: OAPaginated<OAContact> = try await get(
            "/api/v1/contacts",
            query: [URLQueryItem(name: "limit", value: String(min(limit, 2000)))])
        return page.data
    }

    /// Crew-wide snapshot: every member + who has a running entry where.
    /// GET /api/v1/time/clock (bare object).
    func clockSnapshot() async throws -> OAClockSnapshot {
        try await get("/api/v1/time/clock")
    }

    /// Shifts in a window (today's crew placement). GET /api/v1/scheduled-shifts
    /// ?from=&to= -> {shifts}. Project name/address resolved server-side.
    func scheduledShifts(from: Date, to: Date) async throws -> [OAScheduledShift] {
        let f = ISO8601DateFormatter().string(from: from)
        let t = ISO8601DateFormatter().string(from: to)
        let env: OAScheduledShiftsEnvelope = try await get(
            "/api/v1/scheduled-shifts",
            query: [URLQueryItem(name: "from", value: f),
                    URLQueryItem(name: "to", value: t),
                    URLQueryItem(name: "limit", value: "1000")])
        return env.shifts
    }

    // MARK: - Core request plumbing

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send(path: path, method: "GET", query: query, body: nil)
    }

    private func send<T: Decodable>(path: String,
                                    method: String,
                                    query: [URLQueryItem] = [],
                                    body: [String: Any]? = nil) async throws -> T {
        let data = try await raw(path: path, method: method, query: query, body: body)
        do {
            return try OAWire.decoder.decode(T.self, from: data)
        } catch {
            throw OAError.decode("\(T.self): \(error.localizedDescription)")
        }
    }

    /// Raw request; throws OAError with the server's {"error":...} surfaced.
    private func raw(path: String,
                     method: String,
                     query: [URLQueryItem] = [],
                     body: [String: Any]? = nil) async throws -> Data {
        guard var components = URLComponents(url: credentials.normalizedBase, resolvingAgainstBaseURL: false) else {
            throw OAError.notConfigured
        }
        components.path = (components.path as NSString).appendingPathComponent(path)
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw OAError.notConfigured }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("OfficeAdmin-Game-iOS", forHTTPHeaderField: "X-OA-Client")
        req.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        // Org scoping, same as the existing client's x-organization-id on writes.
        // (auth-context.ts also accepts it on reads; harmless when it matches.)
        if let org = resolvedOrganizationId ?? credentials.organizationId {
            req.setValue(org, forHTTPHeaderField: "x-organization-id")
        }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw OAError.decode("no HTTPURLResponse") }
            switch http.statusCode {
            case 200...299:
                return data
            case 401, 403:
                throw OAError.unauthorized(OAClient.serverErrorMessage(String(data: data, encoding: .utf8) ?? "") ?? "")
            default:
                throw OAError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
        } catch let e as OAError {
            throw e
        } catch {
            throw OAError.transport(error)
        }
    }

    private func escapePath(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    /// Pull a server {"error":"..."} message out of a response body, if present.
    static func serverErrorMessage(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = obj["error"] as? String, !msg.isEmpty else { return nil }
        return msg
    }
}
