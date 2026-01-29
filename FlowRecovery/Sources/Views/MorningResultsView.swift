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
import Charts
import QuickLook

/// Comprehensive Recovery Report showing HRV analysis, sleep data, training load, and vitals
/// A one-stop morning readiness check for athletes and health-conscious users
struct MorningResultsView: View {
    let session: HRVSession
    let result: HRVAnalysisResult
    let recentSessions: [HRVSession]  // For trend comparison

    // Required callback - either discard (for new sessions) or simple dismiss
    let onDiscard: () -> Void

    // Optional callbacks for history view features
    var onDelete: (() -> Void)? = nil
    var onReanalyze: ((HRVSession, WindowSelectionMethod) async -> HRVSession?)? = nil
    var onUpdateTags: (([ReadingTag], String?) -> Void)? = nil

    /// Optional callback for manual window reanalysis (timestamp in ms)
    var onReanalyzeAt: ((Int64) -> Void)? = nil

    @State private var selectedTags: Set<ReadingTag>
    @State private var notes: String
    @State private var exportURL: IdentifiableURL?
    @State private var showingHRVInfo = false
    @State private var showingReadinessInfo = false

    // Re-analysis state
    @State private var reanalyzedSession: HRVSession?
    @State private var selectedMethod: WindowSelectionMethod
    @State private var isReanalyzing = false
    @State private var showingReanalyzeConfirmation = false

    // Delete state
    @State private var showingDeleteConfirmation = false

    // PDF generation state
    @State private var isGeneratingPDF = false

    // Section expansion states
    // Everything expanded by default EXCEPT technical details (Kubios-style deep metrics)
    @State private var showingMetrics = true
    @State private var showingPeakCapacity = true
    @State private var showingReadiness = true
    @State private var showingOvernightCharts = true
    @State private var showingHeartRate = true
    @State private var showingTechnicalDetails = false  // Only this is collapsed - deep scientific metrics
    @State private var showingTrends = true
    @State private var showingAnalysis = true
    @State private var showingTags = true
    @State private var showingNotes = true

    // HealthKit integration for sleep data and vitals
    @StateObject private var healthKit = HealthKitManager()
    @State private var healthKitSleep: HealthKitManager.SleepData?
    @State private var sleepTrendStats: HealthKitManager.SleepTrendStats?
    @State private var recoveryVitals: HealthKitManager.RecoveryVitals?

    // Live training load for sessions without stored context
    @State private var liveTrainingContext: TrainingContext?

    /// Composite recovery score (0-100) combining HRV, sleep, training, and vitals
    private var compositeRecoveryScore: Double {
        let trainingContext = displayResult.trainingContext ?? liveTrainingContext
        return RecoveryScoreCalculator.calculate(
            hrvReadiness: displayResult.ansMetrics?.readinessScore,
            rmssd: displayResult.timeDomain.rmssd,
            sleepData: healthKitSleep,
            trainingContext: trainingContext,
            vitals: recoveryVitals,
            typicalSleepHours: SettingsManager.shared.settings.typicalSleepHours
        )
    }

    /// The session to display - uses reanalyzed version if available
    private var displaySession: HRVSession {
        reanalyzedSession ?? session
    }

    /// The result to display - uses reanalyzed version if available
    private var displayResult: HRVAnalysisResult {
        displaySession.analysisResult ?? result
    }

    private var hasRawData: Bool {
        displaySession.rrSeries != nil && !(displaySession.rrSeries?.points.isEmpty ?? true)
    }

