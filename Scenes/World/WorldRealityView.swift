//  WorldRealityView.swift
//  OfficeAdminGame
//
//  The world as a game, not a map: a RealityKit diorama board built from the
//  pure WorldBoard layout (real coordinates projected to the ground), with
//  the player character walked by thumbstick or tap, a board-framing camera,
//  crew wandering between sites, and attention items waiting to be picked up
//  by walking into them. Apple Maps is never the visual — only the geocoder
//  behind the scenes.
//
//  Picking follows the office scene's pattern: we own the camera, so a tap
//  is unprojected into a ray and cast against collision shapes.

import QuartzCore
import RealityKit
import SwiftUI
import UIKit

// MARK: - What the world tells SwiftUI

/// Something the player walked into and should see a card for.
enum WorldPickup: Equatable {
    case mail(String)        // approval request id
    case invoice(String)     // invoice id (whiteboard note)

    var id: String {
        switch self {
        case .mail(let id): return "mail:\(id)"
        case .invoice(let id): return "invoice:\(id)"
        }
    }
}

// MARK: - Controller (owns the scene)

final class WorldGameController: NSObject {
    let arView: ARView
    private let artProvider: any WorldArtProviding
    private let anchor = AnchorEntity(world: .zero)
    private var tapGesture: UITapGestureRecognizer!

    /// Unprojection assumes the default PerspectiveCameraComponent fov (60°).
    private let fovDegrees: Float = 60

    // World data (rebuilt on refetch)
    private var board = WorldBoard()
    private var sites: [String: WorldSite] = [:]
    private var worldRoot = Entity()          // ground + office + buildings
    private var pickupRoot = Entity()
    private var layoutSignature = ""
    private var pickupSignature = ""
    private var pickups: [(pickup: WorldPickup, entity: Entity, at: SIMD2<Float>)] = []
    private var collected = Set<String>()
    private var wanderers: [Wanderer] = []
    /// Site label cards with the geometry the stagger pass needs: where the
    /// card floats, how wide its plate is, and where its pin stands.
    private struct SiteLabel {
        let entity: Entity
        let halfSize: SIMD2<Float>   // plate half extents, local units
        let anchor: SIMD3<Float>     // home position above the roof
        let pinHead: SIMD3<Float>    // the pin's floating head, for leaders
        let leader: Entity           // thin line shown when staggered away
    }
    private var siteLabels: [SiteLabel] = []

    // The player
    private var player = Entity()
    private var playerParts: (legL: Entity, legR: Entity, body: Entity)?
    private var playerBoardPosition = SIMD2<Float>.zero
    private var playerYaw: Float = .pi       // facing north to start
    private var walkTargetPoint: SIMD2<Float>?
    private var walkTargetSiteID: String?
    private var walkPhase: Float = 0
    private var hasPlacedPlayer = false

    // Camera
    private var cameraEntity = Entity()
    /// The mockup diorama angle: low enough that the near edge looms large
    /// and the far edge compresses under the HUD — not a tabletop view.
    private let cameraElevation: Float = 40 * .pi / 180
    private let cameraBoardMargin: Float = 1.10
    /// The board row whose width the camera actually fits: the southern
    /// sites/office strip. South of it runs only sea, which may bleed off
    /// the bottom corners of the frame the way a coast does.
    private var cameraFitRowZ: Float { WorldBoard.size.y / 2 - 6 }
    /// The board is narrower than the camera axis of symmetry (the west
    /// band is ocean): aim at the middle of the strip sites are laid out in.
    private var cameraLookX: Float {
        (-WorldBoard.size.x / 2 + WorldBoard.sceneryWidth + WorldBoard.size.x / 2 - WorldBoard.padding) / 2
    }

    // Signals to SwiftUI
    var moveInput = SIMD2<Float>.zero         // x east, y forward (north)
    var onNearSite: ((String?) -> Void)?
    var onPickup: ((WorldPickup) -> Void)?
    var onEnterOffice: (() -> Void)?
    private var nearSiteID: String?
    private var officeDoorArmed = true

