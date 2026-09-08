//  geocode_addresses.swift
//  OfficeAdminGame (build tool, macOS only)
//
//  Generates the bundled geocode seed (Core/World/GeocodeSeed.json) from the
//  real project addresses, so the world board places every job deterministically
//  and offline. Cache keys are the RAW siteAddress strings exactly as the API
//  returns them (that is what the app looks up); when a raw string is too
//  incomplete for CLGeocoder, input entries may list enriched variants to try
//  in order — the first hit is stored under the raw key.
//
//  Input  (argv[1]): [{"key": "346 21st Place", "try": ["346 21st Place, Los Angeles, CA"]}, ...]
//  Output (argv[2]): {"346 21st Place": {"lat": 33.86, "lng": -118.28}, ...}
//
//  Run on the Mac build box:
//    swiftc -o /tmp/geocode_addresses tools/geocode_addresses.swift
//    /tmp/geocode_addresses /tmp/geocode_input.json /tmp/GeocodeSeed.json

import CoreLocation
import Foundation

struct Input: Decodable {
    let key: String
    let variants: [String]?

    enum CodingKeys: String, CodingKey {
        case key
        case variants = "try"
    }
}

struct Output: Codable {
    let lat: Double
    let lng: Double
}

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: geocode_addresses <input.json> <output.json>\n".data(using: .utf8)!)
    exit(64)
}
let input = try JSONDecoder().decode([Input].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let geocoder = CLGeocoder()
var results: [String: Output] = [:]
var misses: [String] = []

for entry in input {
    let variants = entry.variants ?? [entry.key]
    var placed: Output?
    for variant in variants {
        let placemarks = try? await geocoder.geocodeAddressString(variant)
        if let location = placemarks?.first?.location,
           abs(location.coordinate.latitude) > 0.1 || abs(location.coordinate.longitude) > 0.1 {
            placed = Output(lat: location.coordinate.latitude, lng: location.coordinate.longitude)
            print("placed  \(entry.key)  ->  \(variant)  @  \(placed!)")
            break
        }
    }
    if let placed {
        results[entry.key] = placed
    } else {
        misses.append(entry.key)
        print("MISS    \(entry.key)")
    }
    // Apple's geocoder rate-limits bursts; stay polite.
    try? await Task.sleep(nanoseconds: 300_000_000)
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(results).write(to: URL(fileURLWithPath: args[2]))
print("\n\(results.count) placed, \(misses.count) missed")
if !misses.isEmpty { print("misses: \(misses.joined(separator: " | "))") }
