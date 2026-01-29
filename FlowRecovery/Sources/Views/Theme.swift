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

/// App theme with a peaceful, zen-inspired aesthetic
/// Muted, natural tones evoking calm and balance - perfect for HRV/wellness
struct AppTheme {

    // MARK: - Core Palette (Zen-inspired)

    /// Deep indigo - grounding, peaceful
    static let primary = Color(red: 0.35, green: 0.40, blue: 0.55)

    /// Darker slate for depth
    static let primaryDark = Color(red: 0.22, green: 0.26, blue: 0.38)

    /// Soft periwinkle
    static let primaryLight = Color(red: 0.58, green: 0.62, blue: 0.75)

    // MARK: - Accent Colors (Natural, Organic)

    /// Sage green - growth, health, calm
    static let sage = Color(red: 0.55, green: 0.68, blue: 0.58)

    /// Soft terracotta - warmth without harshness
    static let terracotta = Color(red: 0.78, green: 0.58, blue: 0.52)

    /// Dusty rose - gentle warmth
    static let dustyRose = Color(red: 0.75, green: 0.58, blue: 0.62)

    /// Warm sand/cream
    static let sand = Color(red: 0.92, green: 0.88, blue: 0.82)

    /// Soft gold - subtle highlight
    static let softGold = Color(red: 0.85, green: 0.78, blue: 0.55)

    /// Ocean mist - calm blue-gray
    static let mist = Color(red: 0.70, green: 0.78, blue: 0.82)

    // MARK: - Secondary (Legacy compatibility)

    static let secondary = dustyRose
    static let secondaryLight = Color(red: 0.88, green: 0.78, blue: 0.82)
    static let secondaryDark = Color(red: 0.62, green: 0.45, blue: 0.50)
    static let accent = terracotta

    // MARK: - Semantic Colors

    /// Success - muted sage green
    static let success = sage

    /// Warning - soft gold
    static let warning = softGold

    /// Alert - dusty coral (not harsh red)
    static let alert = Color(red: 0.82, green: 0.52, blue: 0.48)

    // MARK: - Backgrounds

    /// Main background - warm off-white
    static let background = Color(red: 0.97, green: 0.96, blue: 0.94)

    /// Card background - soft warm white
    static let cardBackground = Color(red: 0.99, green: 0.98, blue: 0.96)

    /// Elevated card - pure white with warmth
    static let cardElevated = Color.white

    /// Subtle tint for sections
    static let sectionTint = Color(red: 0.95, green: 0.94, blue: 0.92)

    // MARK: - Text Colors

    /// Primary text - soft charcoal (not pure black)
    static let textPrimary = Color(red: 0.18, green: 0.20, blue: 0.25)

    /// Secondary text - warm gray
    static let textSecondary = Color(red: 0.45, green: 0.48, blue: 0.52)

    /// Tertiary text - light gray
    static let textTertiary = Color(red: 0.62, green: 0.65, blue: 0.68)

    // MARK: - Gradients

