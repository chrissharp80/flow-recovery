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

/// Pro-style Recovery Dashboard - all recovery metrics at a glance
struct RecoveryDashboardView: View {
    let sessions: [HRVSession]
    let onStartRecording: () -> Void
    let onViewReport: (HRVSession) -> Void

    @EnvironmentObject var collector: RRCollector
    @EnvironmentObject var settingsManager: SettingsManager

    @State private var recoveryVitals: HealthKitManager.RecoveryVitals?
    @State private var trainingMetrics: HealthKitManager.TrainingMetrics?
    @State private var sleepData: HealthKitManager.SleepData?
    @State private var latestSession: HRVSession?
    @State private var isLoading = true

    @StateObject private var healthKit = HealthKitManager()

    private var latestHRV: Double? {
        latestSession?.analysisResult?.timeDomain.rmssd
    }

    private var morningReading: HRVSession? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let noon = calendar.date(byAdding: .hour, value: 12, to: today)!

        return sessions.filter { session in
            guard session.state == .complete, let endDate = session.endDate else { return false }
            let endedTodayMorning = endDate >= today && endDate < noon
            let isOvernight = (session.duration ?? 0) > 7200
            return endedTodayMorning && isOvernight
        }.sorted { $0.startDate > $1.startDate }.first
            ?? sessions.first { $0.state == .complete }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Recovery Score - Hero Section
                recoveryScoreCard

                // Primary Metrics Row
                HStack(spacing: 12) {
                    NavigationLink {
                        HRVDetailView(
                            sessions: sessions,
                            currentHRV: latestHRV,
                            baselineRMSSD: settingsManager.settings.baselineRMSSD,
                            onViewReport: onViewReport
                        )
                    } label: {
                        hrvCard
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        SleepDetailView(
                            sleepData: sleepData,
                            typicalSleepHours: settingsManager.settings.typicalSleepHours
                        )
                    } label: {
                        sleepCard
                    }
                    .buttonStyle(.plain)
                }

                // Training Load
                if settingsManager.settings.enableTrainingLoadIntegration,
                   !settingsManager.settings.isOnTrainingBreak {
                    NavigationLink {
                        TrainingDetailView(
                            trainingMetrics: trainingMetrics,
                            trainingContext: latestSession?.analysisResult?.trainingContext
                        )
                    } label: {
                        trainingLoadCard
                    }
                    .buttonStyle(.plain)
                }

                // Vitals Grid
                NavigationLink {
                    VitalsDetailView(
                        vitals: recoveryVitals,
                        temperatureUnit: settingsManager.settings.temperatureUnit
                    )
                } label: {
                    vitalsSection
                }
                .buttonStyle(.plain)

                // Recovery Insights
                insightsSection