    init(session: HRVSession, result: HRVAnalysisResult, recentSessions: [HRVSession] = [], onDiscard: @escaping () -> Void, onDelete: (() -> Void)? = nil, onReanalyze: ((HRVSession, WindowSelectionMethod) async -> HRVSession?)? = nil, onUpdateTags: (([ReadingTag], String?) -> Void)? = nil, onReanalyzeAt: ((Int64) -> Void)? = nil) {
        self.session = session
        self.result = result
        self.recentSessions = recentSessions
        self.onDiscard = onDiscard
        self.onDelete = onDelete
        self.onReanalyze = onReanalyze
        self.onUpdateTags = onUpdateTags
        self.onReanalyzeAt = onReanalyzeAt
        _selectedTags = State(initialValue: Set(session.tags))
        _notes = State(initialValue: session.notes ?? "")
        _selectedMethod = State(initialValue: SettingsManager.shared.settings.defaultWindowSelectionMethod)
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 12) {
                    // Header with date and quality (always visible)
                    headerSection

                    // Key Metrics (always visible)
                    sectionHeader("Key Metrics", icon: "heart.text.square")
                    heroMetricsSection

                    // Recovery Readiness - composite score from HRV, sleep, training, vitals
                    sectionHeader("Readiness", icon: "gauge.with.needle")
                    readinessSection(RecoveryScoreCalculator.toTenScale(compositeRecoveryScore))

                    // Training Context
                    // Historical data (stored trainingContext) always shown - settings don't change the past
                    // Live context only fetched/shown if training integration is currently enabled
                    if let storedTraining = displayResult.trainingContext {
                        // Historical session - always show what was captured
                        sectionHeader("Training Load", icon: "figure.run")
                        trainingContextSection(storedTraining)
                    } else if let liveTraining = liveTrainingContext {
                        // New session - live context was fetched based on current settings
                        sectionHeader("Training Load", icon: "figure.run")
                        trainingContextSection(liveTraining)
                    }

                    // Analysis Summary (always visible)
                    sectionHeader("Analysis Summary", icon: "doc.text")
                    analysisSummarySection

                    // Window Selection Method (for overnight sessions with raw data)
                    if hasRawData && displaySession.sessionType == .overnight && onReanalyze != nil {
                        windowSelectionMethodSection
                    }

                    // Peak Capacity (always visible)
                    if let peakCapacity = displayResult.peakCapacity {
                        sectionHeader("Peak Capacity", icon: "bolt.heart")
                        PeakCapacityCard(capacity: peakCapacity, showInfoButton: true)
                    }

                    // Overnight charts (always visible)
                    sectionHeader("Overnight Charts", icon: "moon.stars")
                    OvernightChartsView(session: displaySession, result: displayResult, healthKitSleep: healthKitSleep, onReanalyzeAt: onReanalyzeAt)

                    // Heart Rate over Time Chart (always visible)
                    sectionHeader("Heart Rate", icon: "heart")
                    heartRateChartSection

                    // Technical Details (ONLY collapsible section - Kubios-style deep metrics)
                    CollapsibleSection("Technical Details", icon: "chart.bar.doc.horizontal", isExpanded: $showingTechnicalDetails) {
                        technicalDetailsSectionContent
                    }

                    // Trend Comparison (always visible)
                    if !recentSessions.isEmpty {
                        sectionHeader("Trends", icon: "chart.line.uptrend.xyaxis")
                        trendComparisonSection
                    }

                    // Tags (always visible)
                    sectionHeader("Tags", icon: "tag")
                    tagsSection

                    // Notes (always visible)
                    sectionHeader("Notes", icon: "note.text")
                    notesSection

                    // Action buttons (always visible)
                    actionButtons
                }
                .padding()
            }
            .background(AppTheme.background.ignoresSafeArea())

            // PDF Generation Loading Overlay
            if isGeneratingPDF {
                pdfLoadingOverlay
            }
        }
        .sheet(item: $exportURL) { identifiable in
            PDFPreviewView(url: identifiable.url)
        }
        .confirmationDialog("Delete Reading", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                onDelete?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete this HRV reading. This action cannot be undone.")
        }
        .confirmationDialog("Re-analyze Session", isPresented: $showingReanalyzeConfirmation, titleVisibility: .visible) {
            Button("Re-analyze") {
                performReanalysis()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will re-run the analysis algorithms on your existing RR data. Your raw data is safe and will not be modified.")
        }
        .task {
            // Fetch HealthKit sleep data for the recording period
            await fetchHealthKitSleep()

            // Fetch recovery vitals for composite score
            let vitals = await healthKit.fetchRecoveryVitals()
            await MainActor.run {
                self.recoveryVitals = vitals
            }

            // Fetch live training context if session doesn't have stored data
            if displayResult.trainingContext == nil {
                await fetchLiveTrainingContext()
            }
        }
    }

    // MARK: - Live Training Load Fetch

    private func fetchLiveTrainingContext() async {
        guard SettingsManager.shared.settings.enableTrainingLoadIntegration,
              !SettingsManager.shared.settings.isOnTrainingBreak else { return }

        // Use forMorningReading: true to show morning state (before today's training)
        // This ensures consistency with RecoveryDashboardView
        let load = await healthKit.calculateTrainingLoad(forMorningReading: true)
        guard let metrics = load.metrics else { return }

        let recentWorkouts: [WorkoutSnapshot] = load.recentWorkouts.prefix(5).map { workout in
            WorkoutSnapshot(
                date: workout.date,
                type: workout.typeDescription,
                durationMinutes: workout.durationMinutes,
                trimp: workout.calculateTrimp()
            )
        }

        await MainActor.run {
            liveTrainingContext = TrainingContext(
                atl: metrics.atl,
                ctl: metrics.ctl,
                tsb: metrics.tsb,
                yesterdayTrimp: metrics.todayTrimp,  // Show today's load for live display
                vo2Max: load.vo2Max,
                daysSinceHardWorkout: load.daysSinceHardWorkout,
                recentWorkouts: recentWorkouts.isEmpty ? nil : recentWorkouts
            )
        }
    }

    // MARK: - HealthKit Sleep

    private func fetchHealthKitSleep() async {
        debugLog("[HealthKit] Starting sleep fetch...")
        debugLog("[HealthKit] HealthKit available: \(healthKit.isHealthKitAvailable)")
        guard healthKit.isHealthKitAvailable else {
            debugLog("[HealthKit] HealthKit not available on this device")
            return
        }

        do {
            debugLog("[HealthKit] Requesting authorization...")
            try await healthKit.requestAuthorization()
            debugLog("[HealthKit] Authorization granted")

            // Fetch tonight's sleep data
            let recordingEnd = session.endDate ?? session.startDate.addingTimeInterval(session.duration ?? 28800)
            debugLog("[HealthKit] Fetching sleep data for period: \(session.startDate) to \(recordingEnd)")
            let sleep = try await healthKit.fetchSleepData(
                for: session.startDate,
                recordingEnd: recordingEnd,
                extendForDisplay: true
            )
            debugLog("[HealthKit] Sleep data received: totalSleep=\(sleep.totalSleepMinutes)min, inBed=\(sleep.inBedMinutes)min, deep=\(sleep.deepSleepMinutes ?? 0)min, awake=\(sleep.awakeMinutes)min")
            await MainActor.run {
                self.healthKitSleep = sleep
            }

            // Fetch sleep trends (past 7 days)
            let recentSleep = try await healthKit.fetchSleepTrend(days: 7)
            debugLog("[HealthKit] Sleep trend: \(recentSleep.count) nights found")
            let trendStats = healthKit.analyzeSleepTrend(from: recentSleep)
            await MainActor.run {
                self.sleepTrendStats = trendStats
            }
        } catch {
            debugLog("[HealthKit] Sleep fetch failed: \(error)")
        }
    }

    // MARK: - Header

    // MARK: - Section Header (Non-collapsible)

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(AppTheme.sage)
            Text(title)
                .font(.headline)
                .foregroundColor(AppTheme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Training Context Section

    private func trainingContextSection(_ training: TrainingContext) -> some View {
        VStack(spacing: 12) {
            // ACR Gauge (like FITIV/TrainingPeaks)
            if let acr = training.acuteChronicRatio {
                acrGauge(acr: acr)
            }

            // Main metrics row: ATL, CTL, Load (matches FITIV layout)
            HStack(spacing: 12) {
                trainingMetricCard(
                    title: "Short Term",
                    subtitle: "ATL · 7 Day",
                    value: String(format: "%.0f", training.atl),
                    color: AppTheme.textPrimary
                )
                trainingMetricCard(
                    title: "Long Term",
                    subtitle: "CTL · 42 Day",
                    value: String(format: "%.0f", training.ctl),
                    color: AppTheme.textPrimary
                )
                trainingMetricCard(
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
        .padding(16)
        .background(AppTheme.cardBackground)
        .cornerRadius(12)
    }

    /// ACR Gauge showing training load balance zones
    private func acrGauge(acr: Double) -> some View {
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

    private func trainingMetricCard(title: String, subtitle: String, value: String, color: Color) -> some View {
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

    private func acrColor(for acr: Double) -> Color {
        if acr < 0.8 { return .blue }
        if acr <= 1.1 { return .green }
        if acr <= 1.3 { return .yellow }
        if acr <= 1.5 { return .orange }
        return .red
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recovery Report")
                        .font(.title2.bold())
                        .foregroundColor(AppTheme.textPrimary)

                    Text(session.startDate, style: .date)
                        .font(.subheadline)
                        .foregroundColor(AppTheme.textSecondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: result.artifactPercentage < 5 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(result.artifactPercentage < 5 ? AppTheme.sage : AppTheme.softGold)
                        Text(result.artifactPercentage < 5 ? "Excellent" : "Good")
                            .font(.caption.bold())
                            .foregroundColor(result.artifactPercentage < 5 ? AppTheme.sage : AppTheme.softGold)
                    }

                    Text("\(result.cleanBeatCount) beats")
                        .font(.caption)
                        .foregroundColor(AppTheme.textTertiary)
                }
            }

            // Analysis window info
            if let series = session.rrSeries {
                let windowDuration = Double(result.windowEnd - result.windowStart) / Double(series.points.count) * series.durationMinutes
                HStack {
                    Image(systemName: "clock")
                        .foregroundColor(AppTheme.mist)
                    Text("Best \(String(format: "%.1f", windowDuration)) min window from overnight recording")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)
                }
            }
        }
        .zenCard()
    }

    // MARK: - Hero Metrics

    private var heroMetricsSection: some View {
        VStack(spacing: 16) {
            // Prominent HRV Score (RMSSD is the primary HRV metric)
            Button {
                showingHRVInfo = true
            } label: {
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Your HRV")
                            .font(.subheadline)
                            .foregroundColor(AppTheme.textSecondary)
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundColor(AppTheme.textTertiary)
                    }
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(String(format: "%.0f", result.timeDomain.rmssd))
                            .font(.system(size: 64, weight: .bold, design: .rounded))
                            .foregroundColor(hrvScoreColor)
                        Text("ms")
                            .font(.title3)
                            .foregroundColor(AppTheme.textTertiary)
                    }
                    Text(hrvScoreLabel)
                        .font(.caption)
                        .foregroundColor(hrvScoreColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(hrvScoreColor.opacity(0.15))
                        .cornerRadius(12)
                    if let ageContext = hrvAgeContext {
                        Text(ageContext.capitalized)
                            .font(.caption2)
                            .foregroundColor(AppTheme.textSecondary)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(AppTheme.cardBackground)
                .cornerRadius(AppTheme.cornerRadius)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingHRVInfo) {
                MetricExplanationPopover(metric: "RMSSD")
            }

            // Heart Rate Stats Row
            HStack(spacing: 8) {
                HRStatCard(title: "Min", value: result.timeDomain.minHR, color: AppTheme.sage)
                HRStatCard(title: "Avg", value: result.timeDomain.meanHR, color: AppTheme.terracotta)
                HRStatCard(title: "Max", value: result.timeDomain.maxHR, color: AppTheme.dustyRose)
                HRStatCard(title: "SDNN", value: result.timeDomain.sdnn, unit: "ms", color: AppTheme.sdnnColor)
            }
        }
    }

    /// Age-adjusted HRV interpretation using user's age and sex
    private var ageAdjustedHRVInterpretation: RMSSDInterpretation {
        let settings = SettingsManager.shared.settings
        let sex: AgeAdjustedHRV.Sex? = {
            switch settings.biologicalSex {
            case .male: return .male
            case .female: return .female
            case .other, .none: return nil
            }
        }()
        return AgeAdjustedHRV.interpret(rmssd: result.timeDomain.rmssd, age: settings.age, sex: sex)
    }

    private var hrvScoreColor: Color {
        switch ageAdjustedHRVInterpretation.category {
        case .excellent: return AppTheme.sage
        case .good: return AppTheme.sage.opacity(0.8)
        case .fair: return AppTheme.softGold
        case .reduced: return AppTheme.terracotta
        case .low: return AppTheme.dustyRose
        }
    }

    private var hrvScoreLabel: String {
        ageAdjustedHRVInterpretation.label
    }

    /// Context string showing age-based HRV interpretation
    private var hrvAgeContext: String? {
        ageAdjustedHRVInterpretation.ageContext
    }

    // MARK: - Readiness

    private func readinessSection(_ score: Double) -> some View {
        VStack(spacing: 16) {
            Button {
                showingReadinessInfo = true
            } label: {
                HStack {
                    HStack(spacing: 4) {
                        Text("Recovery Readiness")
                            .font(.headline)
                            .foregroundColor(AppTheme.textPrimary)
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundColor(AppTheme.textTertiary)
                    }
                    Spacer()
                    Text(readinessLabel(score))
                        .font(.subheadline.bold())
                        .foregroundColor(readinessColor(score))
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingReadinessInfo) {
                ReadinessExplanationPopover()
            }

            // Gauge
            ZStack {
                // Background arc
                Circle()
                    .trim(from: 0.15, to: 0.85)
                    .stroke(AppTheme.sectionTint, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(90))

                // Value arc
                Circle()
                    .trim(from: 0.15, to: 0.15 + (0.7 * score / 10))
                    .stroke(
                        AngularGradient(
                            gradient: AppTheme.readinessGradient,
                            center: .center,
                            startAngle: .degrees(144),
                            endAngle: .degrees(396)
                        ),
                        style: StrokeStyle(lineWidth: 14, lineCap: .round)
                    )
                    .rotationEffect(.degrees(90))

                VStack(spacing: 2) {
                    Text(String(format: "%.1f", score))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundColor(readinessColor(score))
                    Text("/ 10")
                        .font(.caption)
                        .foregroundColor(AppTheme.textTertiary)
                }
            }
            .frame(height: 150)
            .padding(.horizontal, 40)

            // Interpretation
            Text(readinessInterpretation(score))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .zenCard()
    }

    // MARK: - Heart Rate Chart

    private var heartRateChartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Heart Rate Over Time")
                    .font(.headline)
                    .foregroundColor(AppTheme.textPrimary)
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
        .zenCard()
    }

    // MARK: - Technical Details Content

    private var technicalDetailsSectionContent: some View {
        VStack(spacing: 16) {
            tachogramSection
            poincarePlotSection
            if result.frequencyDomain != nil {
                frequencySection
            }
            additionalMetricsSection
        }
    }

    // MARK: - Poincaré Plot

    private var poincarePlotSection: some View {
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

            // Explanation
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(AppTheme.primary)
                            .frame(width: 8, height: 8)
                        Text("SD1")
                            .font(.caption.bold())
                            .foregroundColor(AppTheme.textPrimary)
                    }
                    Text("Short-term variability")
                        .font(.caption2)
                        .foregroundColor(AppTheme.textTertiary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(AppTheme.dustyRose)
                            .frame(width: 8, height: 8)
                        Text("SD2")
                            .font(.caption.bold())
                            .foregroundColor(AppTheme.textPrimary)
                    }
                    Text("Long-term variability")
                        .font(.caption2)
                        .foregroundColor(AppTheme.textTertiary)
                }
            }
        }
        .zenCard()
    }

    // MARK: - Tachogram

    private var tachogramSection: some View {
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
        .zenCard()
    }

    // MARK: - Frequency Domain

    private var frequencySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Frequency Analysis")
                .font(.headline)
                .foregroundColor(AppTheme.textPrimary)

            if let fd = result.frequencyDomain {
                // Band power bars
                FrequencyBandsView(frequencyDomain: fd)
                    .frame(height: 100)

                // LF/HF ratio
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
        }
        .zenCard()
    }

    // MARK: - Comprehensive Metrics (Kubios Pro Style)

    private var additionalMetricsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Time Domain Section
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Time Domain", icon: "clock")

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    MetricCell(label: "Mean RR", value: String(format: "%.0f ms", result.timeDomain.meanRR))
                    MetricCell(label: "SDNN", value: String(format: "%.1f ms", result.timeDomain.sdnn))
                    MetricCell(label: "RMSSD", value: String(format: "%.1f ms", result.timeDomain.rmssd))
                    MetricCell(label: "pNN50", value: String(format: "%.1f%%", result.timeDomain.pnn50))
                    MetricCell(label: "SDSD", value: String(format: "%.1f ms", result.timeDomain.sdsd))
                    MetricCell(label: "HR Range", value: String(format: "%.0f-%.0f", result.timeDomain.minHR, result.timeDomain.maxHR))
                    MetricCell(label: "Mean HR", value: String(format: "%.0f bpm", result.timeDomain.meanHR))
                    MetricCell(label: "SD HR", value: String(format: "%.1f bpm", result.timeDomain.sdHR))
                    if let tri = result.timeDomain.triangularIndex {
                        MetricCell(label: "HRV TI", value: String(format: "%.1f", tri))
                    }
                }
            }

            Divider()

            // Frequency Domain Section
            if let fd = result.frequencyDomain {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Frequency Domain", icon: "waveform.path")

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        if let vlf = fd.vlf {
                            MetricCell(label: "VLF", value: String(format: "%.0f ms²", vlf))
                        }
                        MetricCell(label: "LF", value: String(format: "%.0f ms²", fd.lf))
                        MetricCell(label: "HF", value: String(format: "%.0f ms²", fd.hf))
                        MetricCell(label: "Total Power", value: String(format: "%.0f ms²", fd.totalPower))
                        if let lfNu = fd.lfNu {
                            MetricCell(label: "LF n.u.", value: String(format: "%.1f%%", lfNu))
                        }
                        if let hfNu = fd.hfNu {
                            MetricCell(label: "HF n.u.", value: String(format: "%.1f%%", hfNu))
                        }
                        if let ratio = fd.lfHfRatio {
                            MetricCell(label: "LF/HF", value: String(format: "%.2f", ratio))
                        }
                    }
                }

                Divider()
            }

            // Nonlinear Section (Poincaré & DFA)
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Nonlinear Analysis", icon: "point.3.filled.connected.trianglepath.dotted")

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    MetricCell(label: "SD1", value: String(format: "%.1f ms", result.nonlinear.sd1))
                    MetricCell(label: "SD2", value: String(format: "%.1f ms", result.nonlinear.sd2))
                    MetricCell(label: "SD1/SD2", value: String(format: "%.3f", result.nonlinear.sd1Sd2Ratio))
                    if let dfa1 = result.nonlinear.dfaAlpha1 {
                        MetricCell(label: "DFA α1", value: String(format: "%.2f", dfa1))
                    }
                    if let dfa2 = result.nonlinear.dfaAlpha2 {
                        MetricCell(label: "DFA α2", value: String(format: "%.2f", dfa2))
                    }
                    if let r2 = result.nonlinear.dfaAlpha1R2 {
                        MetricCell(label: "α1 R²", value: String(format: "%.3f", r2))
                    }
                    if let sampEn = result.nonlinear.sampleEntropy {
                        MetricCell(label: "SampEn", value: String(format: "%.3f", sampEn))
                    }
                    if let appEn = result.nonlinear.approxEntropy {
                        MetricCell(label: "ApEn", value: String(format: "%.3f", appEn))
                    }
                }
            }

            // ANS Indexes Section
            if result.ansMetrics != nil {
                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "ANS Indexes", icon: "brain.head.profile")

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        if let stress = result.ansMetrics?.stressIndex {
                            MetricCell(label: "Stress Index", value: String(format: "%.0f", stress))
                        }
                        if let pns = result.ansMetrics?.pnsIndex {
                            MetricCell(label: "PNS Index", value: String(format: "%+.2f", pns))
                        }
                        if let sns = result.ansMetrics?.snsIndex {
                            MetricCell(label: "SNS Index", value: String(format: "%+.2f", sns))
                        }
                        if let resp = result.ansMetrics?.respirationRate {
                            MetricCell(label: "Resp Rate", value: String(format: "%.1f /min", resp))
                        }
                        if let readiness = result.ansMetrics?.readinessScore {
                            MetricCell(label: "Readiness", value: String(format: "%.1f /10", readiness))
                        }
                    }
                }
            }

            // Data Quality
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Data Quality", icon: "checkmark.seal")

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    MetricCell(label: "Window Beats", value: "\(result.cleanBeatCount)")
                    MetricCell(label: "Artifacts", value: String(format: "%.1f%%", result.artifactPercentage))
                }

                // Explanatory note
                Text("HRV metrics are from a 5-min analysis window, not the full \(session.rrSeries?.points.count ?? 0) recorded beats.")
                    .font(.caption2)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
        .zenCard()
    }

    // MARK: - Trend Comparison Section

    private var trendComparisonSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundColor(AppTheme.primary)
                Text("Trend Analysis")
                    .font(.headline)
                    .foregroundColor(AppTheme.textPrimary)
            }

            // Comparison stats
            let stats = trendStats
            if stats.hasData {
                VStack(spacing: 12) {
                    // RMSSD trend
                    TrendComparisonRow(
                        metric: "HRV (RMSSD)",
                        current: result.timeDomain.rmssd,
                        average: stats.avgRMSSD,
                        baseline: stats.baselineRMSSD,
                        unit: "ms",
                        higherIsBetter: true
                    )

                    // Heart Rate trend
                    TrendComparisonRow(
                        metric: "Resting HR",
                        current: result.timeDomain.meanHR,
                        average: stats.avgHR,
                        baseline: stats.baselineHR,
                        unit: "bpm",
                        higherIsBetter: false
                    )

                    // Stress Index trend
                    if let currentStress = result.ansMetrics?.stressIndex, stats.avgStress != nil {
                        TrendComparisonRow(
                            metric: "Stress Index",
                            current: currentStress,
                            average: stats.avgStress!,
                            baseline: stats.baselineStress,
                            unit: "",
                            higherIsBetter: false
                        )
                    }

                    // Readiness trend
                    if let currentReadiness = result.ansMetrics?.readinessScore, stats.avgReadiness != nil {
                        TrendComparisonRow(
                            metric: "Readiness",
                            current: currentReadiness,
                            average: stats.avgReadiness!,
                            baseline: nil,
                            unit: "/10",
                            higherIsBetter: true
                        )
                    }
                }

                Divider()

                // AI Trend Insight
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "brain")
                            .foregroundColor(AppTheme.primary)
                        Text("AI Trend Insight")
                            .font(.subheadline.bold())
                            .foregroundColor(AppTheme.textPrimary)
                    }

                    Text(trendInsight)
                        .font(.subheadline)
                        .foregroundColor(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
                .background(AppTheme.primary.opacity(0.08))
                .cornerRadius(AppTheme.smallCornerRadius)
            } else {
                Text("More sessions needed for trend analysis")
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }
        }
        .zenCard()
    }

    // MARK: - Trend Computation

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
        let daySpan: Int
        let trend7Day: Double?  // % change over 7 days
        let trend30Day: Double? // % change over 30 days
    }

    private var trendStats: TrendStats {
        let validSessions = recentSessions.filter { $0.state == .complete && $0.analysisResult != nil }
        guard validSessions.count >= 2 else {
            return TrendStats(hasData: false, avgRMSSD: 0, baselineRMSSD: nil, avgHR: 0, baselineHR: nil, avgStress: nil, baselineStress: nil, avgReadiness: nil, sessionCount: 0, daySpan: 0, trend7Day: nil, trend30Day: nil)
        }

        let rmssdValues = validSessions.compactMap { $0.analysisResult?.timeDomain.rmssd }
        let hrValues = validSessions.compactMap { $0.analysisResult?.timeDomain.meanHR }
        let stressValues = validSessions.compactMap { $0.analysisResult?.ansMetrics?.stressIndex }
        let readinessValues = validSessions.compactMap { $0.analysisResult?.ansMetrics?.readinessScore }

        let avgRMSSD = rmssdValues.isEmpty ? 0 : rmssdValues.reduce(0, +) / Double(rmssdValues.count)
        let avgHR = hrValues.isEmpty ? 0 : hrValues.reduce(0, +) / Double(hrValues.count)
        let avgStress = stressValues.isEmpty ? nil : stressValues.reduce(0, +) / Double(stressValues.count)
        let avgReadiness = readinessValues.isEmpty ? nil : readinessValues.reduce(0, +) / Double(readinessValues.count)

        // Compute baseline from oldest stable readings (morning readings preferred)
        let morningReadings = validSessions.filter { $0.tags.contains { $0.name == "Morning" } }
        let baselineSessions = morningReadings.isEmpty ? validSessions : morningReadings
        let baselineRMSSD = baselineSessions.count >= 3 ? baselineSessions.suffix(5).compactMap { $0.analysisResult?.timeDomain.rmssd }.reduce(0, +) / Double(min(5, baselineSessions.count)) : nil
        let baselineHR = baselineSessions.count >= 3 ? baselineSessions.suffix(5).compactMap { $0.analysisResult?.timeDomain.meanHR }.reduce(0, +) / Double(min(5, baselineSessions.count)) : nil
        let baselineStress = baselineSessions.count >= 3 ? baselineSessions.suffix(5).compactMap { $0.analysisResult?.ansMetrics?.stressIndex }.reduce(0, +) / Double(min(5, baselineSessions.count)) : nil

        // Day span
        let dates = validSessions.map { $0.startDate }
        let daySpan = Calendar.current.dateComponents([.day], from: dates.min() ?? Date(), to: dates.max() ?? Date()).day ?? 0

        // 7-day trend
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let recentWeek = validSessions.filter { $0.startDate >= sevenDaysAgo }
        let olderWeek = validSessions.filter { $0.startDate < sevenDaysAgo }
        var trend7Day: Double?
        if recentWeek.count >= 2 && olderWeek.count >= 2 {
            let recentAvg = recentWeek.compactMap { $0.analysisResult?.timeDomain.rmssd }.reduce(0, +) / Double(recentWeek.count)
            let olderAvg = olderWeek.compactMap { $0.analysisResult?.timeDomain.rmssd }.reduce(0, +) / Double(olderWeek.count)
            if olderAvg > 0 {
                trend7Day = ((recentAvg - olderAvg) / olderAvg) * 100
            }
        }

        return TrendStats(
            hasData: true,
            avgRMSSD: avgRMSSD,
            baselineRMSSD: baselineRMSSD,
            avgHR: avgHR,
            baselineHR: baselineHR,
            avgStress: avgStress,
            baselineStress: baselineStress,
            avgReadiness: avgReadiness,
            sessionCount: validSessions.count,
            daySpan: daySpan,
            trend7Day: trend7Day,
            trend30Day: nil
        )
    }

    private var trendInsight: String {
        let stats = trendStats
        guard stats.hasData else { return "Record more sessions to see trends." }

        var insights: [String] = []
        let currentRMSSD = result.timeDomain.rmssd
        let currentHR = result.timeDomain.meanHR
        let currentStress = result.ansMetrics?.stressIndex

        // RMSSD comparison
        let rmssdDiff = currentRMSSD - stats.avgRMSSD
        let rmssdPct = (rmssdDiff / stats.avgRMSSD) * 100

        if abs(rmssdPct) < 10 {
            insights.append("Your HRV is consistent with your recent average (\(String(format: "%.0f", stats.avgRMSSD))ms).")
        } else if rmssdPct > 20 {
            insights.append("Your HRV is significantly higher than your average of \(String(format: "%.0f", stats.avgRMSSD))ms (+\(String(format: "%.0f", rmssdPct))%), suggesting excellent recovery today.")
        } else if rmssdPct > 10 {
            insights.append("Your HRV is above your average of \(String(format: "%.0f", stats.avgRMSSD))ms (+\(String(format: "%.0f", rmssdPct))%), indicating good recovery.")
        } else if rmssdPct < -20 {
            insights.append("Your HRV is significantly below your average of \(String(format: "%.0f", stats.avgRMSSD))ms (\(String(format: "%.0f", rmssdPct))%). Consider taking it easy today.")
        } else if rmssdPct < -10 {
            insights.append("Your HRV is below your average of \(String(format: "%.0f", stats.avgRMSSD))ms (\(String(format: "%.0f", rmssdPct))%). You may not be fully recovered.")
        }

        // Baseline comparison
        if let baseline = stats.baselineRMSSD {
            let baselineDiff = ((currentRMSSD - baseline) / baseline) * 100
            if baselineDiff < -15 {
                insights.append("This is \(String(format: "%.0f", abs(baselineDiff)))% below your personal baseline.")
            } else if baselineDiff > 15 {
                insights.append("This is \(String(format: "%.0f", baselineDiff))% above your baseline—you're in great shape.")
            }
        }

        // HR trend
        let hrDiff = currentHR - stats.avgHR
        if hrDiff > 5 {
            insights.append("Resting heart rate is elevated at \(String(format: "%.0f", currentHR)) bpm (avg: \(String(format: "%.0f", stats.avgHR)) bpm), which may indicate stress, dehydration, or incomplete recovery.")
        } else if hrDiff < -5 {
            insights.append("Resting heart rate is lower than average at \(String(format: "%.0f", currentHR)) bpm (avg: \(String(format: "%.0f", stats.avgHR)) bpm), suggesting good cardiovascular fitness or deep rest.")
        }

        // Stress pattern
        if let stress = currentStress, let avgStress = stats.avgStress {
            if stress > avgStress * 1.3 && stress > 200 {
                insights.append("Stress markers are elevated compared to your norm. Consider stress management today.")
            }
        }

        // Weekly trend
        if let trend = stats.trend7Day {
            if trend > 10 {
                insights.append("Your 7-day HRV trend is improving (+\(String(format: "%.0f", trend))%)—keep doing what you're doing!")
            } else if trend < -10 {
                insights.append("Your 7-day HRV trend shows a decline (\(String(format: "%.0f", trend))%). Consider prioritizing recovery.")
            }
        }

        // Session count context
        if stats.sessionCount < 7 {
            insights.append("With \(stats.sessionCount) sessions recorded, trends will become more accurate over time.")
        }

        return insights.joined(separator: " ")
    }

    // MARK: - Analysis Summary

    // MARK: - Shared Analysis Summary Generator

    /// Uses the shared AnalysisSummaryGenerator to ensure PDF and app show identical content
    private var analysisSummary: AnalysisSummaryGenerator.AnalysisSummary {
        let generator = AnalysisSummaryGenerator(
            result: result,
            session: session,
            recentSessions: recentSessions,
            selectedTags: selectedTags,
            sleep: AnalysisSummaryGenerator.SleepInput(from: healthKitSleep),
            sleepTrend: AnalysisSummaryGenerator.SleepTrendInput(from: sleepTrendStats)
        )
        return generator.generate()
    }

    private var analysisSummarySection: some View {
        let summary = analysisSummary

        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "stethoscope")
                    .foregroundColor(AppTheme.primary)
                Text("What This Means")
                    .font(.headline)
                    .foregroundColor(AppTheme.textPrimary)
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
        .zenCard()
    }

    // MARK: - Diagnostic Analysis Engine (legacy - kept for non-summary uses)

    private func diagnosticColorForScore(_ score: Double) -> Color {
        if score >= 80 { return AppTheme.sage }
        if score >= 60 { return AppTheme.mist }
        if score >= 40 { return AppTheme.softGold }
        return AppTheme.terracotta
    }

    private var diagnosticTitle: String {
        let score = computeDiagnosticScore()
        if score >= 80 { return "Well Recovered" }
        if score >= 60 { return "Adequate Recovery" }
        if score >= 40 { return "Incomplete Recovery" }
        if score >= 20 { return "Significant Stress Load" }
        return "Recovery Needed"
    }

    private var diagnosticIcon: String {
        let score = computeDiagnosticScore()
        if score >= 80 { return "checkmark.circle.fill" }
        if score >= 60 { return "hand.thumbsup.fill" }
        if score >= 40 { return "exclamationmark.triangle.fill" }
        return "bed.double.fill"
    }

    private var diagnosticColor: Color {
        let score = computeDiagnosticScore()
        if score >= 80 { return AppTheme.sage }
        if score >= 60 { return AppTheme.mist }
        if score >= 40 { return AppTheme.softGold }
        return AppTheme.terracotta
    }

    private var diagnosticExplanation: String {
        let rmssd = result.timeDomain.rmssd
        let stress = result.ansMetrics?.stressIndex ?? 150
        let lfhf = result.frequencyDomain?.lfHfRatio ?? 1.0
        let dfa = result.nonlinear.dfaAlpha1 ?? 1.0

        // Build contextual explanation with sleep awareness
        var explanation = ""

        // Sleep context from HealthKit
        let isShortSleep = (healthKitSleep?.totalSleepMinutes ?? 0) > 0 && (healthKitSleep?.totalSleepMinutes ?? 500) < 300
        let isGoodSleep = (healthKitSleep?.totalSleepMinutes ?? 0) >= 420
        let isFragmented = (healthKitSleep?.awakeMinutes ?? 0) > 30
        let sleepFormatted: String = {
            guard let sleep = healthKitSleep, sleep.totalSleepMinutes > 0 else { return "" }
            let hours = sleep.totalSleepMinutes / 60
            let mins = sleep.totalSleepMinutes % 60
            return hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
        }()

        // Build sleep context string
        var sleepContext = ""
        if let sleep = healthKitSleep, sleep.totalSleepMinutes > 0 {
            if isShortSleep {
                sleepContext = " Your short sleep (\(sleepFormatted)) is likely a major contributor."
            } else if isFragmented {
                sleepContext = " Fragmented sleep (\(sleep.awakeMinutes) min awake) may be reducing recovery quality."
            } else if sleep.sleepEfficiency < 75 {
                sleepContext = " Low sleep efficiency (\(Int(sleep.sleepEfficiency))%) limits restorative recovery."
            }
        }

        if rmssd < 20 {
            explanation = "Your HRV is significantly reduced at \(Int(rmssd))ms. "
            if isShortSleep {
                explanation += "With only \(sleepFormatted) of sleep, your body hasn't had adequate time to recover. This is the most likely explanation for your low HRV."
            } else if stress > 300 {
                explanation += "Combined with high stress markers, this pattern is often seen with: acute illness coming on, severe sleep deprivation, or intense accumulated physical/mental strain.\(sleepContext)"
            } else if lfhf > 3 {
                explanation += "Your nervous system is in fight-or-flight mode. This can indicate mental/emotional stress, poor sleep quality, or your body fighting off infection.\(sleepContext)"
            } else {
                explanation += "This suggests your parasympathetic (rest-and-digest) system is suppressed. Common causes include overtraining, chronic stress, or early illness.\(sleepContext)"
            }
        } else if rmssd < 30 {
            explanation = "Your HRV is below typical at \(Int(rmssd))ms. "
            if isShortSleep {
                explanation += "Your short sleep duration (\(sleepFormatted)) is likely contributing to incomplete recovery."
            } else if isFragmented, let sleep = healthKitSleep {
                explanation += "Fragmented sleep (\(sleep.awakeMinutes) min awake) may be preventing deep recovery even with adequate duration."
            } else if dfa > 1.2 {
                explanation += "The reduced complexity in your heart rhythm suggests fatigue or incomplete recovery from recent demands.\(sleepContext)"
            } else if stress > 200 {
                explanation += "Elevated stress markers suggest your body is working harder than usual to maintain balance.\(sleepContext)"
            } else {
                explanation += "This may indicate accumulated fatigue, mild dehydration, or the early stages of fighting off illness.\(sleepContext)"
            }
        } else if rmssd >= 50 {
            explanation = "Your HRV of \(Int(rmssd))ms indicates strong vagal tone and excellent recovery. "
            if isGoodSleep && !isFragmented {
                explanation += "Quality sleep (\(sleepFormatted)) has allowed your body to fully recover."
            } else if stress < 100 {
                explanation += "Low stress markers confirm your nervous system is well-balanced. You have capacity for challenging activities today."
            } else {
                explanation += "Your parasympathetic system is active and healthy."
            }
        } else {
            explanation = "Your HRV of \(Int(rmssd))ms is in a moderate range. "
            if isShortSleep {
                explanation += "With only \(sleepFormatted) of sleep, your HRV may improve with better rest."
            } else if lfhf > 2 {
                explanation += "There's some sympathetic activation present, which could be residual from yesterday's activities or mild ongoing stress.\(sleepContext)"
            } else {
                explanation += "Your autonomic nervous system is reasonably balanced."
            }
        }

        return explanation
    }

    private func computeDiagnosticScore() -> Double {
        var score = 50.0

        // RMSSD contribution (40 points max) - using age-adjusted interpretation
        switch ageAdjustedHRVInterpretation.category {
        case .excellent: score += 40
        case .good: score += 30
        case .fair: score += 20
        case .reduced: score += 10
        case .low: score -= 10
        }

        // Stress index contribution (20 points max)
        if let stress = result.ansMetrics?.stressIndex {
            if stress < 100 { score += 20 }
            else if stress < 150 { score += 15 }
            else if stress < 200 { score += 10 }
            else if stress < 300 { score += 0 }
            else { score -= 15 }
        }

        // LF/HF balance contribution (20 points max)
        if let ratio = result.frequencyDomain?.lfHfRatio {
            if ratio >= 0.5 && ratio <= 2.0 { score += 20 }
            else if ratio < 0.5 { score += 15 }  // Parasympathetic dominant (recovery)
            else if ratio <= 3.0 { score += 5 }
            else { score -= 10 }
        }

        // DFA contribution (20 points max)
        if let dfa = result.nonlinear.dfaAlpha1 {
            if dfa >= 0.75 && dfa <= 1.0 { score += 20 }
            else if dfa > 1.0 && dfa <= 1.15 { score += 10 }
            else { score += 0 }
        }

        // ANS Balance contribution - penalize sympathetic dominance (20 points impact)
        if let sns = result.ansMetrics?.snsIndex, let pns = result.ansMetrics?.pnsIndex {
            let balance = pns - sns  // Positive = parasympathetic dominant
            if balance >= 1.0 { score += 15 }
            else if balance >= 0 { score += 10 }
            else if balance >= -1.0 { score -= 5 }
            else { score -= 15 }
        }

        return min(100, max(0, score))
    }

    private struct ProbableCause {
        let cause: String
        let confidence: String
        let explanation: String
    }

    private var probableCauses: [ProbableCause] {
        var causes: [(cause: ProbableCause, weight: Double)] = []

        let rmssd = result.timeDomain.rmssd
        let stress = result.ansMetrics?.stressIndex ?? 150
        let lfhf = result.frequencyDomain?.lfHfRatio ?? 1.0
        let dfa = result.nonlinear.dfaAlpha1 ?? 1.0
        let pnn50 = result.timeDomain.pnn50
        let stats = trendStats

        // Determine if this is a good or bad reading
        let isGoodReading = rmssd >= 40 && stress < 200 && lfhf < 2.5 && dfa < 1.2
        let isExcellentReading = stats.hasData && rmssd > stats.avgRMSSD * 1.15

        // Calculate historical tag impact from recent sessions
        let tagImpact = calculateTagImpact()

        // === POSITIVE INSIGHTS (why is HRV high?) ===
        if isGoodReading || isExcellentReading {
            // HealthKit sleep - positive factors
            if let sleep = healthKitSleep {
                // Great sleep duration
                if sleep.totalSleepMinutes >= 420 { // 7+ hours
                    let hours = Double(sleep.totalSleepMinutes) / 60.0
                    causes.append((ProbableCause(
                        cause: "Solid Sleep",
                        confidence: "Contributing Factor",
                        explanation: "HealthKit shows \(String(format: "%.1f", hours)) hours of sleep. Getting 7+ hours is strongly associated with elevated HRV and better recovery."
                    ), 0.8))
                }

                // High sleep efficiency
                if sleep.sleepEfficiency >= 90 {
                    causes.append((ProbableCause(
                        cause: "Excellent Sleep Quality",
                        confidence: "Contributing Factor",
                        explanation: "HealthKit shows \(Int(sleep.sleepEfficiency))% sleep efficiency — minimal awakenings. Uninterrupted sleep allows full parasympathetic restoration."
                    ), 0.75))
                }

                // Good deep sleep
                if let deepMins = sleep.deepSleepMinutes, sleep.totalSleepMinutes > 0 {
                    let deepPercent = Double(deepMins) / Double(sleep.totalSleepMinutes) * 100
                    if deepPercent >= 20 {
                        causes.append((ProbableCause(
                            cause: "Strong Deep Sleep",
                            confidence: "Contributing Factor",
                            explanation: "\(deepMins) minutes of deep sleep (\(Int(deepPercent))%). Deep sleep is when HRV peaks and the nervous system fully recovers."
                        ), 0.7))
                    }
                }
            }

            // Check positive tags
            if selectedTags.contains(where: { $0.name == "Good Sleep" }) {
                causes.append((ProbableCause(
                    cause: "Restful Night",
                    confidence: "High",
                    explanation: "You reported good sleep. Quality sleep is the #1 factor in HRV recovery."
                ), 0.85))
            }

            if selectedTags.contains(where: { $0.name == "Rest Day" }) {
                causes.append((ProbableCause(
                    cause: "Recovery Day",
                    confidence: "Moderate-High",
                    explanation: "Rest days allow accumulated training stress to dissipate, often resulting in HRV rebound."
                ), 0.7))
            }

            // Trend-based positive insight
            if stats.hasData && stats.sessionCount >= 5 {
                if let trend = stats.trend7Day, trend > 10 {
                    causes.append((ProbableCause(
                        cause: "Upward Trend",
                        confidence: "Pattern",
                        explanation: "Your HRV has been climbing over the past week (+\(String(format: "%.0f", trend))%). Whatever you're doing is working — keep it up."
                    ), 0.65))
                }

                // Day-over-day improvement
                if rmssd > stats.avgRMSSD * 1.2 {
                    causes.append((ProbableCause(
                        cause: "Above Your Baseline",
                        confidence: "Excellent",
                        explanation: "Today's HRV (\(Int(rmssd))ms) is \(String(format: "%.0f", ((rmssd - stats.avgRMSSD) / stats.avgRMSSD) * 100))% above your average. Your body is well-recovered and ready for challenges."
                    ), 0.8))
                }
            }

            // Low resting HR is positive
            if stats.hasData, let baselineHR = stats.baselineHR {
                let hrDrop = baselineHR - result.timeDomain.meanHR
                if hrDrop > 5 {
                    causes.append((ProbableCause(
                        cause: "Low Resting HR",
                        confidence: "Good Sign",
                        explanation: "Resting HR is \(String(format: "%.0f", hrDrop)) bpm below your baseline — indicates strong parasympathetic activity and cardiovascular efficiency."
                    ), 0.6))
                }
            }

            // If we have good insights, return them
            if !causes.isEmpty {
                causes.sort { $0.weight > $1.weight }
                return Array(causes.prefix(3).map { $0.cause })
            }

            // No specific positive factors identified
            return []
        }

        // === SEVERE ANOMALY DETECTION (highest priority - emergency-level deviations) ===
        if stats.hasData && stats.sessionCount >= 3 {
            let deviationPercent = ((rmssd - stats.avgRMSSD) / stats.avgRMSSD) * 100

            // Catastrophic drop: >50% below average is a medical-grade warning
            if deviationPercent < -50 {
                causes.append((ProbableCause(
                    cause: "Severe HRV Crash",
                    confidence: "Critical",
                    explanation: "Your HRV (\(Int(rmssd))ms) is \(String(format: "%.0f", abs(deviationPercent)))% below your average (\(String(format: "%.0f", stats.avgRMSSD))ms). This level of suppression indicates a serious stressor — likely acute illness, severe sleep deprivation, or extreme physical/emotional strain. Consider staying home and monitoring for symptoms."
                ), 0.99))
            }
            // Major drop: 30-50% below average
            else if deviationPercent < -30 {
                causes.append((ProbableCause(
                    cause: "Major HRV Drop",
                    confidence: "Very High",
                    explanation: "Your HRV is \(String(format: "%.0f", abs(deviationPercent)))% below your baseline (\(Int(rmssd))ms vs \(String(format: "%.0f", stats.avgRMSSD))ms average). This significant deviation suggests your body is under substantial stress. Take it very easy today."
                ), 0.92))
            }

            // Also check HR elevation relative to baseline
            if let baselineHR = stats.baselineHR {
                let hrElevation = result.timeDomain.meanHR - baselineHR
                if hrElevation > 8 && rmssd < stats.avgRMSSD * 0.8 {
                    causes.append((ProbableCause(
                        cause: "Elevated HR + Low HRV",
                        confidence: "High",
                        explanation: "Your resting HR is \(String(format: "%.0f", hrElevation)) bpm above baseline while HRV is suppressed. This combination is a strong indicator of immune activation, illness onset, or severe fatigue."
                    ), 0.85))
                }
            }
        }

        // === TAG-BASED CAUSES (highest priority - user told us!) ===

        // Alcohol tag - known to suppress HRV
        if selectedTags.contains(where: { $0.name == "Alcohol" }) {
            let conf = rmssd < 30 ? "Very High" : "High"
            let boost = rmssd < 30 ? 0.95 : 0.85
            causes.append((ProbableCause(
                cause: "Alcohol Consumption",
                confidence: conf,
                explanation: "You tagged alcohol. Even moderate drinking suppresses HRV for 24-48 hours by disrupting sleep architecture and increasing sympathetic tone."
            ), boost))
        } else if let alcoholImpact = tagImpact["Alcohol"], alcoholImpact > 0.3 {
            // Historical pattern: alcohol tag correlated with low HRV
            let dayOfWeek = Calendar.current.component(.weekday, from: session.startDate)
            if dayOfWeek == 1 || dayOfWeek == 7 { // Weekend
                causes.append((ProbableCause(
                    cause: "Possible Alcohol Effect",
                    confidence: "Moderate",
                    explanation: "Your past readings with the alcohol tag averaged \(Int(alcoholImpact * 100))% lower HRV. Weekend timing + low reading suggests this might be a factor."
                ), 0.55))
            }
        }

        // Poor sleep tag
        if selectedTags.contains(where: { $0.name == "Poor Sleep" }) {
            let conf = dfa > 1.15 ? "Very High" : "High"
            let boost = dfa > 1.15 ? 0.92 : 0.82
            causes.append((ProbableCause(
                cause: "Poor Sleep Quality",
                confidence: conf,
                explanation: "You tagged poor sleep. Sleep debt is one of the strongest suppressors of HRV. Your DFA α1 pattern confirms reduced recovery."
            ), boost))
        }

        // Late meal tag
        if selectedTags.contains(where: { $0.name == "Late Meal" }) {
            causes.append((ProbableCause(
                cause: "Late Night Eating",
                confidence: "Moderate-High",
                explanation: "You tagged a late meal. Digestion during sleep elevates metabolism and heart rate, reducing vagal tone and HRV."
            ), 0.7))
        }

        // Caffeine tag (late caffeine)
        if selectedTags.contains(where: { $0.name == "Caffeine" }) {
            causes.append((ProbableCause(
                cause: "Caffeine Effect",
                confidence: "Moderate",
                explanation: "You tagged caffeine. Caffeine's half-life is 5-6 hours—late consumption can disrupt deep sleep even if you fall asleep fine."
            ), 0.6))
        }

        // Travel tag
        if selectedTags.contains(where: { $0.name == "Travel" }) {
            causes.append((ProbableCause(
                cause: "Travel Stress / Jet Lag",
                confidence: "Moderate-High",
                explanation: "You tagged travel. Travel disrupts circadian rhythm, sleep, and hydration—all of which lower HRV."
            ), 0.75))
        }

        // Illness tag
        if selectedTags.contains(where: { $0.name == "Illness" }) {
            causes.append((ProbableCause(
                cause: "Active Illness",
                confidence: "Very High",
                explanation: "You tagged illness. Your immune system is active, which dramatically increases sympathetic tone and suppresses HRV."
            ), 0.98))
        }

        // Menstrual tag
        if selectedTags.contains(where: { $0.name == "Menstrual" }) {
            causes.append((ProbableCause(
                cause: "Menstrual Cycle Phase",
                confidence: "Moderate",
                explanation: "You tagged menstrual. HRV naturally varies across the cycle, often dipping during menstruation due to hormonal shifts."
            ), 0.6))
        }

        // Stressed tag
        if selectedTags.contains(where: { $0.name == "Stressed" }) {
            let conf = lfhf > 2.5 ? "Very High" : "High"
            let boost = lfhf > 2.5 ? 0.9 : 0.8
            causes.append((ProbableCause(
                cause: "Psychological Stress",
                confidence: conf,
                explanation: "You tagged feeling stressed. Your LF/HF ratio confirms elevated sympathetic activity consistent with mental/emotional load."
            ), boost))
        }

        // Post-exercise tag
        if selectedTags.contains(where: { $0.name == "Post-Exercise" }) {
            let conf = rmssd < 30 ? "High" : "Moderate"
            causes.append((ProbableCause(
                cause: "Exercise Recovery",
                confidence: conf,
                explanation: "You tagged post-exercise. HRV is suppressed for 24-72 hours after intense training while your body repairs and adapts."
            ), rmssd < 30 ? 0.85 : 0.65))
        }

        // === HEALTHKIT SLEEP DATA (authoritative when available) ===
        if let sleep = healthKitSleep {
            // Short sleep duration
            if sleep.totalSleepMinutes < 360 && sleep.totalSleepMinutes > 0 { // Less than 6 hours
                let conf = sleep.totalSleepMinutes < 300 ? "Very High" : "High"
                let weight = sleep.totalSleepMinutes < 300 ? 0.92 : 0.82
                let hours = Double(sleep.totalSleepMinutes) / 60.0
                causes.append((ProbableCause(
                    cause: "Insufficient Sleep",
                    confidence: conf,
                    explanation: "HealthKit shows only \(String(format: "%.1f", hours)) hours of sleep. Research shows HRV drops significantly with less than 7 hours. This is likely the primary factor."
                ), weight))
            }

            // Poor sleep efficiency
            if sleep.sleepEfficiency < 80 && sleep.inBedMinutes > 300 {
                let conf = sleep.sleepEfficiency < 70 ? "High" : "Moderate-High"
                let weight = sleep.sleepEfficiency < 70 ? 0.78 : 0.65
                causes.append((ProbableCause(
                    cause: "Fragmented Sleep",
                    confidence: conf,
                    explanation: "HealthKit shows \(Int(sleep.sleepEfficiency))% sleep efficiency with \(sleep.awakeMinutes) minutes awake. Fragmented sleep reduces HRV even when total time is adequate."
                ), weight))
            }

            // Low deep sleep (if available from Apple Watch)
            if let deepMins = sleep.deepSleepMinutes, deepMins < 45 && sleep.totalSleepMinutes > 300 {
                let deepPercent = Double(deepMins) / Double(sleep.totalSleepMinutes) * 100
                if deepPercent < 10 {
                    causes.append((ProbableCause(
                        cause: "Low Deep Sleep",
                        confidence: "Moderate-High",
                        explanation: "Only \(deepMins) minutes of deep sleep (\(Int(deepPercent))%). Deep sleep is when HRV-restoring parasympathetic activity peaks. Alcohol, late meals, and stress reduce deep sleep."
                    ), 0.7))
                }
            }

            // Lots of awake time
            if sleep.awakeMinutes > 30 && rmssd < 40 {
                causes.append((ProbableCause(
                    cause: "Frequent Awakenings",
                    confidence: "Moderate",
                    explanation: "HealthKit recorded \(sleep.awakeMinutes) minutes awake during sleep. Each awakening interrupts recovery cycles."
                ), 0.55))
            }

            // === SLEEP TREND INSIGHTS ===
            if let trends = sleepTrendStats, trends.nightsAnalyzed >= 3 {
                let avgHours = trends.averageSleepMinutes / 60.0
                let tonightHours = Double(sleep.totalSleepMinutes) / 60.0

                // Compare tonight to recent average
                let sleepDiffPercent = trends.averageSleepMinutes > 0 ?
                    ((Double(sleep.totalSleepMinutes) - trends.averageSleepMinutes) / trends.averageSleepMinutes) * 100 : 0

                // Tonight significantly below average
                if sleepDiffPercent < -20 && rmssd < 45 {
                    causes.append((ProbableCause(
                        cause: "Below Your Sleep Average",
                        confidence: "High",
                        explanation: "Tonight's \(String(format: "%.1f", tonightHours))h is \(Int(abs(sleepDiffPercent)))% below your 7-day average of \(String(format: "%.1f", avgHours))h. Consistently getting less sleep than usual impacts HRV."
                    ), 0.75))
                }

                // Declining sleep trend
                if trends.trend == .declining && rmssd < 40 {
                    causes.append((ProbableCause(
                        cause: "Declining Sleep Pattern",
                        confidence: "Moderate-High",
                        explanation: "Your sleep duration has been trending downward over the past week (avg \(trends.averageSleepFormatted)). Cumulative sleep debt suppresses HRV even before you feel tired."
                    ), 0.72))
                }

                // Tonight much better than average (for positive insights)
                if sleepDiffPercent > 20 && isGoodReading {
                    causes.append((ProbableCause(
                        cause: "Above Your Sleep Average",
                        confidence: "High",
                        explanation: "Tonight's \(String(format: "%.1f", tonightHours))h is \(Int(sleepDiffPercent))% above your recent average. Extra sleep pays immediate dividends in HRV recovery."
                    ), 0.78))
                }

                // Improving sleep trend (positive)
                if trends.trend == .improving && isGoodReading {
                    causes.append((ProbableCause(
                        cause: "Improving Sleep Pattern",
                        confidence: "Moderate-High",
                        explanation: "Your sleep has been improving over the past week. Consistent sleep improvements compound - expect HRV to continue rising if you maintain this pattern."
                    ), 0.7))
                }
            }
        }

        // === METRIC-BASED CAUSES (when no tags explain it) ===

        // Physical illness / immune response detection using HISTORICAL PATTERNS
        if !selectedTags.contains(where: { $0.name == "Illness" }) {
            let illnessSignals = detectIllnessPattern()

            if illnessSignals.consecutiveDeclines >= 3 && rmssd < 35 && stress > 200 {
                causes.append((ProbableCause(
                    cause: "Likely Getting Sick",
                    confidence: "High",
                    explanation: "Your HRV has declined for \(illnessSignals.consecutiveDeclines) consecutive days (\(String(format: "%.0f", illnessSignals.totalDeclinePercent))% total drop). This pattern strongly suggests your immune system is fighting something. Monitor closely for symptoms."
                ), 0.88))
            } else if illnessSignals.consecutiveDeclines >= 2 && (rmssd < 30 || illnessSignals.hrElevated) {
                var explanation = "Your HRV has dropped for \(illnessSignals.consecutiveDeclines) days in a row"
                if illnessSignals.hrElevated {
                    explanation += " and your resting HR is elevated (+\(String(format: "%.0f", illnessSignals.hrIncrease)) bpm)"
                }
                explanation += ". This often precedes illness symptoms by 1-2 days."
                causes.append((ProbableCause(
                    cause: "Possible Illness Coming On",
                    confidence: "Moderate-High",
                    explanation: explanation
                ), 0.72))
            } else if rmssd < 25 && stress > 250 {
                causes.append((ProbableCause(
                    cause: "Possible Immune Response",
                    confidence: "High",
                    explanation: "Very low HRV + high stress often precedes illness by 1-2 days. Monitor for symptoms."
                ), 0.75))
            } else if illnessSignals.hrElevated && stress > 200 && rmssd < 40 {
                causes.append((ProbableCause(
                    cause: "Elevated Resting HR",
                    confidence: "Moderate",
                    explanation: "Your resting HR is \(String(format: "%.0f", illnessSignals.hrIncrease)) bpm above your average. Combined with elevated stress, this can indicate your body is fighting something or under significant strain."
                ), 0.55))
            } else if rmssd < 30 && stress > 220 {
                causes.append((ProbableCause(
                    cause: "Possible Illness Coming On",
                    confidence: "Moderate",
                    explanation: "This pattern sometimes appears before cold/flu symptoms manifest."
                ), 0.45))
            }
        }

        // Mental/emotional stress (only if not already tagged)
        if !selectedTags.contains(where: { $0.name == "Stressed" }) {
            if lfhf > 3.0 && stress > 200 {
                causes.append((ProbableCause(
                    cause: "Unidentified Stress",
                    confidence: "Moderate-High",
                    explanation: "High sympathetic activation without tagged cause. Consider what might be weighing on you mentally."
                ), 0.65))
            }
        }

        // Sleep deprivation (only if not already tagged)
        if !selectedTags.contains(where: { $0.name == "Poor Sleep" }) {
            if rmssd < 30 && dfa > 1.15 {
                causes.append((ProbableCause(
                    cause: "Possible Sleep Debt",
                    confidence: "Moderate",
                    explanation: "Reduced HRV with elevated DFA α1 is characteristic of insufficient sleep."
                ), 0.55))
            }
        }

        // Overtraining (only if not tagged post-exercise)
        if !selectedTags.contains(where: { $0.name == "Post-Exercise" }) {
            if rmssd < 35 && pnn50 < 10 && dfa > 1.1 {
                causes.append((ProbableCause(
                    cause: "Accumulated Training Load",
                    confidence: "Low-Moderate",
                    explanation: "If you've been training hard recently, your body may need extra recovery time."
                ), 0.4))
            }
        }

        // Dehydration / nutrition
        if rmssd < 35 && stress > 180 && lfhf < 2 {
            causes.append((ProbableCause(
                cause: "Dehydration or Fasting",
                confidence: "Low-Moderate",
                explanation: "Low HRV without strong sympathetic shift can indicate dehydration or low blood sugar."
            ), 0.35))
        }

        // === DAY OF WEEK PATTERNS ===
        if let dayImpact = calculateDayOfWeekImpact(), dayImpact.impact > 0.15 {
            // Only mention if it's a consistently bad day for them
            if dayImpact.isLowDay && rmssd < 40 {
                causes.append((ProbableCause(
                    cause: "\(dayImpact.dayName) Pattern",
                    confidence: "Low",
                    explanation: "Historically, your HRV tends to be \(Int(dayImpact.impact * 100))% lower on \(dayImpact.dayName)s. Consider your typical \(dayImpact.dayName == "Monday" ? "weekend" : "mid-week") activities."
                ), 0.3))
            }
        }

        // Sort by weight and return top 3
        causes.sort { $0.weight > $1.weight }
        return Array(causes.prefix(3).map { $0.cause })
    }

    /// Calculate how much each tag historically correlates with lower HRV
    private func calculateTagImpact() -> [String: Double] {
        var tagImpact: [String: Double] = [:]

        // Need at least 5 sessions for meaningful correlation
        guard recentSessions.count >= 5 else { return tagImpact }

        // Get baseline average RMSSD
        let allRMSSDs = recentSessions.compactMap { $0.analysisResult?.timeDomain.rmssd }
        guard !allRMSSDs.isEmpty else { return tagImpact }
        let baselineRMSSD = allRMSSDs.reduce(0, +) / Double(allRMSSDs.count)

        // For each tag type, calculate average RMSSD when tag was present
        for tag in ReadingTag.systemTags {
            let sessionsWithTag = recentSessions.filter { $0.tags.contains(where: { $0.name == tag.name }) }
            guard sessionsWithTag.count >= 2 else { continue }

            let taggedRMSSDs = sessionsWithTag.compactMap { $0.analysisResult?.timeDomain.rmssd }
            guard !taggedRMSSDs.isEmpty else { continue }

            let avgWithTag = taggedRMSSDs.reduce(0, +) / Double(taggedRMSSDs.count)
            let impact = (baselineRMSSD - avgWithTag) / baselineRMSSD  // Positive = tag lowers HRV

            if impact > 0.1 {  // Only track tags that meaningfully lower HRV
                tagImpact[tag.name] = impact
            }
        }

        return tagImpact
    }

    /// Calculate if certain days of week consistently show lower HRV
    private func calculateDayOfWeekImpact() -> (dayName: String, impact: Double, isLowDay: Bool)? {
        guard recentSessions.count >= 14 else { return nil }  // Need 2+ weeks

        let calendar = Calendar.current
        var dayAverages: [Int: [Double]] = [:]

        for session in recentSessions {
            guard let rmssd = session.analysisResult?.timeDomain.rmssd else { continue }
            let day = calendar.component(.weekday, from: session.startDate)
            dayAverages[day, default: []].append(rmssd)
        }

        // Need at least 2 readings per day to compare
        let validDays = dayAverages.filter { $0.value.count >= 2 }
        guard validDays.count >= 3 else { return nil }

        // Calculate overall average
        let allValues = validDays.values.flatMap { $0 }
        let overallAvg = allValues.reduce(0, +) / Double(allValues.count)

        // Find today's day and its impact
        let today = calendar.component(.weekday, from: session.startDate)
        guard let todayReadings = dayAverages[today], todayReadings.count >= 2 else { return nil }

        let todayAvg = todayReadings.reduce(0, +) / Double(todayReadings.count)
        let impact = (overallAvg - todayAvg) / overallAvg

        let dayNames = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return (dayNames[today], abs(impact), impact > 0)
    }

    /// Detect illness patterns from consecutive declining HRV and elevated HR
    private func detectIllnessPattern() -> (consecutiveDeclines: Int, totalDeclinePercent: Double, hrElevated: Bool, hrIncrease: Double) {
        // Need at least a few days of history
        guard recentSessions.count >= 3 else {
            return (0, 0, false, 0)
        }

        // Get recent sessions sorted by date (most recent first)
        let sortedSessions = recentSessions
            .filter { $0.analysisResult != nil }
            .sorted { $0.startDate > $1.startDate }

        guard sortedSessions.count >= 2 else {
            return (0, 0, false, 0)
        }

        // Count consecutive declining days
        var consecutiveDeclines = 0
        var previousRMSSD: Double? = nil
        var firstRMSSD: Double? = nil
        var lastRMSSD: Double? = nil

        for session in sortedSessions.prefix(7) {  // Look at last 7 days max
            guard let rmssd = session.analysisResult?.timeDomain.rmssd else { continue }

            if firstRMSSD == nil {
                firstRMSSD = rmssd
            }

            if let prev = previousRMSSD {
                // Is this day lower than the previous day (going back in time)?
                // So if today < yesterday < day before, that's consecutive declines
                if rmssd > prev {  // Previous day (earlier) was higher
                    consecutiveDeclines += 1
                    lastRMSSD = rmssd
                } else {
                    break  // Pattern broken
                }
            }
            previousRMSSD = rmssd
        }

        // Calculate total decline percentage
        var totalDeclinePercent = 0.0
        if let first = firstRMSSD, let last = lastRMSSD, last > 0 {
            totalDeclinePercent = ((last - first) / last) * 100  // Negative = decline
        }

        // Check if HR is elevated compared to baseline
        let currentHR = result.timeDomain.meanHR
        let recentHRs = sortedSessions.prefix(14).compactMap { $0.analysisResult?.timeDomain.meanHR }
        let avgHR = recentHRs.isEmpty ? currentHR : recentHRs.reduce(0, +) / Double(recentHRs.count)
        let hrIncrease = currentHR - avgHR
        let hrElevated = hrIncrease > 4  // 4+ bpm above average is notable

        return (consecutiveDeclines, abs(totalDeclinePercent), hrElevated, hrIncrease)
    }

    private var keyFindings: [String] {
        var findings: [String] = []

        let rmssd = result.timeDomain.rmssd
        let _ = result.timeDomain.sdnn  // Available for future use
        let stress = result.ansMetrics?.stressIndex
        let lfhf = result.frequencyDomain?.lfHfRatio
        let dfa = result.nonlinear.dfaAlpha1
        let pnn50 = result.timeDomain.pnn50
        let stats = trendStats

        // TREND & BASELINE COMPARISONS FIRST (most actionable insights)
        if stats.hasData {
            let rmssdPct = ((rmssd - stats.avgRMSSD) / stats.avgRMSSD) * 100

            // Compare to recent average
            if rmssdPct > 20 {
                findings.append("HRV is significantly higher than your average of \(String(format: "%.0f", stats.avgRMSSD))ms (+\(String(format: "%.0f", rmssdPct))%) — excellent recovery today")
            } else if rmssdPct > 10 {
                findings.append("HRV is above your recent average of \(String(format: "%.0f", stats.avgRMSSD))ms (+\(String(format: "%.0f", rmssdPct))%) — good recovery")
            } else if rmssdPct < -20 {
                findings.append("HRV is significantly below your average of \(String(format: "%.0f", stats.avgRMSSD))ms (\(String(format: "%.0f", rmssdPct))%) — recovery may be compromised")
            } else if rmssdPct < -10 {
                findings.append("HRV is below your average of \(String(format: "%.0f", stats.avgRMSSD))ms (\(String(format: "%.0f", rmssdPct))%) — not fully recovered")
            }

            // Compare to personal baseline
            if let baseline = stats.baselineRMSSD {
                let baselineDiff = ((rmssd - baseline) / baseline) * 100
                if baselineDiff > 15 {
                    findings.append("You're \(String(format: "%.0f", baselineDiff))% above your personal baseline — you're in great shape")
                } else if baselineDiff < -15 {
                    findings.append("You're \(String(format: "%.0f", abs(baselineDiff)))% below your personal baseline")
                }
            }

            // 7-day trend
            if let trend = stats.trend7Day {
                if trend > 10 {
                    findings.append("Your 7-day HRV trend is improving (+\(String(format: "%.0f", trend))%) — keep doing what you're doing!")
                } else if trend < -10 {
                    findings.append("Your 7-day HRV trend shows a decline (\(String(format: "%.0f", trend))%)")
                }
            }

            // HR comparison
            let hrDiff = result.timeDomain.meanHR - stats.avgHR
            if hrDiff > 5 {
                findings.append("Resting HR is elevated (+\(String(format: "%.0f", hrDiff)) bpm vs average) — possible stress or incomplete recovery")
            } else if hrDiff < -5 {
                findings.append("Resting HR is lower than average (\(String(format: "%.0f", abs(hrDiff))) bpm) — good cardiovascular state")
            }
        }

        // ABSOLUTE HRV ASSESSMENT (if no trend data, or as additional context)
        if findings.isEmpty {
            // Only show absolute if we don't have trend comparisons
            if rmssd >= 50 {
                findings.append("HRV is excellent at \(Int(rmssd))ms — strong parasympathetic activity")
            } else if rmssd >= 35 {
                findings.append("HRV is adequate at \(Int(rmssd))ms — normal recovery capacity")
            } else if rmssd >= 25 {
                findings.append("HRV is reduced at \(Int(rmssd))ms — recovery may be incomplete")
            } else {
                findings.append("HRV is low at \(Int(rmssd))ms — indicates significant physiological stress")
            }
        }

        // Stress finding
        // Scale: <50 low/relaxed, 50-150 normal, 150-300 elevated, >300 high
        if let s = stress {
            if s > 300 {
                findings.append("Stress index is high (\(Int(s))) - significant physiological load")
            } else if s > 150 {
                findings.append("Stress index is elevated (\(Int(s))) - moderate strain present")
            } else if s > 50 {
                findings.append("Stress index is normal (\(Int(s))) - within typical resting range")
            } else {
                findings.append("Stress index is low (\(Int(s))) - very relaxed state")
            }
        }

        // ANS balance
        if let ratio = lfhf {
            if ratio > 3 {
                findings.append("Strong sympathetic dominance (LF/HF \(String(format: "%.1f", ratio))) - fight-or-flight active")
            } else if ratio < 0.5 {
                findings.append("Parasympathetic dominance (LF/HF \(String(format: "%.1f", ratio))) - deep recovery state")
            } else if ratio >= 0.8 && ratio <= 1.5 {
                findings.append("Balanced autonomic state (LF/HF \(String(format: "%.1f", ratio)))")
            }
        }

        // DFA finding
        if let alpha = dfa {
            if alpha > 1.2 {
                findings.append("DFA α1 is elevated (\(String(format: "%.2f", alpha))) - suggests fatigue")
            } else if alpha >= 0.75 && alpha <= 1.0 {
                findings.append("DFA α1 is optimal (\(String(format: "%.2f", alpha))) - healthy heart rhythm complexity")
            }
        }

        // pNN50 finding (only if notable)
        if pnn50 < 5 {
            findings.append("Very low beat-to-beat variation (pNN50 \(Int(pnn50))%) - vagal tone suppressed")
        } else if pnn50 > 30 {
            findings.append("Strong beat-to-beat variation (pNN50 \(Int(pnn50))%) - excellent vagal activity")
        }

        // HealthKit sleep insights
        if let sleep = healthKitSleep, sleep.totalSleepMinutes > 0 {
            let hours = Double(sleep.totalSleepMinutes) / 60.0
            let isGoodHRV = rmssd >= 40 || (stats.hasData && rmssd >= stats.avgRMSSD * 0.95)
            let isExcellentHRV = stats.hasData && rmssd > stats.avgRMSSD * 1.1

            if sleep.totalSleepMinutes < 300 { // Less than 5 hours
                if isExcellentHRV {
                    findings.append("Remarkable: Excellent HRV despite only \(String(format: "%.1f", hours))h sleep — your recovery capacity is impressive")
                } else if isGoodHRV {
                    findings.append("Solid HRV despite \(String(format: "%.1f", hours))h sleep — you're handling the short night well")
                } else {
                    findings.append("Short sleep (\(String(format: "%.1f", hours))h) per HealthKit — likely a major factor in reduced HRV")
                }
            } else if sleep.totalSleepMinutes >= 420 && isExcellentHRV {
                findings.append("Great combo: \(String(format: "%.1f", hours))h sleep + elevated HRV — fully recovered")
            }

            // Sleep efficiency insight
            if sleep.sleepEfficiency >= 92 {
                findings.append("Sleep efficiency \(Int(sleep.sleepEfficiency))% — nearly uninterrupted rest")
            } else if sleep.sleepEfficiency < 75 && sleep.inBedMinutes > 360 {
                findings.append("Low sleep efficiency (\(Int(sleep.sleepEfficiency))%) — \(sleep.awakeMinutes) min awake during the night")
            }

            // Sleep trend insights
            if let trends = sleepTrendStats, trends.nightsAnalyzed >= 3 {
                let avgHours = trends.averageSleepMinutes / 60.0
                let tonightHours = Double(sleep.totalSleepMinutes) / 60.0
                let sleepDiffPercent = trends.averageSleepMinutes > 0 ?
                    ((Double(sleep.totalSleepMinutes) - trends.averageSleepMinutes) / trends.averageSleepMinutes) * 100 : 0

                // Pattern recognition
                switch trends.trend {
                case .declining:
                    findings.append("Sleep trending down over past \(trends.nightsAnalyzed) nights (avg \(String(format: "%.1f", avgHours))h) — watch for cumulative fatigue")
                case .improving:
                    if isGoodHRV {
                        findings.append("Sleep improving over past week — your body is responding positively")
                    }
                case .stable:
                    if avgHours >= 7 && isGoodHRV {
                        findings.append("Consistent \(String(format: "%.1f", avgHours))h average sleep supporting steady HRV")
                    }
                case .insufficient:
                    break
                }

                // Tonight vs average comparison
                if abs(sleepDiffPercent) > 25 {
                    if sleepDiffPercent > 25 {
                        findings.append("Tonight's \(String(format: "%.1f", tonightHours))h is \(Int(sleepDiffPercent))% above your recent average")
                    } else {
                        findings.append("Tonight's \(String(format: "%.1f", tonightHours))h is \(Int(abs(sleepDiffPercent)))% below your \(String(format: "%.1f", avgHours))h average")
                    }
                }
            }
        }

        return findings
    }

    private var actionableSteps: [String] {
        var steps: [String] = []

        let score = computeDiagnosticScore()
        let rmssd = result.timeDomain.rmssd
        let stress = result.ansMetrics?.stressIndex ?? 150
        let lfhf = result.frequencyDomain?.lfHfRatio ?? 1.0
        let stats = trendStats

        // Sleep awareness from HealthKit
        let isShortSleep = (healthKitSleep?.totalSleepMinutes ?? 0) > 0 && (healthKitSleep?.totalSleepMinutes ?? 500) < 300
        let isGoodSleep = (healthKitSleep?.totalSleepMinutes ?? 0) >= 420
        let isFragmented = (healthKitSleep?.awakeMinutes ?? 0) > 30
        let sleepFormatted: String = {
            guard let sleep = healthKitSleep, sleep.totalSleepMinutes > 0 else { return "" }
            let hours = sleep.totalSleepMinutes / 60
            let mins = sleep.totalSleepMinutes % 60
            return hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
        }()

        // Trend-aware recommendations
        if stats.hasData {
            let rmssdPct = ((rmssd - stats.avgRMSSD) / stats.avgRMSSD) * 100

            // If improving trend, acknowledge it
            if let trend = stats.trend7Day, trend > 10 {
                steps.append("Your improving trend suggests your current routine is working well")
            }

            // If significantly above average
            if rmssdPct > 15 && score >= 70 {
                steps.append("This is a great day to push yourself — you have extra capacity")
            }

            // If declining trend
            if let trend = stats.trend7Day, trend < -10 {
                steps.append("Consider what changed in the past week — sleep, stress, training load?")
            }
        }

        // Score-based recommendations with sleep awareness
        if score >= 80 {
            steps.append("Great day for high-intensity training or challenging activities")
            steps.append("Your body has capacity for physical and mental demands")
            if isGoodSleep {
                steps.append("Good sleep is supporting your recovery — maintain this pattern")
            }
        } else if score >= 60 {
            steps.append("Moderate activity is fine — listen to your body")
            if isShortSleep {
                steps.append("Prioritize getting more sleep tonight (\(sleepFormatted) is insufficient)")
            } else {
                steps.append("Stay hydrated and maintain good sleep habits")
            }
        } else if score >= 40 {
            steps.append("Prioritize rest and recovery today")
            steps.append("Light movement like walking is better than intense exercise")
            if isShortSleep {
                steps.append("Aim for 7-9 hours of sleep tonight (you got \(sleepFormatted))")
            }
            if isFragmented {
                steps.append("Address sleep quality — avoid screens before bed, keep room cool and dark")
            }
            if lfhf > 2.5 {
                steps.append("Try 5-10 minutes of slow breathing (4s in, 6s out) to activate parasympathetic")
            }
            if stress > 200 {
                steps.append("Consider what stressors you can reduce or delegate today")
            }
        } else {
            steps.append("Take it easy — your body is signaling it needs recovery")
            if isShortSleep {
                steps.append("Your short sleep (\(sleepFormatted)) needs to be addressed — make sleep the priority")
            } else {
                steps.append("Monitor for illness symptoms over the next 24-48 hours")
            }
            if rmssd < 25 {
                steps.append("If you feel unwell, consider staying home and resting")
            }
            steps.append("Ensure adequate hydration and nutrition")
            if isFragmented {
                steps.append("Focus on uninterrupted sleep — avoid alcohol, caffeine after noon")
            } else {
                steps.append("Aim for extra sleep tonight (8-9+ hours)")
            }
        }

        return steps
    }

    private func balanceColor(_ ratio: Double?) -> Color {
        guard let r = ratio else { return AppTheme.textTertiary }
        if r < 0.5 { return AppTheme.mist }
        if r < 2.0 { return AppTheme.sage }
        if r < 3.0 { return AppTheme.softGold }
        return AppTheme.terracotta
    }

    // MARK: - Tags

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tags")
                .font(.headline)
                .foregroundColor(AppTheme.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ReadingTag.systemTags) { tag in
                        TagChip(
                            tag: tag,
                            isSelected: selectedTags.contains(tag),
                            onTap: { toggleTag(tag) }
                        )
                    }
                }
            }
        }
        .zenCard()
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notes")
                .font(.headline)
                .foregroundColor(AppTheme.textPrimary)

            TextField("How did you sleep? Any observations...", text: $notes, axis: .vertical)
                .padding(12)
                .background(AppTheme.sectionTint)
                .cornerRadius(AppTheme.smallCornerRadius)
                .lineLimit(3...5)
        }
        .zenCard()
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 12) {
            // Primary row: Export PDF and Export RR
            HStack(spacing: 12) {
                Button {
                    exportPDF()
                } label: {
                    if isGeneratingPDF {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Generating...")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label("Export PDF", systemImage: "doc.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.zenSecondary)
                .disabled(isGeneratingPDF)

                if hasRawData {
                    Button {
                        exportRRData()
                    } label: {
                        Label("Export RR", systemImage: "waveform.path")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.zenSecondary)
                }
            }

            // Re-analyze row (only if we have raw data and handler)
            if hasRawData, onReanalyze != nil {
                Button {
                    showingReanalyzeConfirmation = true
                } label: {
                    if isReanalyzing {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Analyzing...")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label("Re-analyze", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.zenSecondary)
                .disabled(isReanalyzing)
            }

            // Secondary row: Discard/Done and Delete (if available)
            HStack(spacing: 12) {
                Button(action: {
                    // Save tags/notes before dismissing if callback provided
                    onUpdateTags?(Array(selectedTags), notes.isEmpty ? nil : notes)
                    onDiscard()
                }) {
                    Label(onDelete != nil ? "Done" : "Discard", systemImage: onDelete != nil ? "checkmark" : "xmark")
                        .frame(maxWidth: .infinity)
                        .foregroundColor(onDelete != nil ? AppTheme.textPrimary : AppTheme.terracotta)
                }
                .buttonStyle(.zenSecondary)

                if onDelete != nil {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                            .foregroundColor(AppTheme.terracotta)
                    }
                    .buttonStyle(.zenSecondary)
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Window Selection Method

    private var windowSelectionMethodSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "scope")
                    .foregroundColor(AppTheme.primary)
                Text("Analysis Window Method")
                    .font(.headline)
                    .foregroundColor(AppTheme.textPrimary)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(WindowSelectionMethod.allCases, id: \.self) { method in
                        Button {
                            if selectedMethod != method {
                                selectedMethod = method
                                if method != .custom {
                                    reanalyzeWithMethod(method)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if let icon = method.icon {
                                    Image(systemName: icon)
                                        .font(.caption2)
                                }
                                Text(method.displayName)
                                    .font(.caption.bold())
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedMethod == method ? AppTheme.primary : AppTheme.sectionTint)
                            .foregroundColor(selectedMethod == method ? .white : AppTheme.textPrimary)
                            .cornerRadius(16)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text(selectedMethod.tooltip)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .zenCard()
    }

    // MARK: - PDF Loading Overlay

    private var pdfLoadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Generating PDF...")
                    .font(.headline)
                    .foregroundColor(.white)
            }
            .padding(40)
            .background(AppTheme.cardBackground.opacity(0.95))
            .cornerRadius(16)
        }
    }

    // MARK: - Helpers

    private func toggleTag(_ tag: ReadingTag) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
    }

    private func exportPDF() {
        isGeneratingPDF = true
        Task {
            await exportPDFAsync()
            await MainActor.run {
                isGeneratingPDF = false
            }
        }
    }

    private func exportPDFAsync() async {
        // Create a session copy with the analysis result attached
        // Use displaySession/displayResult to include any reanalyzed data
        var sessionForExport = displaySession
        sessionForExport.analysisResult = displayResult

        debugLog("[MorningResultsView] Generating PDF...")
        debugLog("[MorningResultsView] Session has analysisResult: \(sessionForExport.analysisResult != nil)")
        debugLog("[MorningResultsView] Session has rrSeries: \(sessionForExport.rrSeries != nil)")
        debugLog("[MorningResultsView] HealthKit sleep data: \(healthKitSleep?.totalSleepMinutes ?? 0) min")

        // Convert HealthKit sleep data to PDF generator format
        let sleepData: PDFReportGenerator.SleepData?
        if let hkSleep = healthKitSleep, hkSleep.totalSleepMinutes > 0 {
            sleepData = PDFReportGenerator.SleepData(from: hkSleep)
        } else {
            sleepData = nil
        }

        // Convert sleep trend data
        let sleepTrend: PDFReportGenerator.SleepTrendData?
        if let hkTrend = sleepTrendStats, hkTrend.nightsAnalyzed > 0 {
            sleepTrend = PDFReportGenerator.SleepTrendData(from: hkTrend)
        } else {
            sleepTrend = nil
        }

        // Fetch HealthKit HR samples for accurate nadir
        let healthKitHR: (mean: Double, min: Double, max: Double, nadirTime: Date)?
        do {
            let recordingEnd = session.endDate ?? session.startDate.addingTimeInterval(session.duration ?? 28800)
            healthKitHR = try await healthKit.calculateHRStats(from: session.startDate, to: recordingEnd)
            debugLog("[MorningResultsView] Fetched HealthKit HR: nadir=\(healthKitHR?.min ?? 0), max=\(healthKitHR?.max ?? 0)")
        } catch {
            debugLog("[MorningResultsView] Failed to fetch HealthKit HR: \(error)")
            healthKitHR = nil
        }

        let generator = PDFReportGenerator()
        if let url = generator.generateReportURL(for: sessionForExport,
                                                  sleepData: sleepData,
                                                  sleepTrend: sleepTrend,
                                                  recentSessions: recentSessions,
                                                  healthKitHR: healthKitHR) {
            debugLog("[MorningResultsView] PDF generated at: \(url.path)")
            // Verify file exists and has content
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int {
                debugLog("[MorningResultsView] PDF file size: \(size) bytes")
            }
            await MainActor.run {
                exportURL = IdentifiableURL(url: url)
            }
        } else {
            debugLog("[MorningResultsView] PDF generation failed - check session data")
        }
    }

    // MARK: - Re-analysis

    private func performReanalysis() {
        guard let onReanalyze = onReanalyze else { return }
        isReanalyzing = true

        Task {
            if let newSession = await onReanalyze(displaySession, selectedMethod) {
                await MainActor.run {
                    reanalyzedSession = newSession
                    isReanalyzing = false
                }
            } else {
                await MainActor.run {
                    isReanalyzing = false
                }
            }
        }
    }

    private func reanalyzeWithMethod(_ method: WindowSelectionMethod) {
        guard let onReanalyze = onReanalyze else { return }
        isReanalyzing = true

        Task {
            if let newSession = await onReanalyze(displaySession, method) {
                await MainActor.run {
                    reanalyzedSession = newSession
                    isReanalyzing = false
                }
            } else {
                await MainActor.run {
                    isReanalyzing = false
                }
            }
        }
    }

    // MARK: - Export RR Data

    private func exportRRData() {
        guard let series = displaySession.rrSeries else {
            debugLog("[MorningResultsView] ERROR: No rrSeries in displaySession")
            return
        }

        debugLog("[MorningResultsView] Exporting RR data: \(series.points.count) points")

        var csv = "# FlowRecovery RR Export\n"
        csv += "# Session Date: \(displaySession.startDate)\n"
        csv += "# Series Start: \(series.startDate)\n"
        csv += "# Total Points: \(series.points.count)\n"
        csv += "# Duration (ms): \(series.durationMs)\n"
        if let result = displaySession.analysisResult {
            csv += "# Window Start Index: \(result.windowStart)\n"
            csv += "# Window End Index: \(result.windowEnd)\n"
            csv += "# Window Start Ms: \(result.windowStartMs ?? -1)\n"
            csv += "# Window End Ms: \(result.windowEndMs ?? -1)\n"
            csv += "# RMSSD: \(result.timeDomain.rmssd)\n"
        }
        csv += "#\n"
        csv += "timestamp_ms,rr_ms,hr_bpm\n"
        for point in series.points {
            let hr = 60000.0 / Double(point.rr_ms)
            csv += "\(point.t_ms),\(point.rr_ms),\(String(format: "%.1f", hr))\n"
        }

        // Write to temp file
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let dateStr = formatter.string(from: displaySession.startDate)
        let filename = "FlowRecovery_RR_\(dateStr).csv"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        do {
            try csv.write(to: tempURL, atomically: true, encoding: .utf8)
            debugLog("[MorningResultsView] RR data exported to: \(tempURL.path)")
            exportURL = IdentifiableURL(url: tempURL)
        } catch {
            debugLog("[MorningResultsView] Failed to write RR data: \(error)")
        }
    }

    private func readinessLabel(_ score: Double) -> String {
        // Score is on 1-10 scale, convert to 0-100 for label
        RecoveryScoreCalculator.label(for: score * 10)
    }

    private func readinessColor(_ score: Double) -> Color {
        AppTheme.readinessColor(score)
    }

    private func readinessInterpretation(_ score: Double) -> String {
        // Score is on 1-10 scale, convert to 0-100 for message
        RecoveryScoreCalculator.message(for: score * 10)
    }

    private func balanceInterpretation(_ ratio: Double?) -> String {
        guard let r = ratio else { return "—" }
        if r < 0.5 { return "Parasympathetic" }
        if r < 2.0 { return "Balanced" }
        return "Sympathetic"
    }
}

// MARK: - Supporting Views

private struct HeroMetricCard: View {
    let title: String
    let value: Double
    let unit: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.body)
                    .foregroundColor(color)
            }

            VStack(spacing: 2) {
                Text(String(format: "%.0f", value))
                    .font(.system(.title2, design: .rounded).bold())
                    .foregroundColor(color)
                Text(unit)
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }

            Text(title)
                .font(.caption.bold())
                .foregroundColor(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
        .shadow(color: AppTheme.cardShadow, radius: AppTheme.cardShadowRadius, x: 0, y: 2)
    }
}

