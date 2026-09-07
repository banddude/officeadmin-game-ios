//  AppTheme.swift
//  OfficeAdminGame
//
//  One warm, readable palette for the whole world — paper cream, sage, clay,
//  soft sky — in the direction of Animal Crossing / Dorfromantik comfort.
//  Nothing here may drift toward admin-panel gray or dashboard blue.

import SwiftUI

enum Theme {
    // Surfaces
    static let paper = Color(red: 0.98, green: 0.95, blue: 0.88)       // warm cream
    static let parchment = Color(red: 0.93, green: 0.88, blue: 0.78)   // card fronts
    static let ink = Color(red: 0.24, green: 0.20, blue: 0.16)         // soft black-brown

    // Accents
    static let sage = Color(red: 0.47, green: 0.63, blue: 0.47)
    static let clay = Color(red: 0.80, green: 0.48, blue: 0.33)
    static let honey = Color(red: 0.93, green: 0.72, blue: 0.33)
    static let sky = Color(red: 0.62, green: 0.80, blue: 0.90)
    static let brick = Color(red: 0.64, green: 0.28, blue: 0.22)

    // Site phases (marker color by project status)
    static func phaseColor(_ phase: WorldSite.Phase) -> Color {
        switch phase {
        case .lead: return sky
        case .estimating: return honey
        case .bidSent: return Color(red: 0.72, green: 0.55, blue: 0.76)
        case .onHold: return Color(white: 0.72)
        case .active: return sage
        }
    }

    // Type
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// The one card shape used for every in-world surface.
struct CardBackground: ViewModifier {
    var color: Color = Theme.parchment

    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(color)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            )
    }
}

extension View {
    func worldCard(_ color: Color = Theme.parchment) -> some View {
        modifier(CardBackground(color: color))
    }
}
