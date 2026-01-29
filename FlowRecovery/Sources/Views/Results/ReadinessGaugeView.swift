//
//  Copyright © 2024-2026 Chris Sharp. All rights reserved.
//

import SwiftUI

/// Circular gauge displaying readiness score
struct ReadinessGaugeView: View {
    let score: Double
    let showLabel: Bool

    init(score: Double, showLabel: Bool = true) {
        self.score = score
        self.showLabel = showLabel
    }

    private var scoreColor: Color {
        AppTheme.readinessColor(score)
    }

    private var interpretation: String {
        if score >= 8 { return "Excellent" }
        if score >= 6 { return "Good" }
        if score >= 4 { return "Fair" }
        return "Low"
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Background arc
                Circle()
                    .stroke(AppTheme.sectionTint, lineWidth: 12)
                    .frame(width: 100, height: 100)

                // Progress arc
                Circle()
                    .trim(from: 0, to: min(score / 10.0, 1.0))
                    .stroke(
                        scoreColor,
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .frame(width: 100, height: 100)
                    .rotationEffect(.degrees(-90))

                // Score text
                VStack(spacing: 2) {
                    Text(String(format: "%.1f", score))
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .foregroundColor(AppTheme.textPrimary)
                    Text("/10")
                        .font(.caption)
                        .foregroundColor(AppTheme.textTertiary)
                }
            }

            if showLabel {
                Text(interpretation)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(scoreColor)
            }
        }
    }
}

/// Horizontal bar gauge for readiness
struct ReadinessBarView: View {
    let score: Double
    let maxScore: Double

    init(score: Double, maxScore: Double = 10.0) {
        self.score = score
        self.maxScore = maxScore
    }

    private var scoreColor: Color {
        let normalized = score / maxScore * 10
        return AppTheme.readinessColor(normalized)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppTheme.sectionTint)
                    .frame(height: 8)

                // Progress
                RoundedRectangle(cornerRadius: 4)
                    .fill(scoreColor)
                    .frame(width: geometry.size.width * min(score / maxScore, 1.0), height: 8)
            }
        }
        .frame(height: 8)
    }
}

#Preview {
    VStack(spacing: 32) {
        ReadinessGaugeView(score: 8.5)
        ReadinessGaugeView(score: 6.2)
        ReadinessGaugeView(score: 4.1)
        ReadinessGaugeView(score: 2.5)

        HStack {
            Text("Readiness")
            Spacer()
            Text("7.5")
        }
        ReadinessBarView(score: 7.5)
    }
    .padding()
}
