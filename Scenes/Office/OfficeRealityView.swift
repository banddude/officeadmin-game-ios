//  OfficeRealityView.swift
//  OfficeAdminGame
//
//  The walkable 3D office: a RealityKit scene (no AR) built entirely from
//  procedural geometry — floor, walls, desk, chair, whiteboard with real
//  notes, a plant, coin stacks for receivables, and a mail pile whose
//  envelopes ARE the pending approval requests. A thumbstick walks the
//  player; tapping an envelope opens its card (see OfficeSceneView).
//
//  Picking: we own the camera, so a tap is unprojected through the camera
//  transform into a ray and cast against collision shapes — no AR hit-test.

import RealityKit
import SwiftUI
import UIKit

// MARK: - Controller (owns the scene)

final class OfficeController: NSObject {
    let arView: ARView
    private let artProvider: any WorldArtProviding
    private let anchor = AnchorEntity(world: .zero)
    private var tapGesture: UITapGestureRecognizer!

    /// Unprojection assumes the default PerspectiveCameraComponent fov (60°).
    private let fovDegrees: Float = 60
    private var player = Entity()
    private var cameraEntity = Entity()
    private var playerFacing: Float = 0 // radians, 0 = looking toward -Z (desk)

    private(set) var envelopes: [Entity] = []
    /// Everything rebuilt on each world refetch (mail, coins, notes).
    private var dynamicEntities: [Entity] = []
    private var furnitureBounds: [(min: SIMD2<Float>, max: SIMD2<Float>)] = []

    var moveInput: SIMD2<Float> = .zero    // x strafe, y forward (-1...1)
    var onTapMail: ((String) -> Void)?

    // Palette (matches AppTheme; UIColor because RealityKit materials)
    private let floorColor = UIColor(red: 0.72, green: 0.55, blue: 0.38, alpha: 1)
    private let wallColor = UIColor(red: 0.96, green: 0.91, blue: 0.80, alpha: 1)
    private let woodColor = UIColor(red: 0.52, green: 0.36, blue: 0.24, alpha: 1)
    private let inkColor = UIColor(red: 0.24, green: 0.20, blue: 0.16, alpha: 1)

    // Room extents (meters); the player is clamped to walkable space.
    private let roomHalf: SIMD2<Float> = SIMD2(5.0, 4.0)
    private let wallT: Float = 0.15

    init(frame: CGRect, artProvider: any WorldArtProviding = WorldArt.provider) {
        self.artProvider = artProvider
        arView = ARView(frame: frame)
        super.init()

        // iOS 17: non-AR mode is an ARView property, not a camera-component
        // mode (that arrives in iOS 18). Default camera fov is ~60 degrees.
        arView.cameraMode = .nonAR
        arView.environment.background = .color(UIColor(red: 0.62, green: 0.80, blue: 0.90, alpha: 1))
        arView.scene.addAnchor(anchor)

        buildRoom()
        buildLights()

        cameraEntity.components.set(PerspectiveCameraComponent())
        anchor.addChild(cameraEntity)

        player = makePlayer()
        player.position = SIMD3(0, 0, 2.4)
        anchor.addChild(player)
        placeCamera()

        // Subscription lives for the scene's lifetime (the token is discarded).
        _ = arView.scene.subscribe(to: SceneEvents.Update.self, { [weak self] event in
            self?.tick(deltaTime: Float(event.deltaTime))
        })

        tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        arView.addGestureRecognizer(tapGesture)
    }

    // MARK: Scene construction (procedural, original geometry only)

    private func box(_ size: SIMD3<Float>, _ color: UIColor,
                     at position: SIMD3<Float>,
                     rotation: Float? = nil,
                     collision: Bool = false) -> Entity {
        let entity = Entity()
        let mesh = MeshResource.generateBox(size: size)
        let material = SimpleMaterial(color: color, isMetallic: false)
        entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
        entity.position = position
        if let rotation {
            entity.orientation = simd_quatf(angle: rotation, axis: [0, 1, 0])
        }
        if collision {
            entity.generateCollisionShapes(recursive: false)
        }
        return entity
    }