    // Tuning
    private let walkSpeed: Float = 3.4
    private let siteCardRadius: Float = 6.5

    init(frame: CGRect, artProvider: any WorldArtProviding = WorldArt.provider) {
        self.artProvider = artProvider
        arView = ARView(frame: frame)
        super.init()

        arView.cameraMode = .nonAR
        arView.environment.background = .color(WorldPalette.sky)
        arView.scene.addAnchor(anchor)

        anchor.addChild(worldRoot)
        anchor.addChild(pickupRoot)

        buildLights()

        cameraEntity.components.set(PerspectiveCameraComponent())
        anchor.addChild(cameraEntity)

        player = WorldPropFactory.character(shirt: WorldPalette.vest)
        // Hero scale: the hard hat and vest read clearly at the resting
        // diorama camera, not a dot on the board.
        player.scale = SIMD3(repeating: 2.2)
        if let legL = player.findEntity(named: "legL"),
           let legR = player.findEntity(named: "legR"),
           let body = player.findEntity(named: "body") {
            playerParts = (legL, legR, body)
        }
        anchor.addChild(player)

        // Subscription lives for the scene's lifetime (the token is discarded).
        _ = arView.scene.subscribe(to: SceneEvents.Update.self, { [weak self] event in
            self?.tick(deltaTime: Float(event.deltaTime))
        })

        tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        arView.addGestureRecognizer(tapGesture)
    }

    // MARK: Lights

    private func buildLights() {
        let sun = Entity()
        sun.components.set(DirectionalLightComponent(
            color: UIColor(red: 1.0, green: 0.96, blue: 0.88, alpha: 1),
            intensity: 950, isRealWorldProxy: false))
        sun.orientation = simd_quatf(angle: Float.pi * 0.24, axis: [1, 0, 0])
        sun.position = SIMD3(0, 8, 3)
        anchor.addChild(sun)

        let fill = Entity()
        fill.components.set(DirectionalLightComponent(
            color: UIColor(red: 0.88, green: 0.92, blue: 0.98, alpha: 1),
            intensity: 380, isRealWorldProxy: false))
        fill.orientation = simd_quatf(angle: -Float.pi * 0.25, axis: [1, 0, 0])
        anchor.addChild(fill)
    }

    // MARK: Building the world from data

    /// Rebuild what changed; keep the player where they stand. Signatures
    /// make the common no-op refetch cheap.
    func applyWorld(_ world: WorldState) {
        sites = Dictionary(uniqueKeysWithValues: world.sites.map { ($0.id, $0) })
        board = WorldBoard(sites: world.sites)

        let layout = world.sites
            .filter { $0.coordinate != nil }
            .sorted { $0.id < $1.id }
            .map { "\($0.id)@\(Int($0.coordinate!.latitude * 10000)),\(Int($0.coordinate!.longitude * 10000))" }
            .joined(separator: "|")
        if layout != layoutSignature {
            layoutSignature = layout
            rebuildBoard()
        }

        rebuildPickupsIfNeeded(world)
        rebuildCrewIfNeeded(world)

        if !hasPlacedPlayer {
            // First layout: the player starts beside the office path, facing
            // the world (north), clear of the door's trigger zone.
            hasPlacedPlayer = true
            playerBoardPosition = SIMD2(board.officeDoorPoint.x - 6.5,
                                        board.walkableRect.maxY - 0.2)
            player.position = boardPoint(playerBoardPosition)
            player.orientation = simd_quatf(angle: playerYaw, axis: [0, 1, 0])
            placeCamera()
        }
    }

