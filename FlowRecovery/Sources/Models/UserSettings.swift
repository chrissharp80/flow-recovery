//
//  Copyright © 2024-2026 Chris Sharp. All rights reserved.
//
//  This source code is provided for reference and verification purposes only.
//  Unauthorized copying, modification, distribution, or use of this code,
//  via any medium, is strictly prohibited without prior written permission.
//
//  For licensing inquiries, contact the copyright holder.
//

import Foundation

/// User fitness level for personalized baselines
enum FitnessLevel: String, Codable, CaseIterable, Identifiable {
    case sedentary = "Sedentary"
    case lightlyActive = "Lightly Active"
    case moderatelyActive = "Moderately Active"
    case active = "Active"
    case veryActive = "Very Active"
    case athlete = "Athlete"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .sedentary:
            return "Little to no regular exercise"
        case .lightlyActive:
            return "Light exercise 1-3 days/week"
        case .moderatelyActive:
            return "Moderate exercise 3-5 days/week"
        case .active:
            return "Hard exercise 6-7 days/week"
        case .veryActive:
            return "Very hard daily exercise or physical job"
        case .athlete:
            return "Professional or competitive athlete"
        }
    }

    /// Expected RMSSD range baseline multiplier
    var rmssdBaselineMultiplier: Double {
        switch self {
        case .sedentary: return 0.8
        case .lightlyActive: return 0.9
        case .moderatelyActive: return 1.0
        case .active: return 1.1
        case .veryActive: return 1.2
        case .athlete: return 1.3
        }
    }
}

/// Temperature display unit preference
enum TemperatureUnit: String, Codable, CaseIterable, Identifiable {
    case celsius = "Celsius"
    case fahrenheit = "Fahrenheit"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .celsius: return "°C"
        case .fahrenheit: return "°F"
        }
    }

    /// Convert Celsius deviation to display value
    func convert(_ celsiusDeviation: Double) -> Double {
        switch self {
        case .celsius: return celsiusDeviation
        case .fahrenheit: return celsiusDeviation * 9.0 / 5.0  // Deviation conversion (not absolute)
        }
    }
}

/// User settings for personalized insights and preferences
struct UserSettings: Codable {
    var customTags: [ReadingTag]
    var defaultMorningTime: Date
    var birthday: Date?
    var fitnessLevel: FitnessLevel?
    var biologicalSex: BiologicalSex?
    var notificationsEnabled: Bool
    var morningReminderEnabled: Bool
    var morningReminderTime: Date
    var preferredRecordingDuration: Int // seconds
    var showAdvancedMetrics: Bool
    var baselineRMSSD: Double?
    var baselineHR: Double?
    /// User's typical/target sleep duration in hours (default 8.0)
    /// Used to calculate sleep completion ratio for effective recovery
    var typicalSleepHours: Double
    /// Default window selection method for HRV analysis (defaults to consolidatedRecovery for backward compatibility)
    var defaultWindowSelectionMethod: WindowSelectionMethod = .consolidatedRecovery

    // MARK: - Fitness Integration Settings

    /// Manual VO2max override (ml/kg/min) - use if you have actual lab-tested value
    /// HealthKit estimates are often inaccurate, so manual override takes priority
    var vo2MaxOverride: Double?

    /// Whether to use HealthKit's VO2max estimate as fallback when no override is set
    var useHealthKitVO2Max: Bool = false

    /// Whether to integrate recent workout data into readiness calculations
    var enableTrainingLoadIntegration: Bool = true

    /// Training break start date (injury, surgery, vacation) - hides training load display
    /// Does NOT affect calculations - just hides the UI during recovery
    var trainingBreakStartDate: Date?

    /// Training break end date (optional) - if nil, break continues until manually ended
    var trainingBreakEndDate: Date?

    /// Optional reason for training break (e.g. "Surgery", "Vacation", "Sick")
    var trainingBreakReason: String?

    /// Temperature unit preference (Celsius or Fahrenheit)
    var temperatureUnit: TemperatureUnit = .fahrenheit