    /// A paper, sign, or decal prop built only from the injected art provider.
    private func paperBox(_ size: SIMD3<Float>, kind: WorldArt.SurfaceKind,
                          at position: SIMD3<Float>,
                          rotation: Float? = nil) -> Entity {
        let entity = Entity()
        let mesh = MeshResource.generateBox(size: size)
        let surface = artProvider.surface(kind)
        let material: SimpleMaterial
        if let image = surface.image, let cgImage = image.cgImage,
           let texture = try? TextureResource.generate(
               from: cgImage,
               options: TextureResource.CreateOptions(semantic: .color)) {
            material = SimpleMaterial(texture: texture, isMetallic: false)
        } else {
            material = SimpleMaterial(color: surface.tint, isMetallic: false)
        }
        entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
        entity.position = position
        if let rotation {
            entity.orientation = simd_quatf(angle: rotation, axis: [0, 1, 0])
        }
        return entity
    }

    /// A squashed sphere: iOS 17 has no short-cylinder generator, and coins,
    /// rugs, pots and seals are all discs anyway.
    private func disc(radius: Float, thickness: Float, color: UIColor) -> Entity {
        let entity = Entity()
        entity.components.set(ModelComponent(
            mesh: MeshResource.generateSphere(radius: radius),
            materials: [SimpleMaterial(color: color, isMetallic: false)]))
        entity.scale = SIMD3<Float>(1, thickness / (radius * 2), 1)
        return entity
    }

    private func buildRoom() {
        // Floor + rug
        anchor.addChild(box(SIMD3(roomHalf.x * 2, 0.2, roomHalf.y * 2), floorColor,
                            at: SIMD3(0, -0.1, 0), collision: true))
        let rug = disc(radius: 1.7, thickness: 0.03,
                       color: UIColor(red: 0.47, green: 0.63, blue: 0.47, alpha: 1))
        rug.position = SIMD3(0, 0.015, 0.6)
        anchor.addChild(rug)

        // Walls (front wall split for a doorway feel; player spawns inside)
        let wallHeight: Float = 3.0
        let t: Float = 0.15
        anchor.addChild(box(SIMD3(roomHalf.x * 2, wallHeight, t), wallColor,
                            at: SIMD3(0, wallHeight / 2, -roomHalf.y), collision: true))
        anchor.addChild(box(SIMD3(t, wallHeight, roomHalf.y * 2), wallColor,
                            at: SIMD3(-roomHalf.x, wallHeight / 2, 0), collision: true))
        anchor.addChild(box(SIMD3(t, wallHeight, roomHalf.y * 2), wallColor,
                            at: SIMD3(roomHalf.x, wallHeight / 2, 0), collision: true))
        anchor.addChild(box(SIMD3(1.6, wallHeight, t), wallColor,
                            at: SIMD3(-roomHalf.x + 0.8 + 0.4, wallHeight / 2, roomHalf.y), collision: true))
        anchor.addChild(box(SIMD3(1.6, wallHeight, t), wallColor,
                            at: SIMD3(roomHalf.x - 0.8 - 0.4, wallHeight / 2, roomHalf.y), collision: true))
        anchor.addChild(box(SIMD3(1.8, 0.9, t), wallColor,
                            at: SIMD3(0, wallHeight - 0.45, roomHalf.y), collision: true))

        // Desk (top + legs) against the back wall, chair facing it
        let deskTop = box(SIMD3(2.4, 0.09, 1.05), woodColor, at: SIMD3(0, 0.76, -3.0))
        anchor.addChild(deskTop)
        for (lx, lz) in [(Float(-1.08), Float(-3.44)), (1.08, -3.44), (-1.08, -2.56), (1.08, -2.56)] {
            anchor.addChild(box(SIMD3(0.09, 0.74, 0.09), woodColor, at: SIMD3(lx, 0.37, lz)))
        }
        anchor.addChild(box(SIMD3(0.6, 0.07, 0.6), woodColor, at: SIMD3(0, 0.48, -1.9)))
        anchor.addChild(box(SIMD3(0.6, 0.75, 0.07), woodColor, at: SIMD3(0, 0.86, -1.62)))
        furnitureBounds.append((min: SIMD2(-1.25, -3.6), max: SIMD2(1.25, -2.4)))
        furnitureBounds.append((min: SIMD2(-0.35, -2.0), max: SIMD2(0.35, -1.6)))

        // Whiteboard on the back wall: frame + board + TODAY heading
        let boardZ: Float = -roomHalf.y + t / 2 + 0.05
        anchor.addChild(box(SIMD3(2.6, 1.5, 0.05), woodColor,
                            at: SIMD3(-0.0, 1.7, boardZ + 0.01)))
        anchor.addChild(paperBox(SIMD3(2.44, 1.34, 0.04), kind: .officeWhiteboard,
                                 at: SIMD3(0, 1.7, boardZ + 0.045)))
        addText("TODAY", at: SIMD3(-1.0, 2.2, boardZ + 0.08), height: 0.14, color: inkColor)

        // Plant in the corner: pot + foliage blobs
        let pot = disc(radius: 0.22, thickness: 0.35,
                       color: UIColor(red: 0.80, green: 0.48, blue: 0.33, alpha: 1))
        pot.position = SIMD3(roomHalf.x - 0.7, 0.175, -roomHalf.y + 0.7)
        anchor.addChild(pot)
        let leaf = Entity()
        leaf.components.set(ModelComponent(
            mesh: MeshResource.generateSphere(radius: 0.34),
            materials: [SimpleMaterial(color: UIColor(red: 0.36, green: 0.56, blue: 0.34, alpha: 1),
                                       isMetallic: false)]))
        leaf.position = SIMD3(roomHalf.x - 0.7, 0.62, -roomHalf.y + 0.7)
        anchor.addChild(leaf)

        // MAIL sign above the pile
        addText("MAIL", at: SIMD3(0.85, 1.35, -3.5), height: 0.12, color: UIColor(red: 0.64, green: 0.28, blue: 0.22, alpha: 1))
    }

