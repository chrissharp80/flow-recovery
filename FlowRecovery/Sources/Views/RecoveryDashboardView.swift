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

/// Pro-style Recovery Dashboard - comprehensive recovery report with all metrics
struct RecoveryDashboardView: View {
    let sessions: [HRVSession]
    let onStartRecording: () -> Void
    let onViewReport: (HRVSession) -> Void

    @EnvironmentObject var collector: RRCollector
    @EnvironmentObject var settingsManager: SettingsManager

    @State private var recoveryVitals: HealthKitManager.RecoveryVitals?
    @State private var trainingMetrics: HealthKitManager.TrainingMetrics?
    @State private var sleepData: HealthKitManager.SleepData?
    @State private var sleepTrendStats: HealthKitManager.SleepTrendStats?
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

                // Primary Metrics Row (HRV non-tappable since detail is below, Sleep drills in)
                HStack(spacing: 12) {
                    // HRV card - no drill-in since full detail is on this dashboard
                    hrvCard

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

                // Training Load (lighter style)
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

                // Overnight Charts - when we have session with raw data
                if let session = latestSession, let result = session.analysisResult {
                    overnightChartsSection(session: session, result: result)
                }

                // Heart Rate Chart
                if let session = latestSession, let result = session.analysisResult {
                    heartRateSection(session: session, result: result)
                }

                // Trend Comparison (table of numbers)
                if let session = latestSession, let result = session.analysisResult, sessions.count >= 2 {
                    trendComparisonSection(session: session, result: result)
                }

                // Technical plots (no header, just the charts)
                if let session = latestSession, let result = session.analysisResult {
                    technicalPlotsSection(session: session, result: result)
                }

                // Analysis Summary (What This Means) - at bottom as insights
                if let session = latestSession, let result = session.analysisResult {
                    analysisSummarySection(session: session, result: result)
                }

                // Action Button (only show "Take Morning Reading" if no session today)
                if morningReading == nil {
                    takeReadingButton
                }
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

        // Fetch sleep trends (past 7 days)
        let sleepTrend: HealthKitManager.SleepTrendStats?
        if let recentSleep = try? await healthKit.fetchSleepTrend(days: 7) {
            sleepTrend = healthKit.analyzeSleepTrend(from: recentSleep)
        } else {
            sleepTrend = nil
        }

        let (v, t) = await (vitals, training)

        await MainActor.run {
            recoveryVitals = v
            trainingMetrics = t
            sleepData = sleep
            sleepTrendStats = sleepTrend
            latestSession = session
            isLoading = false
        }
    }

    // MARK: - Action Button