    /// Whether user is currently on a training break (within date range)
    var isOnTrainingBreak: Bool {
        guard let start = trainingBreakStartDate else { return false }
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let startDay = calendar.startOfDay(for: start)

        // Must be on or after start date
        guard today >= startDay else { return false }

        // If end date set, must be on or before end date
        if let end = trainingBreakEndDate {
            let endDay = calendar.startOfDay(for: end)
            return today <= endDay
        }

        return true // No end date = ongoing
    }

    // MARK: - Coding Keys and Migration

    enum CodingKeys: String, CodingKey {
        case customTags, defaultMorningTime, birthday, fitnessLevel, biologicalSex
        case notificationsEnabled, morningReminderEnabled, morningReminderTime
        case preferredRecordingDuration, showAdvancedMetrics
        case baselineRMSSD, baselineHR, typicalSleepHours, defaultWindowSelectionMethod
        case vo2MaxOverride, useHealthKitVO2Max, enableTrainingLoadIntegration
        case trainingBreakStartDate, trainingBreakEndDate, trainingBreakReason
        case temperatureUnit
    }

    /// Custom decoder that provides defaults for missing fields - prevents data loss on schema changes
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Required fields with fallbacks
        customTags = (try? container.decode([ReadingTag].self, forKey: .customTags)) ?? []
        defaultMorningTime = (try? container.decode(Date.self, forKey: .defaultMorningTime))
            ?? Calendar.current.date(from: DateComponents(hour: 7, minute: 0)) ?? Date()
        birthday = try? container.decode(Date.self, forKey: .birthday)
        fitnessLevel = try? container.decode(FitnessLevel.self, forKey: .fitnessLevel)
        biologicalSex = try? container.decode(BiologicalSex.self, forKey: .biologicalSex)
        notificationsEnabled = (try? container.decode(Bool.self, forKey: .notificationsEnabled)) ?? false
        morningReminderEnabled = (try? container.decode(Bool.self, forKey: .morningReminderEnabled)) ?? false
        morningReminderTime = (try? container.decode(Date.self, forKey: .morningReminderTime))
            ?? Calendar.current.date(from: DateComponents(hour: 7, minute: 0)) ?? Date()
        preferredRecordingDuration = (try? container.decode(Int.self, forKey: .preferredRecordingDuration)) ?? 120
        showAdvancedMetrics = (try? container.decode(Bool.self, forKey: .showAdvancedMetrics)) ?? false
        baselineRMSSD = try? container.decode(Double.self, forKey: .baselineRMSSD)
        baselineHR = try? container.decode(Double.self, forKey: .baselineHR)
        typicalSleepHours = (try? container.decode(Double.self, forKey: .typicalSleepHours)) ?? 8.0
        defaultWindowSelectionMethod = (try? container.decode(WindowSelectionMethod.self, forKey: .defaultWindowSelectionMethod)) ?? .consolidatedRecovery

        // Fitness integration (new fields)
        vo2MaxOverride = try? container.decode(Double.self, forKey: .vo2MaxOverride)
        useHealthKitVO2Max = (try? container.decode(Bool.self, forKey: .useHealthKitVO2Max)) ?? false
        enableTrainingLoadIntegration = (try? container.decode(Bool.self, forKey: .enableTrainingLoadIntegration)) ?? true
        trainingBreakStartDate = try? container.decode(Date.self, forKey: .trainingBreakStartDate)
        trainingBreakEndDate = try? container.decode(Date.self, forKey: .trainingBreakEndDate)
        trainingBreakReason = try? container.decode(String.self, forKey: .trainingBreakReason)
        temperatureUnit = (try? container.decode(TemperatureUnit.self, forKey: .temperatureUnit)) ?? .fahrenheit
    }

    /// Typical sleep in minutes (for calculations)
    var typicalSleepMinutes: Double {
        typicalSleepHours * 60.0
    }

    /// Computed age from birthday
    var age: Int? {
        guard let birthday = birthday else { return nil }
        let calendar = Calendar.current
        let ageComponents = calendar.dateComponents([.year], from: birthday, to: Date())
        return ageComponents.year
    }

    enum BiologicalSex: String, Codable, CaseIterable, Identifiable {
        case male = "Male"
        case female = "Female"
        case other = "Other/Prefer not to say"

        var id: String { rawValue }
    }

    init() {
        self.customTags = []
        self.defaultMorningTime = Calendar.current.date(from: DateComponents(hour: 7, minute: 0)) ?? Date()
        self.notificationsEnabled = false
        self.morningReminderEnabled = false
        self.morningReminderTime = Calendar.current.date(from: DateComponents(hour: 7, minute: 0)) ?? Date()
        self.preferredRecordingDuration = 120
        self.showAdvancedMetrics = false
        self.typicalSleepHours = 8.0  // Default 8 hours, user should customize
        self.defaultWindowSelectionMethod = .consolidatedRecovery
    }

    /// All available tags (system + custom)
    var allTags: [ReadingTag] {
        ReadingTag.systemTags + customTags
    }

    /// Population baseline RMSSD by age (approximate values)
    var populationBaselineRMSSD: Double {
        guard let age = age else { return 35.0 }

        let baselineByAge: Double
        switch age {
        case ..<20: baselineByAge = 55.0
        case 20..<30: baselineByAge = 45.0
        case 30..<40: baselineByAge = 38.0
        case 40..<50: baselineByAge = 32.0
        case 50..<60: baselineByAge = 27.0
        case 60..<70: baselineByAge = 22.0
        default: baselineByAge = 18.0
        }

        let multiplier = fitnessLevel?.rmssdBaselineMultiplier ?? 1.0
        return baselineByAge * multiplier
    }
}