    private func rebuildBoard() {
        worldRoot.children.forEach { $0.removeFromParent() }
        siteLabels.removeAll()

        var rng = SeededGenerator(SeededGenerator.seed(from: Array(sites.keys)))
        worldRoot.addChild(WorldPropFactory.groundBoard(board: board, rng: &rng))
        worldRoot.addChild(WorldPropFactory.office(board: board))

        for site in sites.values.sorted { $0.id < $1.id } {
            guard let footprint = board.buildingFootprints[site.id] else { continue }
            let building = WorldPropFactory.building(for: site, footprint: footprint)
            worldRoot.addChild(building)

            let roofline = building.position.y + WorldPropFactory.rooflineHeight(for: site)
            let pin = WorldPropFactory.sitePin(aboveRoofAt: roofline)
            pin.position += SIMD3(footprint.halfExtents.x - 0.4, 0, -footprint.halfExtents.y + 0.4)
            worldRoot.addChild(pin)

            let label = WorldPropFactory.siteLabel(for: site)
            let anchor = SIMD3(footprint.center.x, roofline + 1.5, footprint.center.y)
            label.position = anchor
            worldRoot.addChild(label)

            let leader = WorldPropFactory.leaderLine()
            leader.isEnabled = false
            worldRoot.addChild(leader)

            siteLabels.append(SiteLabel(
                entity: label,
                halfSize: plateHalfSize(of: label),
                anchor: anchor,
                pinHead: SIMD3(pin.position.x, roofline + 1.3, pin.position.z),
                leader: leader))
        }
    }

    /// A label group's first child is its plate box (the factories build the
    /// plate before the text); measuring it tells the stagger pass how wide
    /// and tall each card really is.
    private func plateHalfSize(of label: Entity) -> SIMD2<Float> {
        guard let mesh = label.children.first?.components[ModelComponent.self]?.mesh else {
            return SIMD2(1.2, 0.4)
        }
        let extents = mesh.bounds.max - mesh.bounds.min
        return SIMD2(extents.x / 2, extents.y / 2)
    }

    private func rebuildPickupsIfNeeded(_ world: WorldState) {
        // Mail first (approvals), then urgent invoice notes — capped so the
        // board stays readable; the HUD cards still count everything.
        let entries: [(WorldPickup, WorldArt.AttentionKind, String?)] =
            world.mail.prefix(4).map { (.mail($0.id), .approval, $0.siteID) } +
            world.whiteboard.prefix(3).map { (.invoice($0.id), .invoicePayment, $0.siteID) }

        let signature = entries.map { "\($0.0.id)@\($0.2 ?? "office")" }.joined(separator: "|")
        guard signature != pickupSignature else { return }
        pickupSignature = signature

        pickupRoot.children.forEach { $0.removeFromParent() }
        pickups.removeAll()
        // Keep only the still-existing ids the player already grabbed, so a
        // rebuild right after a pickup doesn't re-trigger its card.
        collected.formIntersection(Set(entries.map { $0.0.id }))

        for (index, entry) in entries.enumerated() {
            let (pickup, kind, siteID) = entry
            guard !collected.contains(pickup.id) else { continue }
            let at = pickupPosition(siteID: siteID, index: index)
            let entity = WorldPropFactory.attentionPickup(kind: kind, artProvider: artProvider)
            entity.position = boardPoint(at)
            pickupRoot.addChild(entity)
            pickups.append((pickup, entity, at))
        }
    }

    /// Pickups stand by the south-west corner of their site's building (or
    /// by the office door when they have no site).
    private func pickupPosition(siteID: String?, index: Int) -> SIMD2<Float> {
        if let siteID, let rect = board.buildingFootprints[siteID] {
            return WorldWalk.clamp(
                SIMD2(rect.minX - 1.5 - Float(index % 2) * 1.3,
                      rect.minY - 0.4 + Float(index / 2) * 1.3),
                to: board.walkableRect)
        }
        let side = Float(index % 3) - 1
        return WorldWalk.clamp(
            SIMD2(board.officeDoorPoint.x + side * 1.8,
                  board.officeDoorPoint.y + 1.4 + Float(index / 3) * 1.4),
            to: board.walkableRect)
    }

    // MARK: Crew wanderers

    private struct Wanderer {
        let entity: Entity
        let label: Entity
        let labelHalf: SIMD2<Float>
        var labelAnchor: SIMD3<Float>
        let legs: (Entity, Entity)
        var position: SIMD2<Float>
        var target: SIMD2<Float>
        var pauseRemaining: Float
        var heading: Float
        var phase: Float
        /// Where this person belongs: their site's yard, or the office front.
        let anchor: SIMD2<Float>
        var rng: SeededGenerator
    }

