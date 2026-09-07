//  JoystickView.swift
//  OfficeAdminGame
//
//  A soft virtual thumbstick for walking around the office. Reports a
//  normalized vector: y > 0 = forward (away from the camera).

import SwiftUI

struct JoystickView: View {
    let onChange: (SIMD2<Float>) -> Void

    @State private var isDragging = false
    @State private var thumbOffset: CGSize = .zero
    private let baseRadius: CGFloat = 62
    private let thumbRadius: CGFloat = 30

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.parchment.opacity(isDragging ? 0.95 : 0.7))
                .frame(width: baseRadius * 2, height: baseRadius * 2)
                .overlay(Circle().strokeBorder(Theme.ink.opacity(0.15), lineWidth: 2))
            Circle()
                .fill(Theme.clay)
                .frame(width: thumbRadius * 2, height: thumbRadius * 2)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                .offset(thumbOffset)
        }
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    isDragging = true
                    var vector = CGSize(width: value.translation.width, height: value.translation.height)
                    let magnitude = hypot(vector.width, vector.height)
                    let maxReach = baseRadius - thumbRadius * 0.4
                    if magnitude > maxReach {
                        vector = CGSize(width: vector.width / magnitude * maxReach,
                                        height: vector.height / magnitude * maxReach)
                    }
                    thumbOffset = vector
                    // Screen up (negative height) = forward.
                    onChange(SIMD2(Float(vector.width / maxReach), Float(-vector.height / maxReach)))
                }
                .onEnded { _ in
                    isDragging = false
                    thumbOffset = .zero
                    onChange(.zero)
                }
        )
    }
}
