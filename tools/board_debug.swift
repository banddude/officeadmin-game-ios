//  board_debug.swift — standalone harness that compiles the REAL WorldBoard
//  and prints the layout + bearing deltas for the test's real-CA coordinate
//  set, so the spread can be inspected without the simulator. Run on the Mac:
//    cp tools/board_debug.swift /tmp/main.swift
//    swiftc Core/World/WorldModels.swift Core/World/WorldBoard.swift \
//          /tmp/main.swift -o /tmp/boarddebug && /tmp/boarddebug
import CoreLocation
import Foundation
import simd

let set: [(String, Double, Double)] = [
    ("novato", 38.1099, -122.5665), ("sanjose", 37.2345, -121.7874),
    ("coalinga", 36.1353, -120.3278), ("fowler", 36.6349, -119.6737),
    ("sandiego", 32.7018, -117.0663),
    ("palisades", 34.0483, -118.5252), ("calabasas", 34.1454, -118.6158),
    ("encino", 34.1574, -118.5040), ("pasadena", 34.1616, -118.3036),
    ("downtown", 34.0935, -118.3241), ("santamonica", 34.0469, -118.4451),
    ("downey", 33.9255, -118.1298), ("lynwood", 33.9212, -118.1798),
    ("orange", 33.8134, -117.8664), ("huntington", 33.6861, -117.9882),
]
let sites = set.map { id, lat, lng in
    WorldSite(id: id, name: id, scopeLabel: nil, customerName: nil,
              phase: .active, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
              pendingGeocodeAddress: nil, budgetCents: nil, billedCents: nil, progressPercent: nil,
              crewPresent: [], crewScheduled: [], waitingMailCount: 0)
}
let board = WorldBoard(sites: sites)
let regionMin = SIMD2(-WorldBoard.size.x / 2 + WorldBoard.sceneryWidth,
                      -WorldBoard.size.y / 2 + WorldBoard.padding)
let regionMax = SIMD2(WorldBoard.size.x / 2 - WorldBoard.padding,
                      WorldBoard.size.y / 2 - WorldBoard.padding)
let regionCenter = (regionMin + regionMax) / 2

// Mirror the fit: offsets from the coord centroid, box centered at regionCenter.
let coords = set.map { CLLocationCoordinate2D(latitude: $0.1, longitude: $0.2) }
let lat = coords.map(\.latitude).reduce(0, +) / Double(coords.count)
let lng = coords.map(\.longitude).reduce(0, +) / Double(coords.count)
let centroid = WorldBoard.mercatorMeters(CLLocationCoordinate2D(latitude: lat, longitude: lng))
let meters = coords.map { WorldBoard.mercatorMeters($0) - centroid }
var lo = SIMD2<Double>.zero, hi = SIMD2<Double>.zero
for m in meters {
    lo = simd_min(lo, SIMD2<Double>(m)); hi = simd_max(hi, SIMD2<Double>(m))
}
let cloudCenter = (lo + hi) / 2

// The layout's angular origin is the MEDIAN anchor (see WorldBoard) — grade
// bearings from there, as the lane logic preserves them.
func median(_ pts: [SIMD2<Float>]) -> SIMD2<Float> {
    let xs = pts.map(\.x).sorted(), ys = pts.map(\.y).sorted()
    let mid = xs.count / 2
    return SIMD2(xs.count % 2 == 1 ? xs[mid] : (xs[mid-1] + xs[mid]) / 2,
                 ys.count % 2 == 1 ? ys[mid] : (ys[mid-1] + ys[mid]) / 2)
}
var anchorList: [SIMD2<Float>] = []
var anchorById: [String: SIMD2<Float>] = [:]
do {
    let usable = regionMax - regionMin - SIMD2(WorldBoard.fitMargin * 2, WorldBoard.fitMargin * 2)
    let span = hi - lo
    let scale = min(usable.x / Float(max(span.x, 0.001)), usable.y / Float(max(span.y, 0.001)), 12)
    for (i, (id, _, _)) in set.enumerated() {
        let a = regionCenter + SIMD2<Float>(meters[i] - cloudCenter) * scale * SIMD2<Float>(1, -1)
        anchorList.append(a)
        anchorById[id] = a
    }
}
let medianAnchor = median(anchorList)

print("site           final                   true-anchor              bDelta°    moved")
for (i, (id, _, _)) in set.enumerated() {
    guard let p = board.sitePositions[id] else { print("\(id) NOT PLACED"); continue }
    let anchor = anchorById[id]!
    let trueBearing = atan2(anchor.y - medianAnchor.y, anchor.x - medianAnchor.x)
    let boardBearing = atan2(p.y - medianAnchor.y, p.x - medianAnchor.x)
    var delta = abs(boardBearing - trueBearing)
    if delta > .pi { delta = 2 * .pi - delta }
    let row = id.padding(toLength: 14, withPad: " ", startingAt: 0)
    print(String(format: "%@ (%6.2f,%6.2f)      (%6.2f,%6.2f)      %8.1f %8.2f",
                 row, p.x, p.y, anchor.x, anchor.y,
                 delta * 180 / .pi, simd_distance(p, anchor)))
}
var rects = Array(board.buildingFootprints.values)
var overlaps = 0
for i in rects.indices {
    for j in i + 1..<rects.count where rects[i].overlaps(rects[j]) { overlaps += 1 }
}
print("overlaps: \(overlaps) | placed: \(board.buildingFootprints.count)/\(set.count)")
