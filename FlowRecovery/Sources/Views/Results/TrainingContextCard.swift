//
//  Copyright © 2024-2026 Chris Sharp. All rights reserved.
//

import SwiftUI

/// Card displaying training load context (ATL/CTL/TSB)
struct TrainingContextCard: View {
    let context: TrainingContext

    private var acrColor: Color {
        guard let acr = context.acuteChronicRatio else { return AppTheme.textSecondary }
        if acr > TrainingConstants.ACR.overreaching { return AppTheme.alert }
        if acr > TrainingConstants.ACR.building { return AppTheme.warning }
        if acr < TrainingConstants.ACR.detraining { return AppTheme.warning }
        return AppTheme.success
    }

    private var tsbColor: Color {
        if context.tsb > TrainingConstants.TSB.fresh { return AppTheme.success }
        if context.tsb > TrainingConstants.TSB.neutral { return AppTheme.mist }
        if context.tsb > TrainingConstants.TSB.tired { return AppTheme.warning }
        return AppTheme.alert
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Form/Freshness
            HStack {
                Image(systemName: "figure.run")
                    .foregroundColor(AppTheme.primary)
                Text("Form")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(context.formDescription)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(tsbColor)
            }

            Divider()

            // Metrics Grid
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                metricCell(
                    label: "Fitness",
                    value: context.ctl.formatted0,
                    caption: "CTL"
                )
                metricCell(
                    label: "Fatigue",
                    value: context.atl.formatted0,
                    caption: "ATL"
                )
                metricCell(
                    label: "Form",
                    value: context.tsb.formatted0,
                    caption: "TSB",
                    color: tsbColor
                )
            }

            // ACR if available
            if let acr = context.acuteChronicRatio {
                Divider()

                HStack {
                    Text("Load Ratio")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)
                    Spacer()
                    Text(acr.formatted2)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(acrColor)
                    Text("ACR")
                        .font(.caption)
                        .foregroundColor(AppTheme.textTertiary)
                }

                Text(context.riskLevel)
                    .font(.caption)
                    .foregroundColor(acrColor)
            }

            // Yesterday's training
            if context.yesterdayTrimp > 0 {
                Divider()

                HStack {
                    Text("Yesterday")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)
                    Spacer()
                    Text("\(Int(context.yesterdayTrimp)) TRIMP")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(AppTheme.textPrimary)
                }
            }

            // Days since hard workout
            if let days = context.daysSinceHardWorkout {
                HStack {
                    Text("Rest days")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)
                    Spacer()
                    Text(days == 0 ? "Hard workout yesterday" : "\(days) day\(days == 1 ? "" : "s")")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(days <= 1 ? AppTheme.warning : AppTheme.textPrimary)
                }
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
    }

    private func metricCell(label: String, value: String, caption: String, color: Color = AppTheme.textPrimary) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundColor(color)
            Text(caption)
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
        }
    }
}

#Preview {
    TrainingContextCard(context: TrainingContext(
        atl: 45,
        ctl: 52,
        tsb: 7,
        yesterdayTrimp: 85,
        vo2Max: 48.5,
        daysSinceHardWorkout: 2,
        recentWorkouts: nil
    ))
    .padding()
}