                // Action Button
                actionButton
            }
            .padding()
        }
        .background(AppTheme.background)
        .task {
            await loadData()
        }
        .refreshable {
            await loadData()
        }
    }

    // MARK: - Data Loading

    private func loadData() async {
        isLoading = true

        // Get the session first so we can fetch matching sleep data
        let session = morningReading ?? sessions.first { $0.state == .complete }

        async let vitals = healthKit.fetchRecoveryVitals()
        async let training = healthKit.calculateTrainingMetrics(forMorningReading: true)

        // Fetch sleep data matching the session (with 1-hour buffer to find the right sleep)
        let sleep: HealthKitManager.SleepData?
        if let session = session {
            let recordingEnd = session.endDate ?? Date()
            sleep = try? await healthKit.fetchSleepData(
                for: session.startDate,
                recordingEnd: recordingEnd,
                extendForDisplay: true
            )
        } else {
            sleep = try? await healthKit.fetchLastNightSleep()
        }

        let (v, t) = await (vitals, training)

        await MainActor.run {
            recoveryVitals = v
            trainingMetrics = t
            sleepData = sleep
            latestSession = session
            isLoading = false
        }
    }

    // MARK: - Action Button

    private var actionButton: some View {
        Group {
            if let session = morningReading {
                Button {
                    onViewReport(session)
                } label: {
                    HStack {
                        Image(systemName: "doc.text.fill")
                        Text("View Recovery Report")
                            .fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(AppTheme.primary)
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }
            } else {
                Button {
                    onStartRecording()
                } label: {
                    HStack {
                        Image(systemName: "waveform.circle.fill")
                        Text("Take Morning Reading")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(AppTheme.primary)
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }
            }
        }
    }

    // MARK: - Recovery Score Card

    private var recoveryScoreCard: some View {
        let score = calculateRecoveryScore()
        let color = recoveryColor(score)

        return VStack(spacing: 8) {
            Text("RECOVERY")
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.textTertiary)
                .tracking(2)

            ZStack {
                // Background ring
                Circle()
                    .stroke(color.opacity(0.2), lineWidth: 16)

                // Progress ring
                Circle()
                    .trim(from: 0, to: CGFloat(score) / 100)
                    .stroke(
                        AngularGradient(
                            colors: [color.opacity(0.6), color],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 16, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                // Score
                VStack(spacing: 4) {
                    Text("\(Int(score))")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundColor(color)
                    Text(recoveryLabel(score))
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(AppTheme.textSecondary)
                }
            }
            .frame(width: 180, height: 180)
            .padding(.vertical, 8)

            Text(recoveryMessage(score))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(AppTheme.cardBackground)
        .cornerRadius(20)
    }

    // MARK: - HRV Card

    private var hrvCard: some View {
        MetricCard(
            title: "HRV",
            icon: "waveform.path.ecg",
            iconColor: AppTheme.primary
        ) {
            if let hrv = latestHRV {
                VStack(spacing: 4) {
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text(String(format: "%.0f", hrv))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        Text("ms")
                            .font(.caption)
                            .foregroundColor(AppTheme.textTertiary)
                    }
                    Text(hrvLabel(hrv))
                        .font(.caption)
                        .foregroundColor(hrvColor(hrv))
                }
            } else {
                Text("--")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
    }

    // MARK: - Sleep Card

    private var sleepCard: some View {
        MetricCard(
            title: "SLEEP",
            icon: "moon.fill",
            iconColor: AppTheme.primary
        ) {
            if let sleep = sleepData {
                VStack(spacing: 4) {
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text(String(format: "%.1f", Double(sleep.totalSleepMinutes) / 60.0))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        Text("hrs")
                            .font(.caption)
                            .foregroundColor(AppTheme.textTertiary)
                    }
                    let efficiency = min(100, sleep.sleepEfficiency)
                    Text("\(Int(efficiency))% efficient")
                        .font(.caption)
                        .foregroundColor(efficiency >= 85 ? AppTheme.sage : AppTheme.terracotta)
                }
            } else {
                Text("--")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
    }

    // MARK: - Training Load Card

    private var trainingLoadCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "figure.run")
                    .foregroundColor(AppTheme.primary)
                Text("TRAINING LOAD")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.textTertiary)
                    .tracking(1)
                Spacer()
            }

            if let metrics = trainingMetrics {
                // ACR Gauge
                if let acr = metrics.acuteChronicRatio {
                    ACRGaugeView(acr: acr)
                }

                // ATL / CTL / TSB
                HStack(spacing: 16) {
                    TrainingMetricPill(label: "ATL", value: String(format: "%.0f", metrics.atl), subtitle: "Fatigue")
                    TrainingMetricPill(label: "CTL", value: String(format: "%.0f", metrics.ctl), subtitle: "Fitness")
                    TrainingMetricPill(label: "TSB", value: String(format: "%+.0f", metrics.tsb), subtitle: "Form", color: metrics.tsb >= 0 ? AppTheme.sage : AppTheme.terracotta)
                }
            } else {
                Text("No training data")
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    // MARK: - Vitals Section

    private var vitalsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "heart.text.square")
                    .foregroundColor(AppTheme.primary)
                Text("VITALS")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.textTertiary)
                    .tracking(1)
                Spacer()

                if let vitals = recoveryVitals {
                    StatusBadge(status: vitals.status)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                VitalCell(
                    icon: "lungs.fill",
                    label: "Respiratory",
                    value: recoveryVitals?.respiratoryRate.map { String(format: "%.1f", $0) },
                    unit: "/min",
                    status: recoveryVitals?.isRespiratoryElevated == true ? .elevated : .normal
                )

                VitalCell(
                    icon: "drop.fill",
                    label: "SpO2",
                    value: recoveryVitals?.oxygenSaturation.map { String(format: "%.0f", $0) },
                    unit: "%",
                    status: recoveryVitals?.isSpO2Concerning == true ? .warning : .normal
                )

                VitalCell(
                    icon: "thermometer.medium",
                    label: "Temp",
                    value: recoveryVitals?.wristTemperature.map {
                        let converted = settingsManager.settings.temperatureUnit.convert($0)
                        return String(format: "%+.1f", converted)
                    },
                    unit: settingsManager.settings.temperatureUnit.symbol,
                    status: recoveryVitals?.isTemperatureElevated == true ? .elevated : .normal
                )

                VitalCell(
                    icon: "heart.fill",
                    label: "Resting HR",
                    value: recoveryVitals?.restingHeartRate.map { String(format: "%.0f", $0) },
                    unit: "bpm",
                    status: .normal
                )
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    // MARK: - Insights Section

    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(AppTheme.softGold)
                Text("INSIGHTS")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.textTertiary)
                    .tracking(1)
                Spacer()
            }

            ForEach(generateInsights(), id: \.self) { insight in
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(AppTheme.primary)
                        .frame(width: 6, height: 6)
                        .padding(.top, 6)
                    Text(insight)
                        .font(.subheadline)
                        .foregroundColor(AppTheme.textSecondary)
                }
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    // MARK: - Calculations

    private func calculateRecoveryScore() -> Double {
        // Only include training metrics in score if integration is enabled and not on break
        let effectiveTrainingMetrics: HealthKitManager.TrainingMetrics?
        if settingsManager.settings.enableTrainingLoadIntegration,
           !settingsManager.settings.isOnTrainingBreak {
            effectiveTrainingMetrics = trainingMetrics
        } else {
            effectiveTrainingMetrics = nil
        }

        return RecoveryScoreCalculator.calculate(
            hrvReadiness: latestSession?.analysisResult?.ansMetrics?.readinessScore,
            rmssd: latestHRV,
            sleepData: sleepData,
            trainingMetrics: effectiveTrainingMetrics,
            vitals: recoveryVitals,
            typicalSleepHours: settingsManager.settings.typicalSleepHours
        )
    }

    private func recoveryColor(_ score: Double) -> Color {
        if score >= 80 { return AppTheme.sage }
        if score >= 60 { return AppTheme.softGold }
        if score >= 40 { return AppTheme.terracotta }
        return AppTheme.dustyRose
    }

    private func recoveryLabel(_ score: Double) -> String {
        RecoveryScoreCalculator.label(for: score)
    }

    private func recoveryMessage(_ score: Double) -> String {
        RecoveryScoreCalculator.message(for: score)
    }

    private func hrvLabel(_ hrv: Double) -> String {
        if hrv >= 60 { return "Excellent" }
        if hrv >= 45 { return "Good" }
        if hrv >= 30 { return "Fair" }
        return "Low"
    }

    private func hrvColor(_ hrv: Double) -> Color {
        if hrv >= 60 { return AppTheme.sage }
        if hrv >= 45 { return AppTheme.softGold }
        if hrv >= 30 { return AppTheme.terracotta }
        return AppTheme.dustyRose
    }

    private func generateInsights() -> [String] {
        var insights: [String] = []

        if let vitals = recoveryVitals {
            if vitals.isRespiratoryElevated && vitals.isTemperatureElevated {
                insights.append("Elevated respiratory rate and temperature may indicate illness. Monitor symptoms.")
            } else if vitals.isRespiratoryElevated {
                insights.append("Respiratory rate is elevated. Could indicate stress, illness, or incomplete recovery.")
            }
            if vitals.isSpO2Concerning {
                insights.append("Blood oxygen is lower than optimal. Ensure good sleep environment.")
            }
        }

        if let metrics = trainingMetrics, let acr = metrics.acuteChronicRatio {
            if acr > 1.5 {
                insights.append("Training load is in the injury risk zone. Reduce intensity.")
            } else if acr > 1.3 {
                insights.append("You're pushing hard. Watch for signs of overreaching.")
            } else if acr < 0.8 {
                insights.append("Training load is low. Fitness may be declining.")
            }
        }

        if let sleep = sleepData {
            if sleep.totalSleepMinutes < 360 {  // 6 hours
                insights.append("Short sleep duration impacts recovery. Prioritize rest tonight.")
            }
        }

        if insights.isEmpty {
            insights.append("All metrics look good. You're on track.")
        }

        return insights
    }
}

