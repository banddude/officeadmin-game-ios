//  AddressGeocoder.swift
//  OfficeAdminGame
//
//  Turns a project's free-text siteAddress into a real coordinate via
//  CLGeocoder, for sites whose project record has no siteLat/siteLng. This is
//  the ONLY impure step between API records and world placement, so it lives
//  beside the pure WorldMapper, not inside it. Results are cached by address
//  string so a site isn't re-geocoded on every refetch.

import CoreLocation
import Foundation

actor AddressGeocoder {
    private var cache: [String: CLLocationCoordinate2D?] = [:]
    private let geocoder = CLGeocoder()

    /// Geocode one address; nil when Apple can't place it. Failures are
    /// cached too (as nil) so bad addresses don't retry forever.
    func coordinate(for address: String) async -> CLLocationCoordinate2D? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let cached = cache[trimmed] { return cached }

        let result: CLLocationCoordinate2D?
        do {
            let placemarks = try await geocoder.geocodeAddressString(trimmed)
            if let location = placemarks.first?.location,
               WorldRules.isPlausible(location.coordinate) {
                result = location.coordinate
            } else {
                result = nil
            }
        } catch {
            result = nil
        }
        cache[trimmed] = result
        return result
    }
}