    private var takeReadingButton: some View {
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

    // MARK: - Training Load Card (lighter style)

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

    // MARK: - Analysis Summary Section

    private func analysisSummarySection(session: HRVSession, result: HRVAnalysisResult) -> some View {
        let generator = AnalysisSummaryGenerator(
            result: result,
            session: session,
            recentSessions: sessions.filter { $0.state == .complete && $0.analysisResult != nil },
            selectedTags: Set(session.tags),
            sleep: AnalysisSummaryGenerator.SleepInput(from: sleepData),
            sleepTrend: AnalysisSummaryGenerator.SleepTrendInput(from: sleepTrendStats)
        )
        let summary = generator.generate()

        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "stethoscope")
                    .foregroundColor(AppTheme.primary)
                Text("WHAT THIS MEANS")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.textTertiary)
                    .tracking(1)
                Spacer()
            }

            // Main diagnostic assessment
            DiagnosticCard(
                title: summary.diagnosticTitle,
                explanation: summary.diagnosticExplanation,
                icon: summary.diagnosticIcon,
                color: diagnosticColorForScore(summary.diagnosticScore)
            )

            // Probable causes section
            if !summary.probableCauses.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Most Likely Explanations")
                        .font(.subheadline.bold())
                        .foregroundColor(AppTheme.textPrimary)

                    ForEach(Array(summary.probableCauses.enumerated()), id: \.offset) { index, cause in
                        ProbableCauseRow(
                            rank: index + 1,
                            cause: cause.cause,
                            confidence: cause.confidence,
                            explanation: cause.explanation
                        )
                    }
                }
            }

            Divider()

            // Key findings
            VStack(alignment: .leading, spacing: 8) {
                Text("Key Findings")
                    .font(.subheadline.bold())
                    .foregroundColor(AppTheme.textPrimary)

                ForEach(summary.keyFindings, id: \.self) { finding in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundColor(AppTheme.primary)
                            .padding(.top, 6)
                        Text(finding)
                            .font(.subheadline)
                            .foregroundColor(AppTheme.textSecondary)
                    }
                }
            }

            Divider()

            // Actionable recommendations
            VStack(alignment: .leading, spacing: 8) {
                Text("What To Do")
                    .font(.subheadline.bold())
                    .foregroundColor(AppTheme.textPrimary)

                ForEach(summary.actionableSteps, id: \.self) { step in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundColor(AppTheme.sage)
                            .font(.caption)
                        Text(step)
                            .font(.subheadline)
                            .foregroundColor(AppTheme.textSecondary)
                    }
                }
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    private func diagnosticColorForScore(_ score: Double) -> Color {
        if score >= 80 { return AppTheme.sage }
        if score >= 60 { return AppTheme.mist }
        if score >= 40 { return AppTheme.softGold }
        return AppTheme.terracotta
    }

    // MARK: - Training Load Context Section

    private func trainingContextSection(_ training: TrainingContext) -> some View {
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

            // ACR Gauge (like FITIV/TrainingPeaks)
            if let acr = training.acuteChronicRatio {
                DetailedACRGaugeView(acr: acr)
            }

            // Main metrics row: ATL, CTL, Load
            HStack(spacing: 12) {
                TrainingMetricCard(
                    title: "Short Term",
                    subtitle: "ATL · 7 Day",
                    value: String(format: "%.0f", training.atl),
                    color: AppTheme.textPrimary
                )
                TrainingMetricCard(
                    title: "Long Term",
                    subtitle: "CTL · 42 Day",
                    value: String(format: "%.0f", training.ctl),
                    color: AppTheme.textPrimary
                )
                TrainingMetricCard(
                    title: "Load",
                    subtitle: "TRIMP",
                    value: String(format: "%.0f", training.yesterdayTrimp),
                    color: training.yesterdayTrimp > 100 ? .orange : AppTheme.sage
                )
            }

            // Recent workouts if available
            if let workouts = training.recentWorkouts, !workouts.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent Training")
                        .font(.caption.bold())
                        .foregroundColor(AppTheme.textSecondary)
                    ForEach(workouts.prefix(3), id: \.date) { workout in
                        HStack {
                            Text(workout.type)
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.0fm", workout.durationMinutes))
                                .font(.caption)
                                .foregroundColor(AppTheme.textSecondary)
                            Text(String(format: "%.0f", workout.trimp))
                                .font(.caption.bold())
                                .foregroundColor(AppTheme.sage)
                        }
                    }
                }
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    // MARK: - Overnight Charts Section

    private func overnightChartsSection(session: HRVSession, result: HRVAnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "moon.stars")
                    .foregroundColor(AppTheme.primary)
                Text("OVERNIGHT CHARTS")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.textTertiary)
                    .tracking(1)
                Spacer()
            }

            OvernightChartsView(session: session, result: result, healthKitSleep: sleepData, onReanalyzeAt: nil)
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    // MARK: - Heart Rate Section

    private func heartRateSection(session: HRVSession, result: HRVAnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "heart")
                    .foregroundColor(AppTheme.primary)
                Text("HEART RATE")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.textTertiary)
                    .tracking(1)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(result.timeDomain.minHR))-\(Int(result.timeDomain.maxHR)) bpm")
                        .font(.caption.bold())
                        .foregroundColor(AppTheme.terracotta)
                }
            }

            HeartRateChartView(session: session, result: result)
                .frame(height: 150)

            // Legend
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Circle().fill(AppTheme.terracotta).frame(width: 8, height: 8)
                    Text("HR (bpm)").font(.caption2).foregroundColor(AppTheme.textTertiary)
                }
                Spacer()
                Text("Tap for details")
                    .font(.caption2)
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    // MARK: - Technical Plots Section (flat, no header)

    private func technicalPlotsSection(session: HRVSession, result: HRVAnalysisResult) -> some View {
        VStack(spacing: 16) {
            // Comprehensive Metrics Grid (HRV table) - first
            comprehensiveMetricsSection(result: result)

            // Tachogram
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Heart Rate Variability")
                        .font(.headline)
                        .foregroundColor(AppTheme.textPrimary)
                    Spacer()
                    Text("RR Intervals")
                        .font(.caption)
                        .foregroundColor(AppTheme.textTertiary)
                }
                TachogramView(session: session, result: result)
                    .frame(height: 120)
            }
            .padding()
            .background(AppTheme.cardBackground)
            .cornerRadius(12)

            // Poincaré Plot
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Poincaré Plot")
                        .font(.headline)
                        .foregroundColor(AppTheme.textPrimary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("SD1: \(String(format: "%.1f", result.nonlinear.sd1)) ms")
                            .font(.caption)
                        Text("SD2: \(String(format: "%.1f", result.nonlinear.sd2)) ms")
                            .font(.caption)
                    }
                    .foregroundColor(AppTheme.textSecondary)
                }
                PoincarePlotView(session: session, result: result)
                    .frame(height: 250)
            }
            .padding()
            .background(AppTheme.cardBackground)
            .cornerRadius(12)

            // Frequency Analysis
            if let fd = result.frequencyDomain {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Frequency Analysis")
                        .font(.headline)
                        .foregroundColor(AppTheme.textPrimary)

                    FrequencyBandsView(frequencyDomain: fd)
                        .frame(height: 100)

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("LF/HF Ratio")
                                .font(.caption)
                                .foregroundColor(AppTheme.textTertiary)
                            Text(fd.lfHfRatio.map { String(format: "%.2f", $0) } ?? "—")
                                .font(.title3.bold())
                                .foregroundColor(AppTheme.textPrimary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Sympathovagal Balance")
                                .font(.caption)
                                .foregroundColor(AppTheme.textTertiary)
                            Text(balanceInterpretation(fd.lfHfRatio))
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(balanceColor(fd.lfHfRatio))
                        }
                    }
                }
                .padding()
                .background(AppTheme.cardBackground)
                .cornerRadius(12)
            }
        }
    }

    private func balanceInterpretation(_ ratio: Double?) -> String {
        guard let ratio = ratio else { return "—" }
        if ratio < 0.5 { return "Parasympathetic Dominant" }
        if ratio <= 1.5 { return "Balanced" }
        if ratio <= 3 { return "Sympathetic Elevated" }
        return "Sympathetic Dominant"
    }

    private func balanceColor(_ ratio: Double?) -> Color {
        guard let ratio = ratio else { return AppTheme.textSecondary }
        if ratio < 0.5 { return AppTheme.sage }
        if ratio <= 1.5 { return AppTheme.mist }
        if ratio <= 3 { return AppTheme.softGold }
        return AppTheme.terracotta
    }

    // MARK: - Comprehensive Metrics Section

    private func comprehensiveMetricsSection(result: HRVAnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Time Domain Section
            VStack(alignment: .leading, spacing: 10) {
                DetailSectionHeader(title: "Time Domain", icon: "clock")

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    DetailMetricCell(label: "Mean RR", value: String(format: "%.0f ms", result.timeDomain.meanRR))
                    DetailMetricCell(label: "SDNN", value: String(format: "%.1f ms", result.timeDomain.sdnn))
                    DetailMetricCell(label: "RMSSD", value: String(format: "%.1f ms", result.timeDomain.rmssd))
                    DetailMetricCell(label: "pNN50", value: String(format: "%.1f%%", result.timeDomain.pnn50))
                    DetailMetricCell(label: "SDSD", value: String(format: "%.1f ms", result.timeDomain.sdsd))
                    DetailMetricCell(label: "HR Range", value: String(format: "%.0f-%.0f", result.timeDomain.minHR, result.timeDomain.maxHR))
                    DetailMetricCell(label: "Mean HR", value: String(format: "%.0f bpm", result.timeDomain.meanHR))
                    DetailMetricCell(label: "SD HR", value: String(format: "%.1f bpm", result.timeDomain.sdHR))
                }
            }

            Divider()

            // Frequency Domain Section
            if let fd = result.frequencyDomain {
                VStack(alignment: .leading, spacing: 10) {
                    DetailSectionHeader(title: "Frequency Domain", icon: "waveform.path")

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        if let vlf = fd.vlf {
                            DetailMetricCell(label: "VLF", value: String(format: "%.0f ms²", vlf))
                        }
                        DetailMetricCell(label: "LF", value: String(format: "%.0f ms²", fd.lf))
                        DetailMetricCell(label: "HF", value: String(format: "%.0f ms²", fd.hf))
                        DetailMetricCell(label: "Total Power", value: String(format: "%.0f ms²", fd.totalPower))
                        if let lfNu = fd.lfNu {
                            DetailMetricCell(label: "LF n.u.", value: String(format: "%.1f%%", lfNu))
                        }
                        if let hfNu = fd.hfNu {
                            DetailMetricCell(label: "HF n.u.", value: String(format: "%.1f%%", hfNu))
                        }
                        if let ratio = fd.lfHfRatio {
                            DetailMetricCell(label: "LF/HF", value: String(format: "%.2f", ratio))
                        }
                    }
                }

                Divider()
            }

            // Nonlinear Section
            VStack(alignment: .leading, spacing: 10) {
                DetailSectionHeader(title: "Nonlinear Analysis", icon: "point.3.filled.connected.trianglepath.dotted")

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    DetailMetricCell(label: "SD1", value: String(format: "%.1f ms", result.nonlinear.sd1))
                    DetailMetricCell(label: "SD2", value: String(format: "%.1f ms", result.nonlinear.sd2))
                    DetailMetricCell(label: "SD1/SD2", value: String(format: "%.3f", result.nonlinear.sd1Sd2Ratio))
                    if let dfa1 = result.nonlinear.dfaAlpha1 {
                        DetailMetricCell(label: "DFA α1", value: String(format: "%.2f", dfa1))
                    }
                    if let dfa2 = result.nonlinear.dfaAlpha2 {
                        DetailMetricCell(label: "DFA α2", value: String(format: "%.2f", dfa2))
                    }
                    if let sampEn = result.nonlinear.sampleEntropy {
                        DetailMetricCell(label: "SampEn", value: String(format: "%.3f", sampEn))
                    }
                }
            }

            // ANS Indexes Section
            if result.ansMetrics != nil {
                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    DetailSectionHeader(title: "ANS Indexes", icon: "brain.head.profile")

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        if let stress = result.ansMetrics?.stressIndex {
                            DetailMetricCell(label: "Stress Index", value: String(format: "%.0f", stress))
                        }
                        if let pns = result.ansMetrics?.pnsIndex {
                            DetailMetricCell(label: "PNS Index", value: String(format: "%+.2f", pns))
                        }
                        if let sns = result.ansMetrics?.snsIndex {
                            DetailMetricCell(label: "SNS Index", value: String(format: "%+.2f", sns))
                        }
                        if let resp = result.ansMetrics?.respirationRate {
                            DetailMetricCell(label: "Resp Rate", value: String(format: "%.1f /min", resp))
                        }
                        if let readiness = result.ansMetrics?.readinessScore {
                            DetailMetricCell(label: "Readiness", value: String(format: "%.1f /10", readiness))
                        }
                    }
                }
            }

            // Data Quality
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                DetailSectionHeader(title: "Data Quality", icon: "checkmark.seal")

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    DetailMetricCell(label: "Window Beats", value: "\(result.cleanBeatCount)")
                    DetailMetricCell(label: "Artifacts", value: String(format: "%.1f%%", result.artifactPercentage))
                }
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(12)
    }

    // MARK: - Trend Comparison Section

    private func trendComparisonSection(session: HRVSession, result: HRVAnalysisResult) -> some View {
        let stats = computeTrendStats()

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundColor(AppTheme.primary)
                Text("TRENDS")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.textTertiary)
                    .tracking(1)
                Spacer()
            }

            if stats.hasData {
                VStack(spacing: 8) {
                    // RMSSD trend
                    TrendComparisonRow(
                        metric: "HRV (RMSSD)",
                        current: result.timeDomain.rmssd,
                        average: stats.avgRMSSD,
                        baseline: stats.baselineRMSSD,
                        unit: "ms",
                        higherIsBetter: true
                    )

                    // HR trend
                    TrendComparisonRow(
                        metric: "Resting HR",
                        current: result.timeDomain.meanHR,
                        average: stats.avgHR,
                        baseline: stats.baselineHR,
                        unit: "bpm",
                        higherIsBetter: false
                    )

                    // Stress trend (if available)
                    if let currentStress = result.ansMetrics?.stressIndex,
                       let avgStress = stats.avgStress {
                        TrendComparisonRow(
                            metric: "Stress Index",
                            current: currentStress,
                            average: avgStress,
                            baseline: stats.baselineStress,
                            unit: "",
                            higherIsBetter: false
                        )
                    }

                    // Readiness trend (if available)
                    if let currentReadiness = result.ansMetrics?.readinessScore,
                       let avgReadiness = stats.avgReadiness {
                        TrendComparisonRow(
                            metric: "Readiness",
                            current: currentReadiness,
                            average: avgReadiness,
                            baseline: nil,
                            unit: "/10",
                            higherIsBetter: true
                        )
                    }
                }

                // Session count context
                if stats.sessionCount < 7 {
                    Text("Based on \(stats.sessionCount) sessions. Trends become more accurate with more data.")
                        .font(.caption)
                        .foregroundColor(AppTheme.textTertiary)
                        .padding(.top, 4)
                }
            } else {
                Text("Record more sessions to see trends.")
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    // MARK: - Trend Stats Computation

    private struct TrendStats {
        let hasData: Bool
        let avgRMSSD: Double
        let baselineRMSSD: Double?
        let avgHR: Double
        let baselineHR: Double?
        let avgStress: Double?
        let baselineStress: Double?
        let avgReadiness: Double?
        let sessionCount: Int
    }

    private func computeTrendStats() -> TrendStats {
        let validSessions = sessions.filter { $0.state == .complete && $0.analysisResult != nil }
        guard validSessions.count >= 2 else {
            return TrendStats(hasData: false, avgRMSSD: 0, baselineRMSSD: nil, avgHR: 0, baselineHR: nil, avgStress: nil, baselineStress: nil, avgReadiness: nil, sessionCount: 0)
        }

        let rmssdValues = validSessions.compactMap { $0.analysisResult?.timeDomain.rmssd }
        let hrValues = validSessions.compactMap { $0.analysisResult?.timeDomain.meanHR }
        let stressValues = validSessions.compactMap { $0.analysisResult?.ansMetrics?.stressIndex }
        let readinessValues = validSessions.compactMap { $0.analysisResult?.ansMetrics?.readinessScore }

        let avgRMSSD = rmssdValues.isEmpty ? 0 : rmssdValues.reduce(0, +) / Double(rmssdValues.count)
        let avgHR = hrValues.isEmpty ? 0 : hrValues.reduce(0, +) / Double(hrValues.count)
        let avgStress = stressValues.isEmpty ? nil : stressValues.reduce(0, +) / Double(stressValues.count)
        let avgReadiness = readinessValues.isEmpty ? nil : readinessValues.reduce(0, +) / Double(readinessValues.count)

        // Baseline from morning readings
        let morningReadings = validSessions.filter { $0.tags.contains { $0.name == "Morning" } }
        let baselineSessions = morningReadings.isEmpty ? validSessions : morningReadings
        let baselineRMSSD = baselineSessions.count >= 3 ? baselineSessions.suffix(5).compactMap { $0.analysisResult?.timeDomain.rmssd }.reduce(0, +) / Double(min(5, baselineSessions.count)) : nil
        let baselineHR = baselineSessions.count >= 3 ? baselineSessions.suffix(5).compactMap { $0.analysisResult?.timeDomain.meanHR }.reduce(0, +) / Double(min(5, baselineSessions.count)) : nil
        let baselineStress = baselineSessions.count >= 3 ? baselineSessions.suffix(5).compactMap { $0.analysisResult?.ansMetrics?.stressIndex }.reduce(0, +) / Double(min(5, baselineSessions.count)) : nil

        return TrendStats(
            hasData: true,
            avgRMSSD: avgRMSSD,
            baselineRMSSD: baselineRMSSD,
            avgHR: avgHR,
            baselineHR: baselineHR,
            avgStress: avgStress,
            baselineStress: baselineStress,
            avgReadiness: avgReadiness,
            sessionCount: validSessions.count
        )
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

// MARK: - Diagnostic Card

private struct DiagnosticCard: View {
    let title: String
    let explanation: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(color)
                    Text("Primary Assessment")
                        .font(.caption)
                        .foregroundColor(AppTheme.textTertiary)
                }

                Spacer()
            }

            Text(explanation)
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(color.opacity(0.08))
        .cornerRadius(AppTheme.cornerRadius)
    }
}