    private var crewSignature = ""

    private func rebuildCrewIfNeeded(_ world: WorldState) {
        // Real people only — the server's automation accounts never stand
        // anywhere, and the board shows a crew, not a member list.
        let crew = world.crew
            .filter { !$0.isPlayer && !$0.isServiceAccount }
            .prefix(6)
        let signature = crew.map { "\($0.id)@\($0.assignmentSiteID ?? "office")" }.joined(separator: "|")
        guard signature != crewSignature else { return }
        crewSignature = signature

        wanderers.forEach {
            $0.entity.removeFromParent()
            $0.label.removeFromParent()
        }
        wanderers = []

        let shirts: [UIColor] = [WorldPalette.canopy, WorldPalette.sky, UIColor(Theme.clay),
                                 WorldPalette.blend(WorldPalette.canopy, toward: .white, fraction: 0.2)]
        for (index, member) in crew.enumerated() {
            var rng = SeededGenerator(SeededGenerator.seed(from: ["crew", member.id]))
            let start = crewAnchor(for: member, index: index)
            let entity = WorldPropFactory.character(shirt: shirts[index % shirts.count])
            entity.scale = SIMD3(repeating: 1.5)
            entity.position = boardPoint(start)
            anchor.addChild(entity)

            let nameplate = WorldPropFactory.crewNameLabel(member.name)
            let labelAnchor = boardPoint(start) + SIMD3(0, 2.55, 0)
            nameplate.position = labelAnchor
            anchor.addChild(nameplate)

            guard let legL = entity.findEntity(named: "legL"),
                  let legR = entity.findEntity(named: "legR") else { continue }
            wanderers.append(Wanderer(
                entity: entity,
                label: nameplate,
                labelHalf: plateHalfSize(of: nameplate),
                labelAnchor: labelAnchor,
                legs: (legL, legR),
                position: start,
                target: start,
                pauseRemaining: rng.float(in: 0.5...2.5),
                heading: rng.float(in: 0...(2 * .pi)),
                phase: rng.float(in: 0...(2 * .pi)),
                anchor: start,
                rng: rng))
        }
    }

    /// Where a crew member belongs: at their site's front step when today's
    /// schedule or timesheet names one, else on the office front steps.
    private func crewAnchor(for member: WorldCrewMember, index: Int) -> SIMD2<Float> {
        if let siteID = member.assignmentSiteID,
           let rect = board.buildingFootprints[siteID] {
            // Approach from the street (south of the building), staggered a
            // little so two crew at one site don't share a pixel.
            return WorldWalk.clamp(
                WorldWalk.approachPoint(
                    for: rect, from: SIMD2(rect.center.x + Float(index % 3 - 1) * 1.4, rect.maxY + 6),
                    standoff: 2.0 + Float(index % 2)),
                to: board.walkableRect)
        }
        // Office: two staggered rows along the office's south face.
        let base = SIMD2(board.officeFootprint.minX + 1.6, board.walkableRect.maxY)
        return WorldWalk.clamp(
            SIMD2(base.x + Float(index) * 1.7,
                  base.y - 0.25 - Float(index % 2) * 0.4),
            to: board.walkableRect)
    }

    /// Crew potter around where they belong (a site's yard, the office
    /// front) — the board keeps reading "who is where", not a parade.
    private func localWanderTarget(anchor: SIMD2<Float>, rng: inout SeededGenerator) -> SIMD2<Float> {
        let angle = rng.float(in: 0...(2 * .pi))
        let radius = rng.float(in: 0.6...2.2)
        return WorldWalk.clamp(
            anchor + SIMD2(cos(angle) * radius, sin(angle) * radius),
            to: board.walkableRect)
    }

    // MARK: Per-frame update

