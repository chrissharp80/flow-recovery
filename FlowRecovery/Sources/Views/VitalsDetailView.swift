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

/// Detailed vitals view showing respiratory rate, SpO2, temperature, and resting HR
struct VitalsDetailView: View {
    let vitals: HealthKitManager.RecoveryVitals?
    let temperatureUnit: TemperatureUnit

    @State private var expandedCard: String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Status Banner
                statusBanner

                // Vitals Score
                vitalsScoreCard

                // Individual Vitals - Tappable for more info
                heartRateCard
                respiratoryCard
                oxygenCard
                temperatureCard

                // What These Mean
                explanationCard
            }
            .padding()
        }
        .background(AppTheme.background)
        .navigationTitle("Recovery Vitals")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Status Banner

    private var statusBanner: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 50, height: 50)
                Image(systemName: statusIcon)
                    .font(.title2)
                    .foregroundColor(statusColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(statusLabel)
                    .font(.headline)
                    .foregroundColor(statusColor)
                Text(statusMessage)
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textSecondary)
            }

            Spacer()
        }
        .padding()
        .background(statusColor.opacity(0.1))
        .cornerRadius(16)
    }

    private var statusIcon: String {
        guard let v = vitals else { return "questionmark.circle" }
        switch v.status {
        case .normal: return "checkmark.circle.fill"
        case .elevated: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.circle.fill"
        }
    }

    private var statusColor: Color {
        guard let v = vitals else { return AppTheme.textTertiary }
        switch v.status {
        case .normal: return AppTheme.sage
        case .elevated: return AppTheme.terracotta
        case .warning: return AppTheme.dustyRose
        }
    }

    private var statusLabel: String {
        guard let v = vitals else { return "No Data" }
        switch v.status {
        case .normal: return "All Vitals Normal"
        case .elevated: return "Some Vitals Elevated"
        case .warning: return "Attention Needed"
        }
    }

    private var statusMessage: String {
        guard let v = vitals else { return "Vitals data not available from last night" }
        switch v.status {
        case .normal: return "Your recovery vitals look healthy"
        case .elevated: return "Monitor these metrics closely"
        case .warning: return "Consider rest and consult a doctor if symptoms persist"
        }
    }

    // MARK: - Vitals Score Card

    private var vitalsScoreCard: some View {
        let score = calculateVitalsScore()

        return VStack(spacing: 16) {
            Text("VITALS SCORE")
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.textTertiary)
                .tracking(1)

            HStack(spacing: 24) {
                // Score Circle
                ZStack {
                    Circle()
                        .stroke(vitalsScoreColor(score).opacity(0.2), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: CGFloat(score) / 100)
                        .stroke(vitalsScoreColor(score), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(score)")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(vitalsScoreColor(score))
                }
                .frame(width: 100, height: 100)

                // Quick Stats
                VStack(alignment: .leading, spacing: 8) {
                    QuickVitalStat(
                        icon: "heart.fill",
                        label: "RHR",
                        value: vitals?.restingHeartRate.map { "\(Int($0))" } ?? "--",
                        unit: "bpm"
                    )
                    QuickVitalStat(
                        icon: "lungs.fill",
                        label: "Resp",
                        value: vitals?.respiratoryRate.map { String(format: "%.1f", $0) } ?? "--",
                        unit: "/min"
                    )
                    QuickVitalStat(
                        icon: "drop.fill",
                        label: "SpO2",
                        value: vitals?.oxygenSaturation.map { "\(Int($0))" } ?? "--",
                        unit: "%"
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    private func calculateVitalsScore() -> Int {
        guard let v = vitals else { return 0 }

        var score = 100

        // Deductions for elevated vitals
        if v.isRespiratoryElevated {
            score -= 15
        }
        if v.isSpO2Concerning {
            score -= 25
        }
        if v.isTemperatureElevated {
            score -= 15
        }

        // SpO2 under 95 is more concerning
        if let spo2 = v.oxygenSaturation, spo2 < 93 {
            score -= 15
        }

        return max(0, score)
    }

    private func vitalsScoreColor(_ score: Int) -> Color {
        if score >= 85 { return AppTheme.sage }
        if score >= 70 { return AppTheme.softGold }
        if score >= 50 { return AppTheme.terracotta }
        return AppTheme.dustyRose
    }

    // MARK: - Heart Rate Card

    private var heartRateCard: some View {
        ExpandableVitalCard(
            icon: "heart.fill",
            title: "Resting Heart Rate",
            value: vitals?.restingHeartRate.map { String(format: "%.0f", $0) },
            unit: "bpm",
            status: .normal,
            isExpanded: expandedCard == "hr",
            onTap: { expandedCard = expandedCard == "hr" ? nil : "hr" },
            expandedContent: {
                VStack(alignment: .leading, spacing: 12) {
                    DetailRow(label: "Normal Range", value: "40-100 bpm (varies by fitness)")
                    DetailRow(label: "Athletes", value: "Often 40-60 bpm")

                    Divider()

                    Text("Your lowest heart rate during sleep. Lower is generally better for athletes. Elevated RHR can indicate:")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)

                    VStack(alignment: .leading, spacing: 4) {
                        BulletText("Incomplete recovery from training")
                        BulletText("Dehydration")
                        BulletText("Elevated stress or illness")
                        BulletText("Alcohol or late meals")
                    }
                }
            }
        )
    }

    // MARK: - Respiratory Card

    private var respiratoryCard: some View {
        let deviationText: String? = {
            guard let rate = vitals?.respiratoryRate,
                  let baseline = vitals?.respiratoryRateBaseline else { return nil }
            let deviation = rate - baseline
            return String(format: "%+.1f from baseline", deviation)
        }()

        return ExpandableVitalCard(
            icon: "lungs.fill",
            title: "Respiratory Rate",
            value: vitals?.respiratoryRate.map { String(format: "%.1f", $0) },
            unit: "breaths/min",
            status: vitals?.isRespiratoryElevated == true ? .elevated : .normal,
            subtitle: deviationText,
            isExpanded: expandedCard == "resp",
            onTap: { expandedCard = expandedCard == "resp" ? nil : "resp" },
            expandedContent: {
                VStack(alignment: .leading, spacing: 12) {
                    DetailRow(label: "Normal Range", value: "12-20 breaths/min")
                    if let baseline = vitals?.respiratoryRateBaseline {
                        DetailRow(label: "Your Baseline (7-day)", value: String(format: "%.1f breaths/min", baseline))
                    }

                    Divider()

                    Text("Elevated respiratory rate during sleep can indicate:")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)

                    VStack(alignment: .leading, spacing: 4) {
                        BulletText("Stress or anxiety")
                        BulletText("Early signs of illness")
                        BulletText("Incomplete recovery")
                        BulletText("Sleep apnea or breathing issues")
                    }
                }
            }
        )
    }

    // MARK: - Oxygen Card

    private var oxygenCard: some View {
        let minText: String? = vitals?.oxygenSaturationMin.map { "Low: \(Int($0))%" }

        return ExpandableVitalCard(
            icon: "drop.fill",
            title: "Blood Oxygen (SpO2)",
            value: vitals?.oxygenSaturation.map { String(format: "%.0f", $0) },
            unit: "%",
            status: vitals?.isSpO2Concerning == true ? .warning : .normal,
            subtitle: minText,
            isExpanded: expandedCard == "spo2",
            onTap: { expandedCard = expandedCard == "spo2" ? nil : "spo2" },
            expandedContent: {
                VStack(alignment: .leading, spacing: 12) {
                    DetailRow(label: "Normal Range", value: "95-100%")
                    DetailRow(label: "Concerning", value: "Below 95%")
                    if let minSpo2 = vitals?.oxygenSaturationMin {
                        DetailRow(label: "Your Lowest Last Night", value: "\(Int(minSpo2))%")
                    }

                    Divider()

                    Text("Blood oxygen below 95% during sleep may indicate:")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)

                    VStack(alignment: .leading, spacing: 4) {
                        BulletText("Sleep apnea")
                        BulletText("Respiratory illness")
                        BulletText("High altitude effects")
                        BulletText("Poor sleep position")
                    }

                    if vitals?.isSpO2Concerning == true {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(AppTheme.dustyRose)
                            Text("Consult a doctor if consistently low")
                                .font(.caption.weight(.medium))
                                .foregroundColor(AppTheme.dustyRose)
                        }
                        .padding(.top, 4)
                    }
                }
            }
        )
    }

    // MARK: - Temperature Card

    private var temperatureCard: some View {
        let tempValue: String? = vitals?.wristTemperature.map {
            let converted = temperatureUnit.convert($0)
            return String(format: "%+.1f", converted)
        }

        return ExpandableVitalCard(
            icon: "thermometer.medium",
            title: "Wrist Temperature",
            value: tempValue,
            unit: temperatureUnit.symbol,
            status: vitals?.isTemperatureElevated == true ? .elevated : .normal,
            subtitle: "deviation from baseline",
            isExpanded: expandedCard == "temp",
            onTap: { expandedCard = expandedCard == "temp" ? nil : "temp" },
            expandedContent: {
                VStack(alignment: .leading, spacing: 12) {
                    DetailRow(label: "Normal Variation", value: temperatureUnit == .celsius ? "±0.5°C" : "±0.9°F")
                    DetailRow(label: "Your Baseline", value: "0.0\(temperatureUnit.symbol) (personalized)")

                    Divider()

                    Text("Temperature deviation from your baseline can indicate:")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)

                    VStack(alignment: .leading, spacing: 4) {
                        BulletText("Early signs of illness (elevated)")
                        BulletText("Ovulation phase for women")
                        BulletText("Environmental factors")
                        BulletText("Alcohol consumption")
                    }

                    Text("Note: Wrist temperature is available on Apple Watch Series 8 and later.")
                        .font(.caption2)
                        .foregroundColor(AppTheme.textTertiary)
                        .padding(.top, 4)
                }
            }
        )
    }

    // MARK: - Explanation Card

    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(AppTheme.primary)
                Text("ABOUT RECOVERY VITALS")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.textTertiary)
                    .tracking(1)
            }

            Text("These vitals are collected from your Apple Watch during sleep. Tap each metric for details.")
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)

            VStack(alignment: .leading, spacing: 8) {
                InsightRow(icon: "chart.line.uptrend.xyaxis", text: "Track trends over multiple nights for meaningful patterns")
                InsightRow(icon: "moon.fill", text: "Morning readings after good sleep are most reliable")
                InsightRow(icon: "figure.walk", text: "Recent training load affects recovery vitals")
                InsightRow(icon: "wineglass", text: "Alcohol and late meals can elevate vitals")
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }
}