private struct MetricCell: View {
    let label: String
    let value: String
    @State private var showingInfo = false

    var body: some View {
        Button {
            showingInfo = true
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 2) {
                    Text(value)
                        .font(.system(.subheadline, design: .rounded).bold())
                        .foregroundColor(AppTheme.textPrimary)
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundColor(AppTheme.textTertiary)
                }
                Text(label)
                    .font(.caption2)
                    .foregroundColor(AppTheme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(AppTheme.sectionTint)
            .cornerRadius(AppTheme.smallCornerRadius)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingInfo) {
            MetricExplanationPopover(metric: label)
        }
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(AppTheme.primary)
            Text(title)
                .font(.subheadline.bold())
                .foregroundColor(AppTheme.textPrimary)
        }
    }
}

// MARK: - Metric Explanation Popover

private struct MetricExplanationPopover: View {
    let metric: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(metricInfo.fullName)
                    .font(.headline)
                    .foregroundColor(AppTheme.textPrimary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppTheme.textTertiary)
                }
            }

            Text(metricInfo.description)
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)

            Divider()

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                    .font(.caption)
                Text(metricInfo.interpretation)
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }
            .padding(8)
            .background(Color.yellow.opacity(0.1))
            .cornerRadius(8)
        }
        .padding()
        .frame(width: 300)
        .presentationCompactAdaptation(.popover)
    }

    private var metricInfo: (fullName: String, description: String, interpretation: String) {
        switch metric {
        // Time Domain
        case "Mean RR":
            return (
                "Mean RR Interval",
                "The average time between successive heartbeats in milliseconds. Inversely related to heart rate.",
                "Higher values = slower heart rate. 800-1000ms is typical at rest (60-75 bpm). Athletes may see 1000-1200ms."
            )
        case "SDNN":
            return (
                "Standard Deviation of NN Intervals",
                "Measures overall heart rate variability. Reflects both sympathetic and parasympathetic activity over the measurement period.",
                "Healthy range: 50-100ms for adults. Lower values may indicate chronic stress or health issues. Increases with fitness."
            )
        case "RMSSD":
            return (
                "Root Mean Square of Successive Differences",
                "The primary HRV metric. Measures beat-to-beat variation and strongly reflects parasympathetic (rest-and-digest) nervous system activity.",
                "Higher is generally better. Age-dependent ranges: 20s-30s: 40-80ms, 40s-50s: 25-50ms, 60+: 15-35ms. Athletes often higher."
            )
        case "pNN50":
            return (
                "Percentage of NN50",
                "The percentage of successive RR intervals that differ by more than 50ms. Like RMSSD, it reflects parasympathetic (vagal) activity.",
                "Higher values (5-25%) indicate greater parasympathetic activity and recovery. Very low values (<2%) suggest autonomic suppression."
            )
        case "SDSD":
            return (
                "Standard Deviation of Successive Differences",
                "Measures the variability of successive RR interval differences. Closely related to RMSSD and reflects short-term HRV.",
                "Higher values indicate greater beat-to-beat variability. Similar interpretation to RMSSD."
            )
        case "HR Range":
            return (
                "Heart Rate Range",
                "The difference between minimum and maximum heart rate during the recording. Indicates the span of HR variation.",
                "Wider range during rest may indicate arousals or movement. Narrow range suggests stable, restful state."
            )
        case "Mean HR":
            return (
                "Mean Heart Rate",
                "Your average heart rate across the entire measurement period in beats per minute.",
                "Resting HR varies by fitness. 60-80 bpm typical for adults. Athletes: 50-60 bpm. Lower generally indicates better fitness."
            )
        case "SD HR":
            return (
                "Heart Rate Standard Deviation",
                "The standard deviation of heart rate values. Measures how much your heart rate fluctuated during the recording.",
                "Higher values indicate more HR variation. At rest, 5-15 bpm is typical."
            )
        case "HRV TI":
            return (
                "HRV Triangular Index",
                "Derived from the histogram of RR intervals (total beats / peak bin). A geometric measure of overall HRV that's robust to artifacts.",
                "Typical range: 15-40. Higher values indicate greater variability. Less sensitive to individual artifacts than time-domain metrics."
            )

        // Frequency Domain
        case "VLF":
            return (
                "Very Low Frequency Power (≤0.04 Hz)",
                "Power in the very low frequency band. Associated with thermoregulation, hormonal fluctuations, and long-term regulatory mechanisms.",
                "Requires longer recordings (>5 min) to be meaningful. Reduced VLF has been associated with inflammation and poor health outcomes."
            )
        case "LF":
            return (
                "Low Frequency Power (0.04-0.15 Hz)",
                "Power in the low frequency band. Reflects a mix of sympathetic and parasympathetic activity, including baroreceptor activity.",
                "Context-dependent. Higher at rest may indicate good autonomic function. During stress, reflects sympathetic activation."
            )
        case "HF":
            return (
                "High Frequency Power (0.15-0.4 Hz)",
                "Power in the high frequency band, strongly associated with parasympathetic (vagal) activity and respiratory sinus arrhythmia.",
                "Higher is generally better at rest. Typical range: 200-3000 ms². Decreases with stress, exercise, and sympathetic activation."
            )
        case "Total Power":
            return (
                "Total Spectral Power",
                "The sum of all frequency band powers (VLF + LF + HF). Represents overall autonomic activity.",
                "Higher values indicate greater overall HRV. Typical range: 1000-8000 ms². Decreases with age and stress."
            )
        case "LF n.u.":
            return (
                "Low Frequency (Normalized Units)",
                "LF power as a percentage of total LF+HF power. Removes the influence of VLF and normalizes for comparison.",
                "Typical range: 30-70%. Higher values suggest relative sympathetic predominance."
            )
        case "HF n.u.":
            return (
                "High Frequency (Normalized Units)",
                "HF power as a percentage of total LF+HF power. Removes VLF influence and normalizes for comparison.",
                "Typical range: 30-70%. Higher values suggest relative parasympathetic predominance and better recovery."
            )
        case "LF/HF":
            return (
                "LF/HF Ratio",
                "The ratio of low-frequency to high-frequency power. Often used as an indicator of sympathovagal balance.",
                "Balanced: 0.5-2.0. Higher ratios indicate sympathetic dominance (stress). Lower ratios indicate parasympathetic dominance (recovery)."
            )

        // Nonlinear
        case "SD1":
            return (
                "Poincaré SD1 (Short-term)",
                "Standard deviation perpendicular to the line of identity in the Poincaré plot. Measures short-term, beat-to-beat variability.",
                "Strongly correlated with RMSSD and parasympathetic activity. Typical range: 20-70ms. Higher indicates better vagal tone."
            )
        case "SD2":
            return (
                "Poincaré SD2 (Long-term)",
                "Standard deviation along the line of identity in the Poincaré plot. Measures longer-term variability patterns.",
                "Reflects overall HRV including sympathetic influences. Typical range: 50-150ms."
            )
        case "SD1/SD2":
            return (
                "Poincaré SD1/SD2 Ratio",
                "The ratio of short-term to long-term variability. Indicates the balance between rapid parasympathetic and slower autonomic influences.",
                "Typical range: 0.2-0.5. Low ratios suggest reduced parasympathetic modulation."
            )
        case "DFA α1":
            return (
                "DFA Alpha-1 (Short-term Scaling)",
                "Detrended Fluctuation Analysis over 4-16 beats. Measures fractal correlation properties and heart rhythm complexity.",
                "Optimal at rest: 0.75-1.0. >1.2: fatigue/stress. <0.75: high vagal activity. Used to assess aerobic fitness zones."
            )
        case "DFA α2":
            return (
                "DFA Alpha-2 (Long-term Scaling)",
                "Detrended Fluctuation Analysis over 16-64 beats. Measures longer-range fractal correlations in heart rhythm.",
                "Less studied than α1. Values around 1.0 suggest healthy long-range correlations."
            )
        case "α1 R²":
            return (
                "DFA Alpha-1 R-squared",
                "The coefficient of determination for the DFA α1 calculation. Indicates how well the fractal model fits your data.",
                "Higher is better. R² > 0.95 indicates reliable α1 measurement. Lower values suggest noisy data or artifacts."
            )
        case "SampEn":
            return (
                "Sample Entropy",
                "Measures the complexity and regularity of the heart rhythm. Lower values indicate more predictable, regular patterns.",
                "Typical range: 1.0-2.0. Higher values indicate more complexity (healthy). Very low (<0.5) may indicate pathology."
            )
        case "ApEn":
            return (
                "Approximate Entropy",
                "Similar to Sample Entropy but includes self-matches. Measures the predictability of the heart rhythm time series.",
                "Typical range: 0.8-1.5. Higher indicates more complexity. Lower values suggest more regular, predictable rhythm."
            )

        // ANS Indexes
        case "Stress Index":
            return (
                "Baevsky's Stress Index",
                "Derived from the geometric properties of RR interval distribution. Reflects sympathetic nervous system load.",
                "Low (<100): Relaxed. Moderate (100-200): Normal. Elevated (200-300): Stressed. High (>300): Significant strain."
            )
        case "PNS Index":
            return (
                "Parasympathetic Nervous System Index",
                "A composite index of parasympathetic (rest-and-digest) activity derived from multiple HRV metrics.",
                "Range typically -3 to +3. Positive values indicate parasympathetic dominance (recovery). Negative indicates suppression."
            )
        case "SNS Index":
            return (
                "Sympathetic Nervous System Index",
                "A composite index of sympathetic (fight-or-flight) activity derived from HRV and stress markers.",
                "Range typically -3 to +3. Positive values indicate sympathetic activation (stress/arousal). Negative indicates relaxation."
            )
        case "Resp Rate":
            return (
                "Respiratory Rate",
                "Breathing rate estimated from the high-frequency oscillations in heart rate (respiratory sinus arrhythmia).",
                "Normal rest: 12-20 breaths/min. Slower breathing promotes HRV. Very slow (<6) or fast (>20) may affect HRV accuracy."
            )
        case "Readiness":
            return (
                "Recovery Readiness Score",
                "A composite score (1-10) estimating your body's readiness for physical and mental demands.",
                "8-10: Excellent, ready for intensity. 6-8: Good, normal capacity. 4-6: Moderate, consider lighter activity. <4: Rest needed."
            )

        // Data Quality
        case "Clean Beats":
            return (
                "Clean Beat Count",
                "The number of normal (non-artifact) heartbeats used in the analysis after artifact removal.",
                "More beats = more reliable analysis. Minimum ~120 for basic metrics, 300+ ideal for frequency analysis."
            )
        case "Artifacts":
            return (
                "Artifact Percentage",
                "The percentage of detected ectopic beats, missed beats, and noise removed from analysis.",
                "<5%: Excellent quality. 5-10%: Good. 10-20%: Acceptable. >20%: Results may be unreliable."
            )

        default:
            return (
                metric,
                "This metric helps assess your heart rate variability and autonomic nervous system balance.",
                "Tap for more details about this metric in the Settings > Metric Explanations section."
            )
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
        let isUp = diff > 0
        let isGood = higherIsBetter ? isUp : !isUp

        if isGood {
            return isUp ? "arrow.up.right" : "arrow.down.right"
        } else {
            return isUp ? "arrow.up.right" : "arrow.down.right"
        }
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

// MARK: - Poincaré Plot View

struct PoincarePlotView: View {
    let session: HRVSession
    let result: HRVAnalysisResult

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard let series = session.rrSeries else { return }
                let flags = session.artifactFlags ?? []

                // Get RR pairs
                var rrPairs: [(Double, Double)] = []
                let windowStart = result.windowStart
                let windowEnd = min(result.windowEnd, series.points.count)

                for i in windowStart..<(windowEnd - 1) {
                    let isArtifact1 = i < flags.count ? flags[i].isArtifact : false
                    let isArtifact2 = (i + 1) < flags.count ? flags[i + 1].isArtifact : false

                    if !isArtifact1 && !isArtifact2 {
                        let rr1 = Double(series.points[i].rr_ms)
                        let rr2 = Double(series.points[i + 1].rr_ms)
                        rrPairs.append((rr1, rr2))
                    }
                }

                guard !rrPairs.isEmpty else { return }

                // Find range
                let allRR = rrPairs.flatMap { [$0.0, $0.1] }
                let minRR = allRR.min() ?? 600
                let maxRR = allRR.max() ?? 1200
                let range = max(maxRR - minRR, 100)
                let padding = range * 0.15
                let plotMin = minRR - padding
                let plotMax = maxRR + padding

                let plotSize = min(size.width, size.height)
                let offsetX = (size.width - plotSize) / 2
                let offsetY = (size.height - plotSize) / 2

                func scale(_ value: Double) -> CGFloat {
                    let normalized = (value - plotMin) / (plotMax - plotMin)
                    return CGFloat(normalized) * plotSize
                }

                // Background
                let bgRect = CGRect(x: offsetX, y: offsetY, width: plotSize, height: plotSize)
                context.fill(Path(bgRect), with: .color(Color(.tertiarySystemGroupedBackground)))

                // Identity line
                var linePath = Path()
                linePath.move(to: CGPoint(x: offsetX, y: offsetY + plotSize))
                linePath.addLine(to: CGPoint(x: offsetX + plotSize, y: offsetY))
                context.stroke(linePath, with: .color(.gray.opacity(0.3)), lineWidth: 1)

                // SD1/SD2 ellipse
                let meanRR = allRR.reduce(0, +) / Double(allRR.count)
                let centerX = offsetX + scale(meanRR)
                let centerY = offsetY + plotSize - scale(meanRR)

                let sd1Px = CGFloat(result.nonlinear.sd1) * plotSize / CGFloat(plotMax - plotMin)
                let sd2Px = CGFloat(result.nonlinear.sd2) * plotSize / CGFloat(plotMax - plotMin)

                let ellipseTransform = CGAffineTransform.identity
                    .translatedBy(x: centerX, y: centerY)
                    .rotated(by: -.pi / 4)

                let ellipseRect = CGRect(x: -sd2Px, y: -sd1Px, width: sd2Px * 2, height: sd1Px * 2)
                var ellipsePath = Path(ellipseIn: ellipseRect)
                ellipsePath = ellipsePath.applying(ellipseTransform)

                context.fill(ellipsePath, with: .color(AppTheme.primary.opacity(0.15)))
                context.stroke(ellipsePath, with: .color(AppTheme.primary.opacity(0.5)), lineWidth: 2)

                // Points
                let maxPoints = 300
                let step = max(1, rrPairs.count / maxPoints)

                for i in stride(from: 0, to: rrPairs.count, by: step) {
                    let (rr1, rr2) = rrPairs[i]
                    let x = offsetX + scale(rr1)
                    let y = offsetY + plotSize - scale(rr2)

                    let dotPath = Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4))
                    context.fill(dotPath, with: .color(AppTheme.primary.opacity(0.6)))
                }
            }
        }
    }
}