    private func tick(deltaTime dt: Float) {
        tickPlayer(deltaTime: dt)
        tickWanderers(deltaTime: dt)
        tickPickups(deltaTime: dt)
        tickProximity()
        placeCamera()
    }

    private var obstacles: [BoardRect] { board.obstacles }

    private func boardPoint(_ p: SIMD2<Float>) -> SIMD3<Float> {
        SIMD3(p.x, 0, p.y)
    }

    private func tickPlayer(deltaTime dt: Float) {
        var delta = SIMD2<Float>.zero
        var heading = playerYaw

        if simd_length(moveInput) > 0.06 {
            // The thumbstick owns the player; a tap-walk is cancelled.
            walkTargetPoint = nil
            walkTargetSiteID = nil
            // Screen up is north (away from the camera); board y is south.
            delta = SIMD2(moveInput.x, -moveInput.y) * walkSpeed * dt
            if simd_length(delta) > 0.0001 { heading = atan2(delta.x, delta.y) }
        } else if let target = walkTargetPoint {
            let step = WorldWalk.stepToward(from: playerBoardPosition, target: target,
                                            speed: walkSpeed * 0.82, dt: dt)
            if step.arrived {
                walkTargetPoint = nil
                walkTargetSiteID = nil
            } else if let h = step.heading {
                delta = step.position - playerBoardPosition
                heading = h
            }
        }

        let moving = simd_length(delta) > 0.0001
        if moving {
            playerBoardPosition = WorldWalk.slide(from: playerBoardPosition, delta: delta,
                                                  obstacles: obstacles,
                                                  bounds: board.walkableRect)
            player.position = boardPoint(playerBoardPosition)
            playerYaw = lerpAngle(playerYaw, toward: heading, amount: min(1, dt * 12))
            player.orientation = simd_quatf(angle: playerYaw, axis: [0, 1, 0])

            walkPhase += dt * 11
            swingLegs(playerParts?.legL, playerParts?.legR, phase: walkPhase, amount: 0.55)
            playerParts?.body.position = SIMD3(0, 0.72 + abs(sin(walkPhase)) * 0.035, 0)
        } else {
            walkPhase = 0
            swingLegs(playerParts?.legL, playerParts?.legR, phase: 0, amount: 0)
            playerParts?.body.position = SIMD3(0, 0.72, 0)
        }
    }

    private func tickWanderers(deltaTime dt: Float) {
        guard !wanderers.isEmpty else { return }
        for index in wanderers.indices {
            var w = wanderers[index]
            if w.pauseRemaining > 0 {
                w.pauseRemaining -= dt
                swingLegs(w.legs.0, w.legs.1, phase: 0, amount: 0)
            } else {
                let step = WorldWalk.stepToward(from: w.position, target: w.target,
                                                speed: 1.2, dt: dt, stopRadius: 0.6)
                if step.arrived {
                    w.target = localWanderTarget(anchor: w.anchor, rng: &w.rng)
                    w.pauseRemaining = w.rng.float(in: 1.5...4.0)
                } else {
                    w.position = WorldWalk.slide(from: w.position,
                                                 delta: step.position - w.position,
                                                 obstacles: obstacles,
                                                 bounds: board.walkableRect,
                                                 radius: 0.5)
                    if let h = step.heading { w.heading = lerpAngle(w.heading, toward: h, amount: min(1, dt * 8)) }
                    w.phase += dt * 9
                    swingLegs(w.legs.0, w.legs.1, phase: w.phase, amount: 0.5)
                }
            }
            w.entity.position = boardPoint(w.position)
            w.entity.orientation = simd_quatf(angle: w.heading, axis: [0, 1, 0])
            w.labelAnchor = boardPoint(w.position) + SIMD3(0, 2.55, 0)
            wanderers[index] = w
        }
    }

    private func tickPickups(deltaTime dt: Float) {
        let t = Float(CACurrentMediaTime().truncatingRemainder(dividingBy: 100))
        for index in pickups.indices {
            let item = pickups[index]
            item.entity.position = boardPoint(item.at) + SIMD3(0, 0.07 * sin(t * 2.2 + Float(index)), 0)
            if simd_distance(playerBoardPosition, item.at) < 1.35,
               !collected.contains(item.pickup.id) {
                collected.insert(item.pickup.id)
                item.entity.removeFromParent()
                onPickup?(item.pickup)
            }
        }
    }

