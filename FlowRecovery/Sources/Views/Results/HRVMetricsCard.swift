//
//  Copyright © 2024-2026 Chris Sharp. All rights reserved.
//

import SwiftUI

/// Card displaying key HRV metrics
struct HRVMetricsCard: View {
    let timeDomain: TimeDomainMetrics
    let frequencyDomain: FrequencyDomainMetrics?
    let nonlinear: NonlinearMetrics?
    let baseline: BaselineTracker.BaselineDeviation?

    init(
        timeDomain: TimeDomainMetrics,
        frequencyDomain: FrequencyDomainMetrics? = nil,
        nonlinear: NonlinearMetrics? = nil,
        baseline: BaselineTracker.BaselineDeviation? = nil
    ) {
        self.timeDomain = timeDomain
        self.frequencyDomain = frequencyDomain
        self.nonlinear = nonlinear
        self.baseline = baseline
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Primary metrics
            HStack(spacing: 20) {
                primaryMetric(
                    value: timeDomain.rmssd.formatted1,
                    label: "RMSSD",
                    unit: "ms",
                    color: AppTheme.rmssdColor,
                    deviation: baseline?.rmssdDeviation
                )

                Divider()
                    .frame(height: 50)

                primaryMetric(
                    value: timeDomain.meanHR.formatted0,
                    label: "Heart Rate",
                    unit: "bpm",
                    color: AppTheme.heartRateColor
                )
            }
            .frame(maxWidth: .infinity)

            Divider()

            // Secondary metrics grid
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                secondaryMetric(
                    label: "SDNN",
                    value: timeDomain.sdnn.formatted1,
                    unit: "ms"
                )

                secondaryMetric(
                    label: "pNN50",
                    value: timeDomain.pnn50.formatted1,
                    unit: "%"
                )

                if let lf = frequencyDomain?.lf, let hf = frequencyDomain?.hf {
                    secondaryMetric(
                        label: "LF/HF",
                        value: (hf > 0 ? (lf / hf) : 0).formatted2,
                        unit: ""
                    )
                } else {
                    secondaryMetric(
                        label: "HR Range",
                        value: "\(Int(timeDomain.minHR))-\(Int(timeDomain.maxHR))",
                        unit: "bpm"
                    )
                }
            }

            // DFA Alpha if available
            if let alpha1 = nonlinear?.dfaAlpha1 {
                Divider()

                HStack {
                    Text("DFA α1")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)
                    Spacer()
                    Text(alpha1.formatted2)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(dfaColor(alpha1))

                    Text(dfaInterpretation(alpha1))
                        .font(.caption)
                        .foregroundColor(AppTheme.textTertiary)
                }
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
    }

    private func primaryMetric(
        value: String,
        label: String,
        unit: String,
        color: Color,
        deviation: Double? = nil
    ) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .foregroundColor(color)
                Text(unit)
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }
            Text(label)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)

            if let deviation = deviation {
                deviationBadge(deviation)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func secondaryMetric(label: String, value: String, unit: String) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundColor(AppTheme.textPrimary)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption2)
                        .foregroundColor(AppTheme.textTertiary)
                }
            }
            Text(label)
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    private func deviationBadge(_ deviation: Double) -> some View {
        let isPositive = deviation > 0
        let color: Color = abs(deviation) > 20
            ? (isPositive ? AppTheme.success : AppTheme.warning)
            : AppTheme.textTertiary

        return HStack(spacing: 2) {
            Image(systemName: isPositive ? "arrow.up" : "arrow.down")
                .font(.caption2)
            Text("\(abs(Int(deviation)))%")
                .font(.caption2)
        }
        .foregroundColor(color)
    }

    private func dfaColor(_ alpha: Double) -> Color {
        let range = HRVConstants.DFA.organizedRecoveryAlpha1Range
        if range.contains(alpha) { return AppTheme.success }
        if alpha < range.lowerBound { return AppTheme.warning }
        return AppTheme.mist
    }

    private func dfaInterpretation(_ alpha: Double) -> String {
        let range = HRVConstants.DFA.organizedRecoveryAlpha1Range
        if range.contains(alpha) { return "Organized" }
        if alpha < range.lowerBound { return "Random" }
        return "Correlated"
    }
}

#Preview {
    HRVMetricsCard(
        timeDomain: TimeDomainMetrics(
            meanRR: 950,
            sdnn: 65,
            rmssd: 45,
            pnn50: 28,
            sdsd: 42,
            meanHR: 63,
            sdHR: 4.5,
            minHR: 52,
            maxHR: 78,
            triangularIndex: 12.5
        ),
        frequencyDomain: FrequencyDomainMetrics(
            vlf: 1200,
            lf: 850,
            hf: 720,
            lfHfRatio: 1.18,
            totalPower: 2770
        ),
        nonlinear: NonlinearMetrics(
            sd1: 32,
            sd2: 68,
            sd1Sd2Ratio: 0.47,
            sampleEntropy: 1.45,
            approxEntropy: 1.12,
            dfaAlpha1: 0.92,
            dfaAlpha2: 0.85,
            dfaAlpha1R2: 0.97
        )
    )
    .padding()
}