    private func buildLights() {
        let sun = Entity()
        sun.components.set(DirectionalLightComponent(color: .white,
                                                     intensity: 900,
                                                     isRealWorldProxy: false))
        sun.orientation = simd_quatf(angle: Float.pi * 0.22, axis: [1, 0, 0])
        sun.position = SIMD3(0, 6, 2)
        anchor.addChild(sun)

        let fill = Entity()
        fill.components.set(DirectionalLightComponent(color: UIColor(red: 0.95, green: 0.93, blue: 0.85, alpha: 1),
                                                      intensity: 350,
                                                      isRealWorldProxy: false))
        fill.orientation = simd_quatf(angle: -Float.pi * 0.25, axis: [1, 0, 0])
        anchor.addChild(fill)
    }

    private func makePlayer() -> Entity {
        let player = Entity()
        let body = Entity()
        body.components.set(ModelComponent(
            mesh: MeshResource.generateSphere(radius: 0.34),
            materials: [SimpleMaterial(color: UIColor(red: 0.80, green: 0.48, blue: 0.33, alpha: 1),
                                       isMetallic: false)]))
        body.scale = SIMD3<Float>(0.9, 1.7, 0.9)   // egg-shaped placeholder character
        body.position = SIMD3(0, 0.60, 0)
        player.addChild(body)
        let head = Entity()
        head.components.set(ModelComponent(
            mesh: MeshResource.generateSphere(radius: 0.26),
            materials: [SimpleMaterial(color: UIColor(red: 0.96, green: 0.87, blue: 0.75, alpha: 1),
                                       isMetallic: false)]))
        head.position = SIMD3(0, 1.42, 0)
        player.addChild(head)
        // Little cap so the player reads as "the boss"
        let cap = disc(radius: 0.27, thickness: 0.12, color: inkColor)
        cap.position = SIMD3(0, 1.60, 0)
        player.addChild(cap)
        return player
    }

    @discardableResult
    private func addText(_ string: String, at position: SIMD3<Float>,
                         height: Float, color: UIColor) -> Entity {
        let entity = Entity()
        let mesh = MeshResource.generateText(
            string,
            extrusionDepth: 0.02,
            font: .systemFont(ofSize: CGFloat(height), weight: .bold),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byWordWrapping)
        entity.components.set(ModelComponent(mesh: mesh, materials: [UnlitMaterial(color: color)]))
        // Center the text's visual bounds on the anchor point.
        if let bounds = entity.components[ModelComponent.self]?.mesh.bounds {
            entity.position = position - SIMD3(bounds.center.x, bounds.center.y, bounds.center.z)
        } else {
            entity.position = position
        }
        anchor.addChild(entity)
        return entity
    }

    // MARK: Dynamic world state (rebuilt on refetch)