    private func tickProximity() {
        let positions = board.sitePositions.map { ($0.key, $0.value) }
        let nearest = WorldWalk.nearestSite(to: playerBoardPosition,
                                            positions: positions,
                                            maxDistance: siteCardRadius)
        if nearest != nearSiteID {
            nearSiteID = nearest
            onNearSite?(nearest)
        }

        let doorDistance = simd_distance(playerBoardPosition, board.officeDoorPoint)
        if doorDistance > 4.5 { officeDoorArmed = true }
        if officeDoorArmed && doorDistance < 1.8 {
            officeDoorArmed = false
            onEnterOffice?()
        }
    }

    private func placeCamera() {
        // Fit the board's width at the SOUTHERN SITES ROW to the portrait
        // viewport (the near edge is where width is tightest; everything
        // farther north is deeper in the frame and fits for free). Solve
        // the ground distance cz from the triangle
        //   (cz - fitZ)^2 + (cz * tanE)^2 = fitDistance^2
        // then hang the camera above it at the diorama angle. The near
        // foreground past the fit row is open sea, which fills the bottom
        // of the frame instead of leaving a sky margin under a tabletop.
        let bounds = arView.bounds.size
        let aspect = bounds.width > 1 && bounds.height > 1
            ? Float(bounds.width / bounds.height)
            : Float(1179.0 / 2556.0)
        let verticalFOV = fovDegrees * .pi / 180
        let horizontalFOV = 2 * atan(tan(verticalFOV / 2) * max(aspect, 0.35))
        let halfSpan = WorldBoard.size.x * cameraBoardMargin / 2
        let fitDistance = halfSpan / max(tan(horizontalFOV / 2), 0.05)
        let fitZ = cameraFitRowZ
        let tanE = tan(cameraElevation)
        let a = 1 + tanE * tanE
        let discriminant = 4 * (a * fitDistance * fitDistance - tanE * tanE * fitZ * fitZ)
        let cz = discriminant > 0 ? (2 * fitZ + sqrt(discriminant)) / (2 * a) : fitDistance

        let lookX = cameraLookX
        cameraEntity.position = SIMD3(lookX, cz * tanE, cz)
        cameraEntity.look(at: SIMD3(lookX, 0.5, -3.0), from: cameraEntity.position, relativeTo: nil)
        updateBillboards()
    }