    /// Subtle dawn gradient
    static let dawnGradient = LinearGradient(
        colors: [
            Color(red: 0.95, green: 0.92, blue: 0.90),
            Color(red: 0.92, green: 0.90, blue: 0.95)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Calming gradient for hero elements
    static let calmGradient = LinearGradient(
        colors: [primaryLight.opacity(0.6), primary.opacity(0.8)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Primary gradient
    static let primaryGradient = LinearGradient(
        colors: [primaryLight, primary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Soft nature gradient
    static let natureGradient = LinearGradient(
        colors: [sage.opacity(0.6), mist.opacity(0.6)],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Hero card gradient - subtle depth
    static let heroGradient = LinearGradient(
        colors: [primary.opacity(0.85), primaryDark.opacity(0.95)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Warm accent gradient
    static let warmGradient = LinearGradient(
        colors: [terracotta.opacity(0.7), dustyRose.opacity(0.7)],
        startPoint: .leading,
        endPoint: .trailing
    )

    // MARK: - Metric Colors (Harmonious)

    /// RMSSD - primary indigo
    static let rmssdColor = primary

    /// SDNN - dusty purple
    static let sdnnColor = Color(red: 0.55, green: 0.50, blue: 0.65)

    /// Heart rate - terracotta
    static let heartRateColor = terracotta

    /// HF power - sage
    static let hfColor = sage

    /// LF power - muted indigo
    static let lfColor = primaryLight

    /// VLF power - warm gray
    static let vlfColor = Color(red: 0.65, green: 0.62, blue: 0.60)

    // MARK: - Readiness Colors

    static func readinessColor(_ score: Double) -> Color {
        if score >= 8 { return sage }
        if score >= 6 { return mist }
        if score >= 4 { return softGold }
        return terracotta
    }

    /// Readiness gradient for gauges
    static let readinessGradient = Gradient(colors: [
        terracotta, softGold, mist, sage
    ])

    // MARK: - Chart Colors (Cohesive palette)

    static let poincarePointColor = primary.opacity(0.5)
    static let poincareEllipseColor = primary.opacity(0.12)
    static let poincareEllipseStroke = primary.opacity(0.4)

    static let tachogramLine = primary
    static let tachogramFill = primary.opacity(0.15)

    // MARK: - Tag Colors (Soft, distinguishable)

    static func tagColor(for name: String) -> Color {
        switch name.lowercased() {
        case "morning": return softGold
        case "post-exercise", "exercise": return terracotta
        case "recovery": return sage
        case "evening": return dustyRose
        case "night", "sleep", "pre-sleep": return primaryDark
        case "stressed": return alert
        case "relaxed": return mist
        default: return primaryLight
        }
    }

    // MARK: - Layout Constants

    static let cornerRadius: CGFloat = 16
    static let smallCornerRadius: CGFloat = 10
    static let padding: CGFloat = 16
    static let smallPadding: CGFloat = 10

    /// Subtle shadow
    static let cardShadow = Color.black.opacity(0.04)
    static let cardShadowRadius: CGFloat = 12
}

// MARK: - View Extensions

extension View {
    /// Apply zen card styling
    func zenCard() -> some View {
        self
            .padding(AppTheme.padding)
            .background(AppTheme.cardBackground)
            .cornerRadius(AppTheme.cornerRadius)
            .shadow(color: AppTheme.cardShadow, radius: AppTheme.cardShadowRadius, x: 0, y: 2)
    }

    /// Apply elevated card styling
    func elevatedCard() -> some View {
        self
            .padding(AppTheme.padding)
            .background(AppTheme.cardElevated)
            .cornerRadius(AppTheme.cornerRadius)
            .shadow(color: AppTheme.cardShadow, radius: AppTheme.cardShadowRadius + 4, x: 0, y: 4)
    }

    /// Hero card with gradient
    func heroCard() -> some View {
        self
            .padding(AppTheme.padding)
            .background(AppTheme.heroGradient)
            .cornerRadius(AppTheme.cornerRadius)
            .shadow(color: AppTheme.primary.opacity(0.15), radius: 12, x: 0, y: 4)
    }

    /// Gradient foreground style
    func gradientForeground() -> some View {
        self.foregroundStyle(AppTheme.primaryGradient)
    }

    /// Zen background for screens
    func zenBackground() -> some View {
        self.background(AppTheme.background.ignoresSafeArea())
    }

    /// Soft section header style
    func sectionHeader() -> some View {
        self
            .font(.subheadline.weight(.semibold))
            .foregroundColor(AppTheme.textSecondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }
}

// MARK: - Button Styles

struct ZenButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius)
                    .fill(color)
                    .shadow(color: color.opacity(0.3), radius: 8, x: 0, y: 4)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct ZenSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundColor(AppTheme.primary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius)
                    .stroke(AppTheme.primary.opacity(0.3), lineWidth: 1.5)
                    .background(AppTheme.cardBackground.cornerRadius(AppTheme.smallCornerRadius))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ZenButtonStyle {
    static func zen(_ color: Color = AppTheme.primary) -> ZenButtonStyle {
        ZenButtonStyle(color: color)
    }
}

extension ButtonStyle where Self == ZenSecondaryButtonStyle {
    static var zenSecondary: ZenSecondaryButtonStyle {
        ZenSecondaryButtonStyle()
    }
}

// MARK: - Metric Display Component

struct MetricDisplay: View {
    let value: String
    let label: String
    let unit: String?
    let color: Color

    init(_ value: String, label: String, unit: String? = nil, color: Color = AppTheme.primary) {
        self.value = value
        self.label = label
        self.unit = unit
        self.color = color
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .foregroundColor(color)
                if let unit = unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundColor(AppTheme.textTertiary)
                }
            }
            Text(label)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }
    }
}

// Note: Color hex extension is in HRVSession.swift