    /// Rebuild the mail pile + coin stacks + whiteboard notes from world state.
    /// Everything dynamic is tracked and cleared first, so a refetch reshapes
    /// the world instead of stacking on top of it.
    func applyWorld(_ world: WorldState) {
        for entity in dynamicEntities {
            entity.removeFromParent()
        }
        dynamicEntities.removeAll()
        envelopes.removeAll()

        // Mail pile on the right of the desk. Cap the physical stack; the
        // world still shows the true count via the pile's "overflow" letter.
        let mail = world.mail
        let placed = min(mail.count, 9)
        for (idx, item) in mail.prefix(placed).enumerated() {
            let row = idx / 3
            let col = idx % 3
            let envelope = paperBox(
                SIMD3(0.34, 0.025, 0.24), kind: .envelope,
                at: SIMD3(0.72 + Float(col) * 0.16,
                          0.82 + Float(row) * 0.028,
                          -3.02 + Float(row) * 0.02),
                rotation: Float.random(in: -0.35...0.35))
            // Wax seal by kind — the envelope's identity in the world.
            let sealColor: UIColor
            switch item.kind {
            case .invoice: sealColor = UIColor(red: 0.64, green: 0.28, blue: 0.22, alpha: 1)
            case .bill: sealColor = UIColor(red: 0.72, green: 0.55, blue: 0.76, alpha: 1)
            case .expense: sealColor = UIColor(red: 0.93, green: 0.72, blue: 0.33, alpha: 1)
            case .journalEntry: sealColor = UIColor(red: 0.47, green: 0.63, blue: 0.47, alpha: 1)
            case .purchaseOrder: sealColor = UIColor(red: 0.62, green: 0.80, blue: 0.90, alpha: 1)
            }
            let seal = disc(radius: 0.035, thickness: 0.012, color: sealColor)
            seal.position = SIMD3(0.09, 0.02, 0.05)
            envelope.addChild(seal)
            envelope.name = "mail:\(item.id)"
            envelope.generateCollisionShapes(recursive: true)
            anchor.addChild(envelope)
            dynamicEntities.append(envelope)
            envelopes.append(envelope)
        }
        if mail.count > placed {
            dynamicEntities.append(
                addText("+\(mail.count - placed) more", at: SIMD3(0.85, 1.05, -3.0),
                        height: 0.06, color: inkColor))
        }

        // Coin stack (outstanding receivables) on the left of the desk.
        let coinCount = min(world.money.outstandingCount, 14)
        for i in 0..<coinCount {
            let coin = disc(radius: 0.085, thickness: 0.016,
                            color: UIColor(red: 0.85, green: 0.66, blue: 0.27, alpha: 1))
            coin.position = SIMD3(-0.85 + Float(i % 2) * 0.19, 0.83 + Float(i / 2) * 0.018, -3.05)
            anchor.addChild(coin)
            dynamicEntities.append(coin)
        }

        // Red letters pile (overdue) — lies open on the desk front.
        let letterCount = min(world.money.overdueCount, 6)
        for i in 0..<letterCount {
            let letter = paperBox(SIMD3(0.30, 0.012, 0.21), kind: .letter,
                                  at: SIMD3(-0.55 + Float(i) * 0.05, 0.82 + Float(i) * 0.013, -2.62),
                                  rotation: Float.random(in: -0.25...0.25))
            anchor.addChild(letter)
            dynamicEntities.append(letter)
        }

        // Whiteboard notes: overdue + coming-due invoices as sticky notes.
        let notes = world.whiteboard
        let columns = 3
        for (idx, note) in notes.prefix(8).enumerated() {
            let col = idx % columns
            let row = idx / columns
            let sticky = paperBox(SIMD3(0.34, 0.001, 0.30),
                                  kind: note.isUrgent ? .letter : .stickyNote,
                                  at: SIMD3(-1.02 + Float(col) * 0.56, 1.78 - Float(row) * 0.40,
                                            -roomHalf.y + wallT / 2 + 0.075))
            sticky.orientation = simd_quatf(angle: Float.random(in: -0.06...0.06), axis: [0, 1, 0])
            anchor.addChild(sticky)
            dynamicEntities.append(sticky)
        }
    }

    // MARK: Per-frame movement + camera