// MARK: - Probable Cause Row

private struct ProbableCauseRow: View {
    let rank: Int
    let cause: String
    let confidence: String
    let explanation: String

    private var confidenceColor: Color {
        switch confidence {
        case "Critical", "Very High": return AppTheme.dustyRose
        case "High": return AppTheme.terracotta
        case "Moderate-High": return AppTheme.softGold
        case "Moderate": return AppTheme.mist
        case "Contributing Factor", "Good Sign", "Pattern", "Excellent": return AppTheme.sage
        default: return AppTheme.textTertiary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(rank).")
                    .font(.caption.bold())
                    .foregroundColor(AppTheme.textTertiary)
                Text(cause)
                    .font(.subheadline.bold())
                    .foregroundColor(AppTheme.textPrimary)
                Spacer()
                Text(confidence)
                    .font(.caption2.bold())
                    .foregroundColor(confidenceColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(confidenceColor.opacity(0.15))
                    .cornerRadius(6)
            }

            Text(explanation)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(AppTheme.sectionTint)
        .cornerRadius(AppTheme.smallCornerRadius)
    }
}

// MARK: - Collapsible Section

private struct CollapsibleSection<Content: View>: View {
    let title: String
    let icon: String?
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    init(
        _ title: String,
        icon: String? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self._isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack {
                    if let icon = icon {
                        Image(systemName: icon)
                            .foregroundColor(AppTheme.sage)
                    }
                    Text(title)
                        .font(.headline)
                        .foregroundColor(AppTheme.textPrimary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(AppTheme.textTertiary)
                        .font(.caption)
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                }
                .padding()
                .background(AppTheme.cardBackground)
                .cornerRadius(12)
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Trend Comparison Row

private struct TrendComparisonRow: View {
    let metric: String
    let current: Double
    let average: Double
    let baseline: Double?
    let unit: String
    let higherIsBetter: Bool

    private var diff: Double { current - average }
    private var pctDiff: Double { average > 0 ? (diff / average) * 100 : 0 }

    private var trendColor: Color {
        let isGood = higherIsBetter ? diff > 0 : diff < 0
        let isBad = higherIsBetter ? diff < 0 : diff > 0

        if abs(pctDiff) < 5 { return AppTheme.textSecondary }
        if isGood { return AppTheme.sage }
        if isBad && abs(pctDiff) > 15 { return AppTheme.terracotta }
        if isBad { return AppTheme.softGold }
        return AppTheme.textSecondary
    }

    private var trendIcon: String {
        if abs(pctDiff) < 5 { return "equal" }
        return diff > 0 ? "arrow.up.right" : "arrow.down.right"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(metric)
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(formatValue(current))
                        .font(.system(.headline, design: .rounded).bold())
                        .foregroundColor(trendColor)
                    Text(unit)
                        .font(.caption2)
                        .foregroundColor(AppTheme.textTertiary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: trendIcon)
                        .font(.caption2)
                        .foregroundColor(trendColor)
                    Text(String(format: "%+.0f%%", pctDiff))
                        .font(.caption.bold())
                        .foregroundColor(trendColor)
                }
                Text("vs avg \(formatValue(average))")
                    .font(.caption2)
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppTheme.sectionTint)
        .cornerRadius(AppTheme.smallCornerRadius)
    }

    private func formatValue(_ value: Double) -> String {
        if unit == "/10" || unit == "" {
            return String(format: "%.1f", value)
        }
        return String(format: "%.0f", value)
    }
}

// MARK: - Detailed ACR Gauge View

private struct DetailedACRGaugeView: View {
    let acr: Double