// MARK: - Tachogram View

struct TachogramView: View {
    let session: HRVSession
    let result: HRVAnalysisResult

    @State private var touchLocation: CGPoint? = nil
    @State private var isDragging = false

    private let xAxisHeight: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let chartHeight = geo.size.height - xAxisHeight
            ZStack {
                VStack(spacing: 0) {
                    chartCanvas(size: CGSize(width: geo.size.width, height: chartHeight))
                        .frame(height: chartHeight)

                    xAxisLabels(width: geo.size.width)
                        .frame(height: xAxisHeight)
                }

                // Touch interaction overlay
                if let touch = touchLocation, isDragging {
                    Rectangle()
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 1, height: chartHeight)
                        .position(x: touch.x, y: chartHeight / 2)

                    if let (rr, time) = rrAtLocation(touch.x, size: CGSize(width: geo.size.width, height: chartHeight)) {
                        TachogramTooltip(value: String(format: "%.0f", rr), unit: "ms", time: time, color: AppTheme.primary)
                            .position(x: tooltipX(touch.x, width: geo.size.width), y: 30)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        touchLocation = value.location
                        isDragging = true
                    }
                    .onEnded { _ in
                        isDragging = false
                        touchLocation = nil
                    }
            )
        }
    }

    private func xAxisLabels(width: CGFloat) -> some View {
        guard let series = session.rrSeries else {
            return AnyView(EmptyView())
        }

        let windowStart = result.windowStart
        let windowEnd = min(result.windowEnd, series.points.count)
        guard windowEnd > windowStart else {
            return AnyView(EmptyView())
        }

        let startMs = series.points[windowStart].t_ms
        let endMs = series.points[windowEnd - 1].t_ms
        let durationMs = endMs - startMs

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        let labelCount = 5
        var labels: [(String, CGFloat)] = []

        for i in 0..<labelCount {
            let fraction = CGFloat(i) / CGFloat(labelCount - 1)
            let x = fraction * width
            let timeOffsetMs = Int64(Double(durationMs) * Double(fraction))
            let actualTime = series.absoluteTime(fromRelativeMs: startMs + timeOffsetMs)
            labels.append((formatter.string(from: actualTime), x))
        }

        return AnyView(
            ZStack {
                ForEach(0..<labels.count, id: \.self) { i in
                    Text(labels[i].0)
                        .font(.system(size: 9))
                        .foregroundColor(AppTheme.textTertiary)
                        .position(x: labels[i].1, y: 10)
                }
            }
        )
    }

    private func tooltipX(_ x: CGFloat, width: CGFloat) -> CGFloat {
        let padding: CGFloat = 50
        if x < padding { return padding }
        if x > width - padding { return width - padding }
        return x
    }

    private func rrAtLocation(_ x: CGFloat, size: CGSize) -> (Double, String)? {
        guard let series = session.rrSeries else { return nil }
        let flags = session.artifactFlags ?? []

        let windowStart = result.windowStart
        let windowEnd = min(result.windowEnd, series.points.count)
        guard windowEnd > windowStart else { return nil }

        let windowCount = windowEnd - windowStart
        let normalizedX = x / size.width
        let targetIndex = windowStart + Int(normalizedX * CGFloat(windowCount))

        guard targetIndex >= windowStart && targetIndex < windowEnd else { return nil }

        let point = series.points[targetIndex]
        let isArtifact = targetIndex < flags.count ? flags[targetIndex].isArtifact : false

        let rr = Double(point.rr_ms)
        let actualTime = series.absoluteTime(fromRelativeMs: point.t_ms)

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        let timeString = formatter.string(from: actualTime) + (isArtifact ? " (artifact)" : "")

        return (rr, timeString)
    }

    private func chartCanvas(size: CGSize) -> some View {
        Canvas { context, size in
            guard let series = session.rrSeries else { return }
            let flags = session.artifactFlags ?? []

            let windowStart = result.windowStart
            let windowEnd = min(result.windowEnd, series.points.count)
            guard windowEnd > windowStart else { return }

            // Get RR values
            var rrValues: [(Int, Double, Bool)] = []
            for i in windowStart..<windowEnd {
                let isArtifact = i < flags.count ? flags[i].isArtifact : false
                rrValues.append((i - windowStart, Double(series.points[i].rr_ms), isArtifact))
            }

            let minRR = rrValues.map { $0.1 }.min() ?? 600
            let maxRR = rrValues.map { $0.1 }.max() ?? 1200
            let range = max(maxRR - minRR, 50)

            let xScale = size.width / CGFloat(rrValues.count - 1)

            // Draw grid
            let gridColor = Color.gray.opacity(0.2)
            for i in 0...4 {
                let y = size.height * CGFloat(i) / 4
                var gridPath = Path()
                gridPath.move(to: CGPoint(x: 0, y: y))
                gridPath.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(gridPath, with: .color(gridColor), lineWidth: 0.5)
            }

            // Draw trace
            var path = Path()
            var first = true

            for (i, rr, _) in rrValues {
                let x = CGFloat(i) * xScale
                let normalized = (rr - minRR) / range
                let y = size.height - CGFloat(normalized) * size.height * 0.85 - size.height * 0.075

                if first {
                    path.move(to: CGPoint(x: x, y: y))
                    first = false
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            // Gradient fill under curve
            var fillPath = path
            fillPath.addLine(to: CGPoint(x: size.width, y: size.height))
            fillPath.addLine(to: CGPoint(x: 0, y: size.height))
            fillPath.closeSubpath()

            let gradient = Gradient(colors: [AppTheme.primary.opacity(0.3), AppTheme.primary.opacity(0.05)])
            context.fill(fillPath, with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            // Stroke line
            context.stroke(path, with: .color(AppTheme.primary), lineWidth: 1.5)
        }
    }
}

private struct TachogramTooltip: View {
    let value: String
    let unit: String
    let time: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.headline, design: .rounded).bold())
                    .foregroundColor(color)
                Text(unit)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Text(time)
                .font(.caption2.bold())
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
        )
    }
}