    private func tick(deltaTime: Float) {
        let speed: Float = 1.9
        if abs(moveInput.x) > 0.05 || abs(moveInput.y) > 0.05 {
            // Joystick y is "up on screen" = walk away from camera = -Z-ish,
            // relative to where the camera looks.
            let yaw = cameraYaw()
            let forward = SIMD2(-sin(yaw), -cos(yaw))
            let right = SIMD2(-forward.y, forward.x)
            var delta = (forward * moveInput.y + right * moveInput.x) * speed * deltaTime
            var next = SIMD2(player.position.x, player.position.z) + delta

            // Keep the player in the room and out of the desk block.
            next.x = min(max(next.x, -roomHalf.x + 0.45), roomHalf.x - 0.45)
            next.y = min(max(next.y, -roomHalf.y + 0.45), roomHalf.y - 0.45)
            for bounds in furnitureBounds {
                if next.x > bounds.min.x - 0.3 && next.x < bounds.max.x + 0.3 &&
                    next.y > bounds.min.y - 0.3 && next.y < bounds.max.y + 0.3 {
                    // Push out along the axis we came from.
                    let prev = SIMD2(player.position.x, player.position.z)
                    if abs(prev.x - bounds.min.x + 0.3) < abs(prev.y - bounds.min.y + 0.3) {
                        next.x = prev.x < (bounds.min.x + bounds.max.x) / 2
                            ? bounds.min.x - 0.3 : bounds.max.x + 0.3
                    } else {
                        next.y = prev.y < (bounds.min.y + bounds.max.y) / 2
                            ? bounds.min.y - 0.3 : bounds.max.y + 0.3
                    }
                }
            }

            playerFacing = atan2(delta.x, delta.y) + Float.pi
            player.position = SIMD3(next.x, 0, next.y)
            player.orientation = simd_quatf(angle: playerFacing, axis: [0, 1, 0])
        }
        placeCamera()
    }

    private func cameraYaw() -> Float {
        // The camera looks toward the player; its facing yaw about Y.
        // (Anchor sits at the world origin, so its local = world space.)
        let forward = cameraEntity.orientation.act(SIMD3<Float>(0, 0, -1))
        return atan2(forward.x, forward.z)
    }

    private func placeCamera() {
        let target = player.position + SIMD3(0, 1.35, 0)
        // Behind the player relative to where the player faces.
        let facing = SIMD2(sin(playerFacing), cos(playerFacing))
        var back = SIMD3(-facing.x, 0, -facing.y) * 3.1
        back.y = 2.1
        var camPos = target + back
        camPos.x = min(max(camPos.x, -roomHalf.x + 0.4), roomHalf.x - 0.4)
        camPos.z = min(max(camPos.z, -roomHalf.y + 0.4), roomHalf.y - 0.4)
        camPos.y = 2.1
        cameraEntity.position = camPos
        cameraEntity.look(at: target, from: camPos, relativeTo: nil)
    }

    // MARK: Picking

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: arView)
        let size = arView.bounds.size
        guard size.width > 0, size.height > 0 else { return }

        // Unproject through the camera we own.
        let aspect = Float(size.width / size.height)
        let tanHalf = tan(fovDegrees * .pi / 180 / 2)
        let ndcX = (2 * Float(location.x) / Float(size.width)) - 1
        let ndcY = 1 - (2 * Float(location.y) / Float(size.height))
        let dirCamera = SIMD3(ndcX * tanHalf * aspect, ndcY * tanHalf, -1)
        let direction = normalize(cameraEntity.orientation.act(dirCamera))
        let origin = cameraEntity.position(relativeTo: nil)

        // Closest hit wins (query types here are .all/.any, so sort by distance).
        let hits = arView.scene.raycast(origin: origin,
                                        direction: direction,
                                        length: 30,
                                        query: .all)
        guard let hit = hits.min(by: { $0.distance < $1.distance }) else { return }
        let entity = hit.entity
        // Walk up to the named envelope.
        var cursor: Entity? = entity
        while let current = cursor {
            if current.name.hasPrefix("mail:") {
                onTapMail?(String(current.name.dropFirst(5)))
                return
            }
            cursor = current.parent
        }
    }
}

// MARK: - SwiftUI wrapper

struct OfficeRealityView: UIViewRepresentable {
    let world: WorldState
    let onTapMail: (String) -> Void
    var artProvider: any WorldArtProviding = WorldArt.provider

    func makeCoordinator() -> OfficeController {
        OfficeController(frame: .zero, artProvider: artProvider)
    }

    func makeUIView(context: Context) -> ARView {
        context.coordinator.onTapMail = onTapMail
        context.coordinator.applyWorld(world)
        return context.coordinator.arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.onTapMail = onTapMail
        context.coordinator.applyWorld(world)
    }
}