// MARK: - Settings Manager

final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var settings: UserSettings {
        didSet {
            save()
        }
    }

    private let fileManager = FileManager.default
    private let settingsURL: URL

    private init() {
        if let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            settingsURL = documentsPath.appendingPathComponent("user_settings.json")
        } else {
            // Fallback to temporary directory (should never happen on iOS)
            settingsURL = fileManager.temporaryDirectory.appendingPathComponent("user_settings.json")
            debugLog("[SettingsManager] WARNING: Using temporary directory as fallback")
        }
        settings = SettingsManager.load(from: settingsURL) ?? UserSettings()
    }

    private static func load(from url: URL) -> UserSettings? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(UserSettings.self, from: data)
        } catch {
            debugLog("Failed to load settings: \(error)")
            return nil
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: settingsURL)
        } catch {
            debugLog("Failed to save settings: \(error)")
        }
    }

    // MARK: - Custom Tag Management

    func addCustomTag(_ tag: ReadingTag) {
        guard !settings.customTags.contains(where: { $0.id == tag.id }) else { return }
        settings.customTags.append(tag)
    }

    func removeCustomTag(_ tag: ReadingTag) {
        settings.customTags.removeAll { $0.id == tag.id }
    }

    func updateCustomTag(_ tag: ReadingTag) {
        if let index = settings.customTags.firstIndex(where: { $0.id == tag.id }) {
            settings.customTags[index] = tag
        }
    }

    // MARK: - Baseline Management

    func updateBaseline(rmssd: Double?, hr: Double?) {
        if let rmssd = rmssd {
            settings.baselineRMSSD = rmssd
        }
        if let hr = hr {
            settings.baselineHR = hr
        }
    }

    func calculatePersonalBaseline(from sessions: [HRVSession]) {
        // Use morning readings from the last 7-14 days
        let calendar = Calendar.current
        let twoWeeksAgo = calendar.date(byAdding: .day, value: -14, to: Date()) ?? Date()

        let morningSessions = sessions.filter { session in
            guard session.state == .complete,
                  session.startDate >= twoWeeksAgo,
                  session.tags.contains(where: { $0.id == ReadingTag.morning.id })
            else { return false }
            return true
        }

        guard morningSessions.count >= 3 else { return }

        let rmssdValues = morningSessions.compactMap { $0.analysisResult?.timeDomain.rmssd }
        let hrValues = morningSessions.compactMap { $0.analysisResult?.timeDomain.meanHR }

        if !rmssdValues.isEmpty {
            settings.baselineRMSSD = rmssdValues.reduce(0, +) / Double(rmssdValues.count)
        }
        if !hrValues.isEmpty {
            settings.baselineHR = hrValues.reduce(0, +) / Double(hrValues.count)
        }
    }
}