// MARK: - Frequency Bands View

struct FrequencyBandsView: View {
    let frequencyDomain: FrequencyDomainMetrics

    var body: some View {
        GeometryReader { geo in
            let total = frequencyDomain.totalPower
            let lfPct = total > 0 ? frequencyDomain.lf / total : 0
            let hfPct = total > 0 ? frequencyDomain.hf / total : 0
            let vlfPct = total > 0 ? (frequencyDomain.vlf ?? 0) / total : 0

            VStack(spacing: 8) {
                // Stacked bar
                HStack(spacing: 2) {
                    if vlfPct > 0.01 {
                        Rectangle()
                            .fill(Color.gray.opacity(0.5))
                            .frame(width: geo.size.width * CGFloat(vlfPct))
                    }

                    Rectangle()
                        .fill(AppTheme.primary)
                        .frame(width: geo.size.width * CGFloat(lfPct))

                    Rectangle()
                        .fill(AppTheme.secondary)
                        .frame(width: geo.size.width * CGFloat(hfPct))
                }
                .frame(height: 24)
                .cornerRadius(4)

                // Legend
                HStack(spacing: 20) {
                    if frequencyDomain.vlf != nil {
                        LegendItem(color: .gray.opacity(0.5), label: "VLF", value: String(format: "%.0f ms²", frequencyDomain.vlf ?? 0))
                    }
                    LegendItem(color: AppTheme.primary, label: "LF", value: String(format: "%.0f ms²", frequencyDomain.lf))
                    LegendItem(color: AppTheme.secondary, label: "HF", value: String(format: "%.0f ms²", frequencyDomain.hf))
                }
            }
        }
    }
}

