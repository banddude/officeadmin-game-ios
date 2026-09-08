//  WorldRealityView.swift
//  OfficeAdminGame
//
//  The world as a game, not a map: a RealityKit diorama board built from the
//  pure WorldBoard layout (real coordinates projected to the ground), with
//  the player character walked by thumbstick or tap, a follow camera at a
//  cozy fixed angle, crew wandering between sites, and attention items
//  waiting to be picked up by walking into them. Apple Maps is never the
//  visual — only the geocoder behind the scenes.
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
    private let cameraOffset = SIMD3<Float>(0, 24, 14)

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
            placeCamera(instant: true)
        }
    }

    private func rebuildBoard() {
        worldRoot.children.forEach { $0.removeFromParent() }

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
            label.position = SIMD3(footprint.center.x, roofline + 1.7, footprint.center.y)
            worldRoot.addChild(label)
        }
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
        let legs: (Entity, Entity)
        var position: SIMD2<Float>
        var target: SIMD2<Float>
        var pauseRemaining: Float
        var heading: Float
        var phase: Float
        var rng: SeededGenerator
    }

    private var crewSignature = ""

    private func rebuildCrewIfNeeded(_ world: WorldState) {
        let crew = world.crew.filter { !$0.isPlayer }.prefix(4)
        let signature = crew.map { "\($0.id)@\($0.assignmentSiteID ?? "office")" }.joined(separator: "|")
        guard signature != crewSignature else { return }
        crewSignature = signature

        wanderers.forEach { $0.entity.removeFromParent() }
        wanderers = []

        let shirts: [UIColor] = [WorldPalette.canopy, WorldPalette.sky, UIColor(Theme.clay),
                                 WorldPalette.blend(WorldPalette.canopy, toward: .white, fraction: 0.2)]
        var available = Array(board.sitePositions.values)
        available.append(board.officeDoorPoint + SIMD2(3, 2))
        guard !available.isEmpty else { return }

        for (index, member) in crew.enumerated() {
            var rng = SeededGenerator(SeededGenerator.seed(from: ["crew", member.id]))
            let start = available[index % available.count]
            let entity = WorldPropFactory.character(shirt: shirts[index % shirts.count])
            entity.position = boardPoint(start)
            anchor.addChild(entity)
            guard let legL = entity.findEntity(named: "legL"),
                  let legR = entity.findEntity(named: "legR") else { continue }
            wanderers.append(Wanderer(
                entity: entity,
                legs: (legL, legR),
                position: start,
                target: start,
                pauseRemaining: rng.float(in: 0.5...2.5),
                heading: rng.float(in: 0...(2 * .pi)),
                phase: rng.float(in: 0...(2 * .pi)),
                rng: rng))
        }
    }

    /// Where a crew member might be headed: a site's front step or the office.
    private var wanderTargets: [SIMD2<Float>] {
        var targets = board.buildingFootprints.values.map {
            WorldWalk.approachPoint(for: $0, from: SIMD2($0.center.x, $0.maxY + 6), standoff: 1.6)
        }
        targets.append(board.officeDoorPoint + SIMD2(1.5, 1.5))
        return targets
    }

    // MARK: Per-frame update

    private func tick(deltaTime dt: Float) {
        tickPlayer(deltaTime: dt)
        tickWanderers(deltaTime: dt)
        tickPickups(deltaTime: dt)
        tickProximity()
        placeCamera(instant: false, deltaTime: dt)
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
        let targets = wanderTargets
        guard !targets.isEmpty else { return }
        for index in wanderers.indices {
            var w = wanderers[index]
            if w.pauseRemaining > 0 {
                w.pauseRemaining -= dt
                swingLegs(w.legs.0, w.legs.1, phase: 0, amount: 0)
            } else {
                let step = WorldWalk.stepToward(from: w.position, target: w.target,
                                                speed: 1.5, dt: dt, stopRadius: 0.6)
                if step.arrived {
                    w.target = targets[Int(w.rng.next() % UInt64(targets.count))]
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

    private func placeCamera(instant: Bool, deltaTime dt: Float = 0.016) {
        let desired = boardPoint(playerBoardPosition) + cameraOffset
        if instant {
            cameraEntity.position = desired
        } else {
            let blend = 1 - exp(-4.5 * dt)
            cameraEntity.position = cameraEntity.position + (desired - cameraEntity.position) * blend
        }
        // Aim north of the player so the board ahead fills the frame and the
        // horizon sits near the top edge, like the mockup's diorama view.
        cameraEntity.look(at: boardPoint(playerBoardPosition) + SIMD3(0, 0.9, -6),
                          from: cameraEntity.position, relativeTo: nil)
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