    var body: some View {
        VStack(spacing: 8) {
            // Zone labels and gradient bar
            GeometryReader { geometry in
                let width = geometry.size.width

                ZStack(alignment: .leading) {
                    // Gradient background bar
                    HStack(spacing: 0) {
                        Color.blue.opacity(0.6)      // Under (< 0.8)
                        Color.green                   // Optimal (0.8-1.1)
                        Color.yellow                  // Peak (1.1-1.3)
                        Color.orange                  // Over (1.3-1.5)
                        Color.red                     // Risk (> 1.5)
                    }
                    .frame(height: 24)
                    .cornerRadius(4)

                    // ACR indicator
                    let clampedACR = min(max(acr, 0.5), 1.8)
                    let position = (clampedACR - 0.5) / 1.3 * width
                    Circle()
                        .fill(Color.white)
                        .frame(width: 20, height: 20)
                        .shadow(radius: 2)
                        .overlay(
                            Text(String(format: "%.2f", acr))
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.black)
                        )
                        .offset(x: position - 10)
                }
            }
            .frame(height: 24)

            // Zone labels
            HStack {
                Text("Under")
                    .font(.caption2)
                    .foregroundColor(.blue)
                Spacer()
                Text("0.8")
                    .font(.caption2)
                    .foregroundColor(AppTheme.textSecondary)
                Spacer()
                Text("Optimal")
                    .font(.caption2)
                    .foregroundColor(.green)
                Spacer()
                Text("1.3")
                    .font(.caption2)
                    .foregroundColor(AppTheme.textSecondary)
                Spacer()
                Text("Risk")
                    .font(.caption2)
                    .foregroundColor(.red)
            }

            // Status text
            Text(acrStatusText(acr))
                .font(.subheadline.bold())
                .foregroundColor(acrColor(for: acr))
        }
    }