private struct LegendItem: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.caption2.bold())
                    .foregroundColor(AppTheme.textPrimary)
                Text(value)
                    .font(.caption2)
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
    }
}

// MARK: - Analysis Insight Row

private struct AnalysisInsightRow: View {
    let icon: String
    let title: String
    let message: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(color)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundColor(AppTheme.textPrimary)
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - HR Stat Card

private struct HRStatCard: View {
    let title: String
    let value: Double
    var unit: String = "bpm"
    let color: Color
    @State private var showingInfo = false

    private var metricKey: String {
        if title == "SDNN" { return "SDNN" }
        return title
    }

    var body: some View {
        Button {
            showingInfo = true
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 2) {
                    Text(title)
                        .font(.caption2)
                        .foregroundColor(AppTheme.textTertiary)
                    if title == "SDNN" {
                        Image(systemName: "info.circle")
                            .font(.system(size: 8))
                            .foregroundColor(AppTheme.textTertiary)
                    }
                }
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(String(format: "%.0f", value))
                        .font(.system(.headline, design: .rounded).bold())
                        .foregroundColor(color)
                    Text(unit)
                        .font(.caption2)
                        .foregroundColor(AppTheme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(AppTheme.sectionTint)
            .cornerRadius(AppTheme.smallCornerRadius)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingInfo) {
            if title == "SDNN" {
                MetricExplanationPopover(metric: "SDNN")
            } else {
                HRStatExplanationPopover(statType: title)
            }
        }
    }
}

private struct HRStatExplanationPopover: View {
    let statType: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(statInfo.title)
                    .font(.headline)
                    .foregroundColor(AppTheme.textPrimary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppTheme.textTertiary)
                }
            }

            Text(statInfo.description)
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                    .font(.caption)
                Text(statInfo.interpretation)
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }
            .padding(8)
            .background(Color.yellow.opacity(0.1))
            .cornerRadius(8)
        }
        .padding()
        .frame(width: 280)
        .presentationCompactAdaptation(.popover)
    }

    private var statInfo: (title: String, description: String, interpretation: String) {
        switch statType {
        case "Min":
            return (
                "Minimum Heart Rate",
                "The lowest heart rate recorded during this session. Reflects your deepest point of rest or recovery.",
                "Lower minimum HR during rest often indicates good cardiovascular fitness. Athletes may see values in the 40s-50s."
            )
        case "Avg":
            return (
                "Average Heart Rate",
                "Your mean heart rate across the entire measurement period. A general indicator of overall cardiovascular load.",
                "Resting HR varies by age and fitness. 60-80 bpm is typical for adults. Athletes and fit individuals often see 50-60 bpm or lower."
            )
        case "Max":
            return (
                "Maximum Heart Rate",
                "The highest heart rate recorded during this session. May reflect brief moments of arousal or movement.",
                "During rest, max HR should be close to average. Large gaps between max and average may indicate arousals or movement during the reading."
            )
        default:
            return (
                statType,
                "A heart rate measurement from your session.",
                "Heart rate varies based on activity, stress, and fitness level."
            )
        }
    }
}