    /// Billboards every floating card (site labels, crew nameplates) to the
    /// camera, scaling with distance so text stays legible on a phone, then
    /// staggers cards that would cover each other: cards are projected to
    /// screen space, and a top-down sweep drops any card whose plate would
    /// overlap one above it — the north row fans out into a readable stack
    /// instead of a pile. Site cards staggered far from home get a thin
    /// leader line back to their pin.
    private func updateBillboards() {
        let size = arView.bounds.size
        guard size.width > 1, size.height > 1 else { return }
        guard !siteLabels.isEmpty || !wanderers.isEmpty else { return }

        let cameraPosition = cameraEntity.position(relativeTo: nil)
        let cameraRotation = cameraEntity.orientation(relativeTo: nil)
        let aspect = Float(size.width / size.height)
        let tanHalfV = tan(fovDegrees * .pi / 180 / 2)
        let tanHalfH = tanHalfV * aspect
        let right = cameraRotation.act(SIMD3<Float>(1, 0, 0))
        let up = cameraRotation.act(SIMD3<Float>(0, 1, 0))
        let forward = cameraRotation.act(SIMD3<Float>(0, 0, -1))

        // One working list: site cards (with pins/leaders), then crew plates.
        struct Placed {
            let entity: Entity
            let halfSize: SIMD2<Float>   // local plate half extents
            let anchor: SIMD3<Float>
            let scale: Float
            let pxPerWorld: Float        // screen pixels per world unit at depth
            let home: SIMD2<Float>       // projected center before staggering
            var center: SIMD2<Float>     // center after staggering
        }
        var cards: [(Entity, SIMD2<Float>, SIMD3<Float>)] = []
        for label in siteLabels {
            cards.append((label.entity, label.halfSize, label.anchor))
        }
        for wanderer in wanderers {
            cards.append((wanderer.label, wanderer.labelHalf, wanderer.labelAnchor))
        }

        var placed: [Placed] = []
        for (entity, halfSize, anchor) in cards {
            let rel = anchor - cameraPosition
            let depth = -simd_dot(rel, forward)
            guard depth > 0.5 else { continue }
            let offset = SIMD2(simd_dot(rel, right), simd_dot(rel, up))
            let ndc = SIMD2(offset.x / (tanHalfH * depth), offset.y / (tanHalfV * depth))
            let center = SIMD2((ndc.x * 0.5 + 0.5) * Float(size.width),
                               (1 - (ndc.y * 0.5 + 0.5)) * Float(size.height))
            let scale = min(max(depth / 26, 1.7), 3.4)
            // Matching the camera orientation keeps the label plate parallel
            // to the screen while its +Z face points back toward the camera.
            entity.scale = SIMD3(repeating: scale)
            entity.orientation = cameraRotation
            placed.append(Placed(
                entity: entity, halfSize: halfSize, anchor: anchor, scale: scale,
                pxPerWorld: (Float(size.height) / 2) / (tanHalfV * depth),
                home: center, center: center))
        }

        // Stagger sweep, top of the screen downward: a card whose x-range
        // meaningfully overlaps a card above it drops below that card. One
        // pass in y order settles the whole stack; later cards check the
        // already-dropped positions of every earlier one.
        let order = placed.indices.sorted {
            placed[$0].home.y < placed[$1].home.y ||
            (placed[$0].home.y == placed[$1].home.y && placed[$0].home.x < placed[$1].home.x)
        }
        let pad: Float = 9
        let heightPx = Float(size.height)
        for k in order.indices {
            let i = order[k]
            let aHalfY = placed[i].halfSize.y * placed[i].scale * placed[i].pxPerWorld
            let aHalfX = placed[i].halfSize.x * placed[i].scale * placed[i].pxPerWorld
            for l in 0..<k {
                let j = order[l]
                let bHalfY = placed[j].halfSize.y * placed[j].scale * placed[j].pxPerWorld
                let bHalfX = placed[j].halfSize.x * placed[j].scale * placed[j].pxPerWorld
                let overlapX = min(placed[i].center.x + aHalfX, placed[j].center.x + bHalfX)
                    - max(placed[i].center.x - aHalfX, placed[j].center.x - bHalfX)
                guard overlapX > 0.35 * min(aHalfX, bHalfX) else { continue }
                let minGap = aHalfY + bHalfY + pad
                if placed[i].center.y - placed[j].center.y < minGap {
                    placed[i].center.y = placed[j].center.y + minGap
                }
            }
            // The stack stays off the HUD above and the thumbstick below,
            // and no card travels absurdly far from where it belongs.
            let maxTravel = max(placed[i].home.y,
                                min(placed[i].home.y + heightPx * 0.16, heightPx * 0.92 - aHalfY))
            placed[i].center.y = min(placed[i].center.y, maxTravel)
            placed[i].center.y = max(placed[i].center.y, heightPx * 0.135 + aHalfY)
        }

        // Apply: screen-space drops become world-space offsets along the
        // camera's up axis (cards are billboards, so up is always on-screen
        // "up"). A site card displaced far from its pin grows a leader.
        for card in placed {
            let dropPx = card.center.y - card.home.y
            card.entity.position = dropPx > 0.5
                ? card.anchor - up * (dropPx / card.pxPerWorld)
                : card.anchor
        }
        for label in siteLabels {
            guard let card = placed.first(where: { $0.entity === label.entity }) else { continue }
            let dropPx = card.center.y - card.home.y
            let staggered = dropPx > 26
            label.leader.isEnabled = staggered
            guard staggered else { continue }
            let plateBottom = card.entity.position - up * (card.halfSize.y * card.scale)
            let pinHead = label.pinHead
            let delta = plateBottom - pinHead
            let length = simd_length(delta)
            guard length > 0.01 else { continue }
            label.leader.scale = SIMD3(0.035, length, 0.035)
            label.leader.position = (plateBottom + pinHead) / 2
            label.leader.orientation = simd_quatf(from: SIMD3(0, 1, 0), to: delta / length)
        }
    }