    private func acrStatusText(_ acr: Double) -> String {
        if acr < 0.8 { return "Undertraining - Fitness declining" }
        if acr <= 1.1 { return "Optimal - Balanced load" }
        if acr <= 1.3 { return "Peak - Building fitness" }
        if acr <= 1.5 { return "Overreaching - Monitor recovery" }
        return "High Risk - Reduce training"
    }

    private func acrColor(for acr: Double) -> Color {
        if acr < 0.8 { return .blue }
        if acr <= 1.1 { return .green }
        if acr <= 1.3 { return .yellow }
        if acr <= 1.5 { return .orange }
        return .red
    }
}

// MARK: - Training Metric Card

private struct TrainingMetricCard: View {
    let title: String
    let subtitle: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold())
                .foregroundColor(color)
            Text(title)
                .font(.caption.bold())
                .foregroundColor(AppTheme.textPrimary)
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(AppTheme.cardBackground.opacity(0.5))
        .cornerRadius(8)
    }
}

// MARK: - Detail Section Header

private struct DetailSectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(AppTheme.primary)
                .font(.caption)
            Text(title)
                .font(.caption.bold())
                .foregroundColor(AppTheme.textPrimary)
        }
    }
}

// MARK: - Detail Metric Cell

private struct DetailMetricCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundColor(AppTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(AppTheme.sectionTint)
        .cornerRadius(6)
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