// MARK: - Readiness Explanation Popover

private struct ReadinessExplanationPopover: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recovery Readiness Score")
                    .font(.headline)
                    .foregroundColor(AppTheme.textPrimary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppTheme.textTertiary)
                }
            }

            Text("A composite score (1-10) combining multiple HRV metrics to estimate your body's readiness for physical and mental demands.")
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Score Ranges:")
                    .font(.caption.bold())
                    .foregroundColor(AppTheme.textPrimary)

                HStack(spacing: 8) {
                    Circle().fill(Color.green).frame(width: 10, height: 10)
                    Text("8-10: Excellent - ready for high intensity")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)
                }
                HStack(spacing: 8) {
                    Circle().fill(Color.blue).frame(width: 10, height: 10)
                    Text("6-8: Good - normal training capacity")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)
                }
                HStack(spacing: 8) {
                    Circle().fill(Color.yellow).frame(width: 10, height: 10)
                    Text("4-6: Moderate - consider lighter activity")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)
                }
                HStack(spacing: 8) {
                    Circle().fill(Color.orange).frame(width: 10, height: 10)
                    Text("1-4: Low - prioritize rest and recovery")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)
                }
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                    .font(.caption)
                Text("Based on RMSSD, stress index, DFA α1, and autonomic balance. Compare to your personal baseline for best insights.")
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }
            .padding(8)
            .background(Color.yellow.opacity(0.1))
            .cornerRadius(8)
        }
        .padding()
        .frame(width: 300)
        .presentationCompactAdaptation(.popover)
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
        case "High": return AppTheme.terracotta
        case "Moderate-High": return AppTheme.softGold
        case "Moderate": return AppTheme.mist
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