    // MARK: Animation helpers

    private func swingLegs(_ legL: Entity?, _ legR: Entity?, phase: Float, amount: Float) {
        let swing = sin(phase) * amount
        for (leg, sign) in [(legL, Float(1)), (legR, Float(-1))] {
            leg?.orientation = simd_quatf(angle: swing * sign, axis: [1, 0, 0])
        }
    }

    private func lerpAngle(_ from: Float, toward to: Float, amount: Float) -> Float {
        var delta = to - from
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return from + delta * amount
    }

    // MARK: Tap-to-walk

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: arView)
        let size = arView.bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let aspect = Float(size.width / size.height)
        let tanHalf = tan(fovDegrees * .pi / 180 / 2)
        let ndcX = (2 * Float(location.x) / Float(size.width)) - 1
        let ndcY = 1 - (2 * Float(location.y) / Float(size.height))
        let dirCamera = SIMD3(ndcX * tanHalf * aspect, ndcY * tanHalf, -1)
        let direction = normalize(cameraEntity.orientation.act(dirCamera))
        let origin = cameraEntity.position(relativeTo: nil)

        let hits = arView.scene.raycast(origin: origin, direction: direction,
                                        length: 220, query: .all)
        guard let hit = hits.min(by: { $0.distance < $1.distance }) else { return }

        // A named building group means "walk to that site's door".
        var cursor: Entity? = hit.entity
        while let current = cursor {
            if current.name.hasPrefix("site:") {
                let siteID = String(current.name.dropFirst(5))
                if let footprint = board.buildingFootprints[siteID] {
                    walkTargetSiteID = siteID
                    walkTargetPoint = WorldWalk.approachPoint(
                        for: footprint, from: playerBoardPosition, standoff: 2.1)
                    return
                }
            }
            cursor = current.parent
        }

        // Otherwise: walk to the tapped ground point.
        let point = SIMD2<Float>(hit.position.x, hit.position.z)
        let resolved = WorldWalk.resolveTap(
            point, footprints: board.buildingFootprints.map { (id: $0.key, rect: $0.value) })
        switch resolved {
        case .point(let p):
            walkTargetSiteID = nil
            walkTargetPoint = WorldWalk.clamp(p, to: board.walkableRect)
        case .site(let id):
            walkTargetSiteID = id
            walkTargetPoint = WorldWalk.approachPoint(
                for: board.buildingFootprints[id] ?? board.officeFootprint,
                from: playerBoardPosition, standoff: 2.1)
        }
    }
}

// MARK: - SwiftUI wrapper

struct WorldRealityView: UIViewRepresentable {
    let world: WorldState
    var moveInput = SIMD2<Float>.zero
    var onNearSite: ((String?) -> Void)?
    var onPickup: ((WorldPickup) -> Void)?
    var onEnterOffice: (() -> Void)?
    var artProvider: any WorldArtProviding = WorldArt.provider

    func makeCoordinator() -> WorldGameController {
        WorldGameController(frame: .zero, artProvider: artProvider)
    }

    func makeUIView(context: Context) -> ARView {
        wire(context.coordinator)
        context.coordinator.applyWorld(world)
        return context.coordinator.arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        wire(context.coordinator)
        context.coordinator.applyWorld(world)
    }

    private func wire(_ controller: WorldGameController) {
        controller.moveInput = moveInput
        controller.onNearSite = onNearSite
        controller.onPickup = onPickup
        controller.onEnterOffice = onEnterOffice
    }
}