// MARK: - Supporting Views

private struct MetricCard<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.textTertiary)
                    .tracking(1)
            }

            content()
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }
}

private struct TrainingMetricPill: View {
    let label: String
    let value: String
    let subtitle: String
    var color: Color = AppTheme.textPrimary

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundColor(AppTheme.textTertiary)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundColor(color)
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct VitalCell: View {
    let icon: String
    let label: String
    let value: String?
    let unit: String
    let status: VitalStatus

    enum VitalStatus {
        case normal, elevated, warning

        var color: Color {
            switch self {
            case .normal: return AppTheme.textPrimary
            case .elevated: return AppTheme.terracotta
            case .warning: return AppTheme.dustyRose
            }
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(status == .normal ? AppTheme.textTertiary : status.color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(value ?? "--")
                        .font(.headline)
                        .foregroundColor(status.color)
                    Text(unit)
                        .font(.caption2)
                        .foregroundColor(AppTheme.textTertiary)
                }
            }

            Spacer()
        }
        .padding(12)
        .background(AppTheme.sectionTint)
        .cornerRadius(12)
    }
}

private struct StatusBadge: View {
    let status: HealthKitManager.RecoveryVitals.VitalsStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.caption.weight(.medium))
                .foregroundColor(statusColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.15))
        .cornerRadius(8)
    }

    private var statusColor: Color {
        switch status {
        case .normal: return AppTheme.sage
        case .elevated: return AppTheme.terracotta
        case .warning: return AppTheme.dustyRose
        }
    }

    private var statusText: String {
        switch status {
        case .normal: return "Normal"
        case .elevated: return "Elevated"
        case .warning: return "Warning"
        }
    }
}