// MARK: - Supporting Views

private struct QuickVitalStat: View {
    let icon: String
    let label: String
    let value: String
    let unit: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(AppTheme.textTertiary)
                .frame(width: 16)
            Text(label)
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
            Text(unit)
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
    }
}

private struct ExpandableVitalCard<ExpandedContent: View>: View {
    let icon: String
    let title: String
    let value: String?
    let unit: String
    let status: VitalStatus
    var subtitle: String? = nil
    let isExpanded: Bool
    let onTap: () -> Void
    @ViewBuilder let expandedContent: () -> ExpandedContent

    enum VitalStatus {
        case normal, elevated, warning

        var color: Color {
            switch self {
            case .normal: return AppTheme.sage
            case .elevated: return AppTheme.terracotta
            case .warning: return AppTheme.dustyRose
            }
        }

        var icon: String {
            switch self {
            case .normal: return "checkmark.circle.fill"
            case .elevated: return "exclamationmark.triangle.fill"
            case .warning: return "exclamationmark.circle.fill"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main card content
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: icon)
                            .font(.title2)
                            .foregroundColor(status.color)
                        Text(title)
                            .font(.headline)
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: status.icon)
                                .foregroundColor(status.color)
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption)
                                .foregroundColor(AppTheme.textTertiary)
                        }
                    }

                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(value ?? "--")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundColor(value != nil ? status.color : AppTheme.textTertiary)
                        Text(unit)
                            .font(.subheadline)
                            .foregroundColor(AppTheme.textTertiary)

                        Spacer()

                        if let subtitle = subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundColor(AppTheme.textTertiary)
                        }
                    }
                }
                .padding()
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded {
                Divider()
                    .padding(.horizontal)

                expandedContent()
                    .padding()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
        }
    }
}

private struct BulletText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(AppTheme.primary)
                .frame(width: 5, height: 5)
                .padding(.top, 6)
            Text(text)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }
    }
}

private struct InsightRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(AppTheme.primary)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
        }
    }
}

#Preview {
    NavigationStack {
        VitalsDetailView(
            vitals: nil,
            temperatureUnit: .fahrenheit
        )
    }
}
