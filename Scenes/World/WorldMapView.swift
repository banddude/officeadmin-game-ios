//  WorldMapView.swift
//  OfficeAdminGame
//
//  The real world itself: MapKit geography with realistic terrain under a
//  stylized marker layer. MKMapView (not SwiftUI Map) because travel is a
//  camera flight — pitch, distance, animation — and the annotation layer
//  needs custom drawn views.

import MapKit
import SwiftUI

// MARK: - Annotation model

final class SiteAnnotation: NSObject, MKAnnotation {
    let site: WorldSite
    var coordinate: CLLocationCoordinate2D { site.coordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0) }
    init(site: WorldSite) { self.site = site }
}

// MARK: - Annotation view (the drawn low-poly site marker)

final class SiteAnnotationView: MKAnnotationView {
    static let reuseID = "SiteAnnotationView"

    override var annotation: MKAnnotation? { didSet { configure() } }

    func configure() {
        guard let annotation = annotation as? SiteAnnotation else { return }
        let site = annotation.site
        let crew = site.crewPresent.count + site.crewScheduled.count
        image = SiteMarkerArt.marker(
            phase: site.phase,
            name: site.name,
            crewCount: crew,
            urgent: site.waitingMailCount > 0)
        centerOffset = CGPoint(x: 0, y: -36)   // pin the base to the coordinate
        canShowCallout = false
        collisionMode = .circle
    }
}

// MARK: - The map

struct WorldMapView: UIViewRepresentable {
    let sites: [WorldSite]
    let selectedSiteID: String?
    let onSelectSite: (WorldSite) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.preferredConfiguration = MKStandardMapConfiguration(
            elevationStyle: .realistic, emphasisStyle: .muted)
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = false
        map.showsScale = false
        map.showsTraffic = false
        map.isPitchEnabled = true
        map.register(SiteAnnotationView.self, forAnnotationViewWithReuseIdentifier: SiteAnnotationView.reuseID)
        context.coordinator.map = map
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator

        // Reconcile annotations with current sites.
        let current = Dictionary(uniqueKeysWithValues: sites.compactMap { site -> (String, WorldSite)? in
            guard site.coordinate != nil else { return nil }
            return (site.id, site)
        })
        let existing = map.annotations.compactMap { $0 as? SiteAnnotation }
        let existingIDs = Set(existing.map(\.site.id))
        let toRemove = existing.filter { current[$0.site.id] == nil }
        let toAdd = current.values.filter { !existingIDs.contains($0.id) }
            .map(SiteAnnotation.init)
        if !toRemove.isEmpty { map.removeAnnotations(toRemove) }
        if !toAdd.isEmpty { map.addAnnotations(toAdd) }

        // Refresh marker art (crew/urgency change as the world refetches).
        for annotation in existing where current[annotation.site.id] != nil {
            (map.view(for: annotation) as? SiteAnnotationView)?.configure()
        }

        if coordinator.needsInitialCamera, let any = current.values.first {
            coordinator.needsInitialCamera = false
            fitCamera(over: Array(current.values), in: map, animated: false)
        }

        if let selectedSiteID,
           let site = current[selectedSiteID],
           coordinator.lastFlownSiteID != selectedSiteID {
            coordinator.lastFlownSiteID = selectedSiteID
            fly(to: site, in: map)
        }
        if selectedSiteID == nil { coordinator.lastFlownSiteID = nil }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectSite: onSelectSite)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let onSelectSite: (WorldSite) -> Void
        var needsInitialCamera = true
        var lastFlownSiteID: String?
        weak var map: MKMapView?

        init(onSelectSite: @escaping (WorldSite) -> Void) {
            self.onSelectSite = onSelectSite
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is SiteAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: SiteAnnotationView.reuseID, for: annotation)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let siteAnnotation = view.annotation as? SiteAnnotation else { return }
            mapView.deselectAnnotation(siteAnnotation, animated: false)
            onSelectSite(siteAnnotation.site)
        }
    }

    // MARK: Camera moves

    private func fitCamera(over sites: [WorldSite], in map: MKMapView, animated: Bool) {
        var rect = MKMapRect.null
        for site in sites {
            let point = MKMapPoint(site.coordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0))
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
        }
        guard !rect.isNull else {
            // No sites yet: a gentle overview while the world loads.
            map.camera = MKMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: 34.05, longitude: -118.25),
                                     fromDistance: 30_000, pitch: 45, heading: 0)
            return
        }
        map.setVisibleMapRect(rect.insetBy(dx: -rect.width * 0.25 - 2000, dy: -rect.height * 0.25 - 2000),
                              edgePadding: UIEdgeInsets(top: 120, left: 60, bottom: 220, right: 60),
                              animated: animated)
        // Lift the camera for a 3D read of the terrain once fitted.
        let center = map.centerCoordinate
        map.setCamera(MKMapCamera(lookingAtCenter: center,
                                  fromDistance: max(map.camera.altitude, 4_000),
                                  pitch: 55, heading: 0),
                      animated: false)
    }

    /// Travel: swoop down close over the site.
    private func fly(to site: WorldSite, in map: MKMapView) {
        guard let coordinate = site.coordinate else { return }
        let camera = MKMapCamera(lookingAtCenter: coordinate, fromDistance: 650, pitch: 68, heading: 0)
        map.setCamera(camera, animated: true)
    }
}