// MARK: - Heart Rate Chart View

struct HeartRateChartView: View {
    let session: HRVSession
    let result: HRVAnalysisResult

    @State private var touchLocation: CGPoint? = nil
    @State private var isDragging = false

    private let xAxisHeight: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let chartHeight = geo.size.height - xAxisHeight
            ZStack {
                VStack(spacing: 0) {
                    chartCanvas(size: CGSize(width: geo.size.width, height: chartHeight))
                        .frame(height: chartHeight)

                    xAxisLabels(width: geo.size.width)
                        .frame(height: xAxisHeight)
                }

                // Touch interaction overlay
                if let touch = touchLocation, isDragging {
                    Rectangle()
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 1, height: chartHeight)
                        .position(x: touch.x, y: chartHeight / 2)

                    if let (hr, time) = hrAtLocation(touch.x, size: CGSize(width: geo.size.width, height: chartHeight)) {
                        HRChartTooltip(value: String(format: "%.0f", hr), unit: "bpm", time: time, color: AppTheme.terracotta)
                            .position(x: tooltipX(touch.x, width: geo.size.width), y: 30)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        touchLocation = value.location
                        isDragging = true
                    }
                    .onEnded { _ in
                        isDragging = false
                        touchLocation = nil
                    }
            )
        }
    }

    private func xAxisLabels(width: CGFloat) -> some View {
        guard let series = session.rrSeries else {
            return AnyView(EmptyView())
        }

        let windowStart = result.windowStart
        let windowEnd = min(result.windowEnd, series.points.count)
        guard windowEnd > windowStart else {
            return AnyView(EmptyView())
        }

        let startMs = series.points[windowStart].t_ms
        let endMs = series.points[windowEnd - 1].t_ms
        let durationMs = endMs - startMs

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        let labelCount = 5
        var labels: [(String, CGFloat)] = []

        for i in 0..<labelCount {
            let fraction = CGFloat(i) / CGFloat(labelCount - 1)
            let x = fraction * width
            let timeOffsetMs = Int64(Double(durationMs) * Double(fraction))
            let actualTime = series.absoluteTime(fromRelativeMs: startMs + timeOffsetMs)
            labels.append((formatter.string(from: actualTime), x))
        }

        return AnyView(
            ZStack {
                ForEach(0..<labels.count, id: \.self) { i in
                    Text(labels[i].0)
                        .font(.system(size: 9))
                        .foregroundColor(AppTheme.textTertiary)
                        .position(x: labels[i].1, y: 10)
                }
            }
        )
    }

    private func tooltipX(_ x: CGFloat, width: CGFloat) -> CGFloat {
        let padding: CGFloat = 50
        if x < padding { return padding }
        if x > width - padding { return width - padding }
        return x
    }

    private func hrAtLocation(_ x: CGFloat, size: CGSize) -> (Double, String)? {
        guard let series = session.rrSeries else { return nil }
        let flags = session.artifactFlags ?? []

        let windowStart = result.windowStart
        let windowEnd = min(result.windowEnd, series.points.count)
        guard windowEnd > windowStart else { return nil }

        let windowCount = windowEnd - windowStart
        let normalizedX = x / size.width
        let targetIndex = windowStart + Int(normalizedX * CGFloat(windowCount))

        guard targetIndex >= windowStart && targetIndex < windowEnd else { return nil }

        let point = series.points[targetIndex]
        let isArtifact = targetIndex < flags.count ? flags[targetIndex].isArtifact : false

        let hr = 60000.0 / Double(point.rr_ms)
        let actualTime = series.absoluteTime(fromRelativeMs: point.t_ms)

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        let timeString = formatter.string(from: actualTime) + (isArtifact ? " (artifact)" : "")

        return (hr, timeString)
    }

    private func chartCanvas(size: CGSize) -> some View {
        Canvas { context, size in
            guard let series = session.rrSeries else { return }
            let flags = session.artifactFlags ?? []

            let windowStart = result.windowStart
            let windowEnd = min(result.windowEnd, series.points.count)
            guard windowEnd > windowStart else { return }

            // Convert RR to HR values
            var hrValues: [(Int, Double)] = []
            for i in windowStart..<windowEnd {
                let isArtifact = i < flags.count ? flags[i].isArtifact : false
                if !isArtifact {
                    let rr = Double(series.points[i].rr_ms)
                    let hr = 60000.0 / rr
                    hrValues.append((i - windowStart, hr))
                }
            }

            guard hrValues.count > 2 else { return }

            // Find range with some padding
            let minHR = hrValues.map { $0.1 }.min() ?? 50
            let maxHR = hrValues.map { $0.1 }.max() ?? 100
            let range = max(maxHR - minHR, 10)
            let paddedMin = minHR - range * 0.1
            let paddedMax = maxHR + range * 0.1
            let paddedRange = paddedMax - paddedMin

            // Draw grid lines
            let gridColor = Color.gray.opacity(0.2)
            let gridValues = [paddedMin, paddedMin + paddedRange * 0.25, paddedMin + paddedRange * 0.5, paddedMin + paddedRange * 0.75, paddedMax]

            for gridValue in gridValues {
                let y = size.height - CGFloat((gridValue - paddedMin) / paddedRange) * size.height
                var gridPath = Path()
                gridPath.move(to: CGPoint(x: 0, y: y))
                gridPath.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(gridPath, with: .color(gridColor), lineWidth: 0.5)
            }

            // Draw HR line
            let xScale = size.width / CGFloat(windowEnd - windowStart - 1)

            var path = Path()
            var first = true

            for (i, hr) in hrValues {
                let x = CGFloat(i) * xScale
                let normalized = (hr - paddedMin) / paddedRange
                let y = size.height - CGFloat(normalized) * size.height

                if first {
                    path.move(to: CGPoint(x: x, y: y))
                    first = false
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            // Gradient fill
            var fillPath = path
            if let lastPoint = hrValues.last {
                let lastX = CGFloat(lastPoint.0) * xScale
                fillPath.addLine(to: CGPoint(x: lastX, y: size.height))
                fillPath.addLine(to: CGPoint(x: 0, y: size.height))
                fillPath.closeSubpath()
            }

            let gradient = Gradient(colors: [AppTheme.terracotta.opacity(0.3), AppTheme.terracotta.opacity(0.05)])
            context.fill(fillPath, with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            // Stroke line
            context.stroke(path, with: .color(AppTheme.terracotta), lineWidth: 2)

            // Draw min/max/avg labels on right side
            let avgHR = hrValues.map { $0.1 }.reduce(0, +) / Double(hrValues.count)

            // Average line
            let avgY = size.height - CGFloat((avgHR - paddedMin) / paddedRange) * size.height
            var avgPath = Path()
            avgPath.move(to: CGPoint(x: 0, y: avgY))
            avgPath.addLine(to: CGPoint(x: size.width, y: avgY))
            context.stroke(avgPath, with: .color(AppTheme.terracotta.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
    }
}

private struct HRChartTooltip: View {
    let value: String
    let unit: String
    let time: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.headline, design: .rounded).bold())
                    .foregroundColor(color)
                Text(unit)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Text(time)
                .font(.caption2.bold())
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
        )
    }
}

// PDFPreviewView is defined in Sources/Views/Utilities/PDFPreviewView.swift

// MARK: - Identifiable URL Wrapper

private struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Collapsible Section

/// A reusable collapsible section with a title header and expandable content
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
