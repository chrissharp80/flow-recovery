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

/// Selection chip button with optional tooltip
struct SelectionChip: View {
    let title: String
    let icon: String?
    let tooltip: String
    let isSelected: Bool
    let onTap: () -> Void

    @State private var showTooltip = false

    init(_ title: String, icon: String? = nil, tooltip: String, isSelected: Bool, onTap: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.tooltip = tooltip
        self.isSelected = isSelected
        self.onTap = onTap
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                }
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(chipBackground)
            .foregroundColor(chipForeground)
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(chipBorder, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0.5) {
            showTooltip = true
        }
        .alert(title, isPresented: $showTooltip) {
            Button("Got it") {}
        } message: {
            Text(tooltip)
        }
    }

    private var chipBackground: Color {
        isSelected ? AppTheme.primary.opacity(0.15) : Color(.systemBackground)
    }

    private var chipForeground: Color {
        isSelected ? AppTheme.primary : AppTheme.textSecondary
    }

    private var chipBorder: Color {
        isSelected ? AppTheme.primary : Color.gray.opacity(0.3)
    }
}
