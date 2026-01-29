//
//  Copyright © 2024-2026 Chris Sharp. All rights reserved.
//

import Foundation
import Combine

/// ViewModel for MorningResultsView - manages state and business logic
@MainActor
final class MorningResultsViewModel: ObservableObject {

    // MARK: - Input

    let session: HRVSession
    let result: HRVAnalysisResult
    let recentSessions: [HRVSession]

    // MARK: - Published State

    @Published var selectedTags: Set<ReadingTag>
    @Published var notes: String
    @Published var reanalyzedSession: HRVSession?
    @Published var selectedMethod: WindowSelectionMethod
    @Published var isReanalyzing = false
    @Published var isGeneratingPDF = false
    @Published var healthKitSleep: HealthKitManager.SleepData?
    @Published var sleepTrendStats: HealthKitManager.SleepTrendStats?
    @Published var recoveryVitals: HealthKitManager.RecoveryVitals?
    @Published var liveTrainingContext: TrainingContext?
    @Published var error: Error?

    // MARK: - Computed Properties

    var displaySession: HRVSession {
        reanalyzedSession ?? session
    }

    var displayResult: HRVAnalysisResult {
        displaySession.analysisResult ?? result
    }

    var hasRawData: Bool {
        guard let series = displaySession.rrSeries else { return false }
        return !series.points.isEmpty
    }

    var compositeRecoveryScore: Double {
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

    var readinessScore: Double {
        RecoveryScoreCalculator.toTenScale(compositeRecoveryScore)
    }

    // MARK: - Services

    private let healthKit = HealthKitManager()
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(session: HRVSession, result: HRVAnalysisResult, recentSessions: [HRVSession] = []) {
        self.session = session
        self.result = result
        self.recentSessions = recentSessions
        self.selectedTags = Set(session.tags)
        self.notes = session.notes ?? ""
        self.selectedMethod = SettingsManager.shared.settings.defaultWindowSelectionMethod
    }

    // MARK: - Actions

    func loadHealthKitData() async {
        guard healthKit.isHealthKitAvailable else {
            debugLog("[MorningResultsVM] HealthKit not available")
            return
        }

        do {
            try await healthKit.requestAuthorization()
            await fetchSleepData()
            await fetchRecoveryVitals()
            await fetchTrainingContextIfNeeded()
        } catch {
            debugLog("[MorningResultsVM] HealthKit error: \(error)")
            self.error = error
        }
    }

    private func fetchSleepData() async {
        let recordingEnd = session.endDate ?? session.startDate.addingTimeInterval(session.duration ?? 28800)

        do {
            let sleep = try await healthKit.fetchSleepData(
                for: session.startDate,
                recordingEnd: recordingEnd,
                extendForDisplay: true
            )
            healthKitSleep = sleep

            let recentSleep = try await healthKit.fetchSleepTrend(days: 7)
            sleepTrendStats = healthKit.analyzeSleepTrend(from: recentSleep)
        } catch {
            debugLog("[MorningResultsVM] Sleep fetch error: \(error)")
        }
    }

    private func fetchRecoveryVitals() async {
        recoveryVitals = await healthKit.fetchRecoveryVitals()
    }

    private func fetchTrainingContextIfNeeded() async {
        guard displayResult.trainingContext == nil,
              SettingsManager.shared.settings.enableTrainingLoadIntegration,
              !SettingsManager.shared.settings.isOnTrainingBreak else {
            return
        }

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

        liveTrainingContext = TrainingContext(
            atl: metrics.atl,
            ctl: metrics.ctl,
            tsb: metrics.tsb,
            yesterdayTrimp: metrics.todayTrimp,
            vo2Max: load.vo2Max,
            daysSinceHardWorkout: load.daysSinceHardWorkout,
            recentWorkouts: recentWorkouts.isEmpty ? nil : recentWorkouts
        )
    }

    func reanalyze(using method: WindowSelectionMethod, handler: ((HRVSession, WindowSelectionMethod) async -> HRVSession?)?) async {
        guard let handler = handler else { return }

        isReanalyzing = true
        defer { isReanalyzing = false }

        if let newSession = await handler(displaySession, method) {
            reanalyzedSession = newSession
        }
    }

    func updateTags(_ tags: Set<ReadingTag>, notes: String?, handler: (([ReadingTag], String?) -> Void)?) {
        selectedTags = tags
        if let notes = notes {
            self.notes = notes
        }
        handler?(Array(tags), notes)
    }
}
