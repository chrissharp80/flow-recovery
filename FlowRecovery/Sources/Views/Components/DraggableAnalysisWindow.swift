//
//  Copyright © 2024-2026 Chris Sharp. All rights reserved.
//
//  This source code is provided for reference and verification purposes only.
//  Unauthorized copying, modification, distribution, or use of this code,
//  via any medium, is strictly prohibited without prior written permission.
//
//  For licensing inquiries, contact the copyright holder.
//

import SwiftUI

/// Draggable overlay for the analysis window that allows users to reposition the 5-minute window
/// and recalculate metrics for custom time ranges
struct DraggableAnalysisWindow: View {
    let windowStartX: CGFloat
    let windowEndX: CGFloat
    let chartHeight: CGFloat
    let totalBeats: Int
    let onAnalyzeCustomWindow: (Int, Int) -> Void
    let onResetToAutoWindow: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    private var effectiveStartX: CGFloat {
        windowStartX + dragOffset
    }

    private var effectiveEndX: CGFloat {
        windowEndX + dragOffset
    }

    private var windowWidth: CGFloat {
        windowEndX - windowStartX
    }

    var body: some View {
        ZStack {
            // Draggable handle area
            dragHandles

            // Action buttons (checkmark and X)
            actionButtons
        }
        .gesture(dragGesture)
    }

    private var dragHandles: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: windowWidth + 40, height: chartHeight)
            .position(x: (effectiveStartX + effectiveEndX) / 2, y: chartHeight / 2)
            .overlay(
                // Visual drag handles on left and right edges
                HStack(spacing: 0) {
                    dragHandle
                    Spacer()
                    dragHandle
                }
                .frame(width: windowWidth)
                .position(x: (effectiveStartX + effectiveEndX) / 2, y: chartHeight / 2)
            )
    }

    private var dragHandle: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(AppTheme.primary.opacity(0.8))
            .frame(width: 4, height: 40)
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            // Checkmark - confirm and analyze
            Button {
                let startIndex = indexFromX(effectiveStartX)
                let endIndex = indexFromX(effectiveEndX)
                onAnalyzeCustomWindow(startIndex, endIndex)
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.green)
                    .background(Circle().fill(Color.white))
            }
            .buttonStyle(.plain)

            // X - cancel and reset
            Button {
                onResetToAutoWindow()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.red)
                    .background(Circle().fill(Color.white))
            }
            .buttonStyle(.plain)
        }
        .position(x: (effectiveStartX + effectiveEndX) / 2, y: 30)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                isDragging = true
                // Constrain drag to keep window within chart bounds
                let proposedOffset = value.translation.width
                let maxLeft = -windowStartX
                let maxRight = UIScreen.main.bounds.width - windowEndX
                dragOffset = max(maxLeft, min(maxRight, proposedOffset))
            }
            .onEnded { _ in
                isDragging = false
            }
    }

    private func indexFromX(_ x: CGFloat) -> Int {
        // Convert x position to beat index
        let chartWidth = UIScreen.main.bounds.width
        let fraction = x / chartWidth
        return Int(fraction * CGFloat(totalBeats))
    }
}