private struct ACRGaugeView: View {
    let acr: Double

    var body: some View {
        VStack(spacing: 8) {
            // Gauge bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background zones
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.blue.opacity(0.3)) // Under
                        Rectangle().fill(Color.green.opacity(0.3)) // Optimal
                        Rectangle().fill(Color.yellow.opacity(0.3)) // Peak
                        Rectangle().fill(Color.orange.opacity(0.3)) // Over
                        Rectangle().fill(Color.red.opacity(0.3)) // Risk
                    }
                    .cornerRadius(4)

                    // Indicator
                    let position = min(max((acr - 0.5) / 1.2, 0), 1) // Map 0.5-1.7 to 0-1
                    Circle()
                        .fill(.white)
                        .frame(width: 16, height: 16)
                        .shadow(radius: 2)
                        .overlay(
                            Text(String(format: "%.2f", acr))
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.black)
                        )
                        .offset(x: geo.size.width * position - 8)
                }
            }
            .frame(height: 16)

            // Labels
            HStack {
                Text("Under").font(.caption2).foregroundColor(.blue)
                Spacer()
                Text("Optimal").font(.caption2).foregroundColor(.green)
                Spacer()
                Text("Risk").font(.caption2).foregroundColor(.red)
            }
        }
    }
}

#Preview {
    NavigationStack {
        RecoveryDashboardView(
            sessions: [],
            onStartRecording: {},
            onViewReport: { _ in }
        )
        .environmentObject(RRCollector())
        .environmentObject(SettingsManager.shared)
    }
}
