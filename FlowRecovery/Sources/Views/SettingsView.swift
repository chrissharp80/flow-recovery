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
import UIKit

// MARK: - Settings View

/// Settings view for app configuration
struct SettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var collector: RRCollector
    @State private var showingAddTag = false
    @State private var newTagName = ""
    @State private var newTagColor = Color.blue
    @State private var showingRecoveryAlert = false
    @State private var recoveryMessage = ""
    @State private var isRecovering = false
    @State private var exportedLogItem: ExportableURL?
    @State private var showingRepairAlert = false
    @State private var repairMessage = ""
    @State private var deletedSessionCount: Int = 0
    @FocusState private var isVO2MaxFieldFocused: Bool

    var body: some View {
        ZStack {
            // Keyboard dismiss layer - only active when field is focused
            if isVO2MaxFieldFocused {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isVO2MaxFieldFocused = false
                    }
                    .zIndex(1)
            }

            List {
                // Profile Section
                Section("Profile") {
                DatePicker(
                    "Birthday",
                    selection: birthdayBinding,
                    in: ...Date(),
                    displayedComponents: .date
                )

                if let age = settingsManager.settings.age {
                    HStack {
                        Text("Age")
                        Spacer()
                        Text("\(age) years")
                            .foregroundColor(.secondary)
                    }
                }

                Picker("Fitness Level", selection: fitnessBinding) {
                    Text("Not Set").tag(Optional<FitnessLevel>.none)
                    ForEach(FitnessLevel.allCases) { level in
                        Text(level.rawValue).tag(Optional(level))
                    }
                }

                Picker("Biological Sex", selection: sexBinding) {
                    Text("Not Set").tag(Optional<UserSettings.BiologicalSex>.none)
                    ForEach(UserSettings.BiologicalSex.allCases) { sex in
                        Text(sex.rawValue).tag(Optional(sex))
                    }
                }
            }

            // Sleep Settings
            Section {
                Picker("Typical Sleep", selection: $settingsManager.settings.typicalSleepHours) {
                    ForEach(Array(stride(from: 5.0, through: 10.0, by: 0.5)), id: \.self) { hours in
                        Text(formatSleepDuration(hours)).tag(hours)
                    }
                }
            } header: {
                Text("Sleep")
            } footer: {
                Text("Your typical sleep duration. Used to calculate effective recovery - shorter nights will show discounted HRV to reflect incomplete recovery.")
            }

            // Units Section
            Section {
                Picker("Temperature", selection: $settingsManager.settings.temperatureUnit) {
                    ForEach(TemperatureUnit.allCases) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
            } header: {
                Text("Units")
            }

            // Baseline Section
            Section {
                if let baseline = settingsManager.settings.baselineRMSSD {
                    HStack {
                        Text("Personal Baseline")
                        Spacer()
                        Text(String(format: "%.0f ms", baseline))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("No baseline calculated yet")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Population Baseline")
                    Spacer()
                    Text(String(format: "%.0f ms", settingsManager.settings.populationBaselineRMSSD))
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Baselines")
            } footer: {
                Text("Personal baseline is calculated from your morning readings. Population baseline is estimated from your age and fitness level.")
            }

            // Fitness Integration Section
            Section {
                // VO2max override
                HStack {
                    Text("VO2max Override")
                    Spacer()
                    TextField("", value: vo2MaxBinding, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .focused($isVO2MaxFieldFocused)
                    Text("ml/kg/min")
                        .foregroundColor(.secondary)
                }

                if settingsManager.settings.vo2MaxOverride != nil {
                    Button("Clear Override") {
                        settingsManager.settings.vo2MaxOverride = nil
                    }
                    .foregroundColor(.red)
                }

                Toggle("Use HealthKit VO2max", isOn: $settingsManager.settings.useHealthKitVO2Max)

                Toggle("Training Load Integration", isOn: $settingsManager.settings.enableTrainingLoadIntegration)

                // Training Break
                if settingsManager.settings.enableTrainingLoadIntegration {
                    if settingsManager.settings.trainingBreakStartDate != nil {
                        // Show current break info
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "bed.double.fill")
                                    .foregroundColor(.orange)
                                Text(settingsManager.settings.isOnTrainingBreak ? "On Break" : "Break Scheduled")
                                    .foregroundColor(.orange)
                                    .fontWeight(.medium)
                            }

                            DatePicker("From", selection: Binding(
                                get: { settingsManager.settings.trainingBreakStartDate ?? Date() },
                                set: { settingsManager.settings.trainingBreakStartDate = $0 }
                            ), displayedComponents: .date)
                            .font(.subheadline)

                            DatePicker("Until", selection: Binding(
                                get: { settingsManager.settings.trainingBreakEndDate ?? Calendar.current.date(byAdding: .day, value: 7, to: Date())! },
                                set: { settingsManager.settings.trainingBreakEndDate = $0 }
                            ), displayedComponents: .date)
                            .font(.subheadline)

                            TextField("Reason (optional)", text: Binding(
                                get: { settingsManager.settings.trainingBreakReason ?? "" },
                                set: { settingsManager.settings.trainingBreakReason = $0.isEmpty ? nil : $0 }
                            ))
                            .font(.subheadline)
                            .textFieldStyle(.roundedBorder)

                            Button("Clear Break") {
                                settingsManager.settings.trainingBreakStartDate = nil
                                settingsManager.settings.trainingBreakEndDate = nil
                                settingsManager.settings.trainingBreakReason = nil
                            }
                            .foregroundColor(.red)
                            .font(.subheadline)
                        }
                    } else {
                        Button {
                            // Default: today through 1 week
                            settingsManager.settings.trainingBreakStartDate = Date()
                            settingsManager.settings.trainingBreakEndDate = Calendar.current.date(byAdding: .day, value: 7, to: Date())
                        } label: {
                            Label("Schedule Training Break", systemImage: "bed.double")
                        }
                        .foregroundColor(.orange)
                    }
                }
            } header: {
                Text("Fitness Integration")
            } footer: {
                Text("Training break hides ATL/CTL during recovery (sick, surgery, vacation). Doesn't affect calculations - just hides the display.")
            }

            // Recording Settings
            Section("Recording") {
                Picker("Default Duration", selection: $settingsManager.settings.preferredRecordingDuration) {
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("3 minutes").tag(180)
                    Text("5 minutes").tag(300)
                }

                Toggle("Show Advanced Metrics", isOn: $settingsManager.settings.showAdvancedMetrics)
            }

            // Custom Tags Section
            Section {
                ForEach(settingsManager.settings.customTags) { tag in
                    HStack {
                        Circle()
                            .fill(tag.color)
                            .frame(width: 16, height: 16)
                        Text(tag.name)
                        Spacer()
                    }
                }
                .onDelete(perform: deleteCustomTag)

                Button {
                    showingAddTag = true
                } label: {
                    Label("Add Custom Tag", systemImage: "plus")
                }
            } header: {
                Text("Custom Tags")
            } footer: {
                Text("Create custom tags to categorize your readings beyond the built-in options.")
            }

            // Support Section - crash logs available in Release builds
            Section("Support") {
                if CrashLogManager.shared.hasPreviousCrash {
                    NavigationLink {
                        CrashLogView()
                    } label: {
                        HStack {
                            Label("Crash Report", systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Spacer()
                            Text("Available")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                } else {
                    HStack {
                        Label("Crash Report", systemImage: "checkmark.circle")
                        Spacer()
                        Text("No crashes")
                            .foregroundColor(.secondary)
                    }
                }
            }

            // About Section
            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.appVersionString)
                        .foregroundColor(.secondary)
                }

                NavigationLink {
                    MetricExplanationsView()
                } label: {
                    Text("Metric Explanations")
                }
            }

            // Data Management
            Section("Data") {
                NavigationLink {
                    ImportDataView()
                } label: {
                    Label("Import RR Data", systemImage: "square.and.arrow.down")
                }

                NavigationLink {
                    ExportDataView()
                } label: {
                    Label("Export Data", systemImage: "square.and.arrow.up")
                }

                // Recovery option - only show when H10 is connected
                if collector.polarManager.connectionState == .connected {
                    Button {
                        recoverRRData()
                    } label: {
                        HStack {
                            Label("Recover RR from Strap", systemImage: "arrow.clockwise.heart")
                            Spacer()
                            if isRecovering {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                    }
                    .disabled(isRecovering)
                }

                // Recovery from backup - find sessions with raw backups that aren't in archive
                NavigationLink {
                    LostSessionsView()
                } label: {
                    Label("Recover Lost Sessions", systemImage: "arrow.counterclockwise.circle")
                }
                .task {
                    // Check for deleted sessions count on background thread
                    if deletedSessionCount == 0 {
                        let collectorRef = collector
                        let count = await Task.detached {
                            await collectorRef.checkForDeletedSessions().count
                        }.value
                        deletedSessionCount = count
                    }
                }

                // Trash - view and manage intentionally deleted sessions
                NavigationLink {
                    TrashView()
                } label: {
                    HStack {
                        Label("Trash", systemImage: "trash")
                        Spacer()
                        if deletedSessionCount > 0 {
                            Text("\(deletedSessionCount)")
                                .foregroundColor(.secondary)
                        }
                    }
                }

            }

            // Debug Section - only available in DEBUG builds to protect user privacy
            #if DEBUG
            Section("Debug") {
                NavigationLink {
                    ArchiveDiagnosticsView()
                } label: {
                    Label("Archive Diagnostics", systemImage: "externaldrive.badge.questionmark")
                }

                NavigationLink {
                    DebugLogView()
                } label: {
                    HStack {
                        Label("View Logs (7 days)", systemImage: "doc.text.magnifyingglass")
                        Spacer()
                        Text("\(DebugLogger.shared.entries.count)")
                            .foregroundColor(.secondary)
                    }
                }

                NavigationLink {
                    ErrorCatalogView()
                } label: {
                    HStack {
                        Label("Error Catalog", systemImage: "exclamationmark.triangle.fill")
                        Spacer()
                        if DebugLogger.shared.errorCatalog.count > 0 {
                            Text("\(DebugLogger.shared.errorCatalog.count)")
                                .foregroundColor(.red)
                        }
                    }
                }

                Button {
                    exportDebugLogs()
                } label: {
                    Label("Export Logs", systemImage: "square.and.arrow.up")
                }

                Button(role: .destructive) {
                    DebugLogger.shared.clear()
                } label: {
                    Label("Clear Logs", systemImage: "trash")
                }

                Button {
                    repairArchive()
                } label: {
                    Label("Repair Archive", systemImage: "wrench.and.screwdriver")
                }
                .alert("Archive Repaired", isPresented: $showingRepairAlert) {
                    Button("OK") {}
                } message: {
                    Text(repairMessage)
                }
            }
            #endif
        }
        .sheet(item: $exportedLogItem) { item in
            ShareSheet(activityItems: [item.url])
        }
        .alert("RR Data Recovery", isPresented: $showingRecoveryAlert) {
            Button("OK") {}
        } message: {
            Text(recoveryMessage)
        }
        .navigationTitle("Settings")
        .scrollDismissesKeyboard(.immediately)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    isVO2MaxFieldFocused = false
                }
            }
        }
        .sheet(isPresented: $showingAddTag) {
            AddTagSheet(
                tagName: $newTagName,
                tagColor: $newTagColor,
                onSave: {
                    let tag = ReadingTag(
                        name: newTagName,
                        colorHex: newTagColor.hexString
                    )
                    settingsManager.addCustomTag(tag)
                    newTagName = ""
                    newTagColor = .blue
                }
            )
        }
        } // Close ZStack
    }

    private var birthdayBinding: Binding<Date> {
        Binding(
            get: { settingsManager.settings.birthday ?? Calendar.current.date(byAdding: .year, value: -30, to: Date())! },
            set: { settingsManager.settings.birthday = $0 }
        )
    }

    private var fitnessBinding: Binding<FitnessLevel?> {
        Binding(
            get: { settingsManager.settings.fitnessLevel },
            set: { settingsManager.settings.fitnessLevel = $0 }
        )
    }

    private var sexBinding: Binding<UserSettings.BiologicalSex?> {
        Binding(
            get: { settingsManager.settings.biologicalSex },
            set: { settingsManager.settings.biologicalSex = $0 }
        )
    }

    private var vo2MaxBinding: Binding<Double?> {
        Binding(
            get: { settingsManager.settings.vo2MaxOverride },
            set: { settingsManager.settings.vo2MaxOverride = $0 }
        )
    }

    private func formatSleepDuration(_ hours: Double) -> String {
        let wholeHours = Int(hours)
        let minutes = Int((hours - Double(wholeHours)) * 60)
        if minutes == 0 {
            return "\(wholeHours) hours"
        } else {
            return "\(wholeHours)h \(minutes)m"
        }
    }

    private func deleteCustomTag(at offsets: IndexSet) {
        for index in offsets {
            let tag = settingsManager.settings.customTags[index]
            settingsManager.removeCustomTag(tag)
        }
    }

    private func recoverRRData() {
        isRecovering = true
        Task {
            do {
                let pointCount = try await collector.recoverAndPatchSession()
                await MainActor.run {
                    recoveryMessage = "Successfully recovered \(pointCount) RR points and patched today's session."
                    showingRecoveryAlert = true
                    isRecovering = false
                }
            } catch {
                await MainActor.run {
                    recoveryMessage = "Recovery failed: \(error.localizedDescription)"
                    showingRecoveryAlert = true
                    isRecovering = false
                }
            }
        }
    }

    private func exportDebugLogs() {
        guard let url = DebugLogger.shared.exportToFile() else { return }
        exportedLogItem = ExportableURL(url: url)
    }

    private func repairArchive() {
        let count = collector.archive.repairArchive()
        repairMessage = "Removed corrupted files and rebuilt index.\n\(count) sessions recovered."
        showingRepairAlert = true
    }
}

// MARK: - Debug Log View

struct DebugLogView: View {
    @ObservedObject var logger = DebugLogger.shared
    @State private var exportItem: ExportItem?
    @State private var showingClearConfirm = false

    private struct ExportItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        List {
            ForEach(logger.entries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.category)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.accentColor)
                        Spacer()
                        Text(entry.timestamp, style: .time)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text(entry.message)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("Debug Logs")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(role: .destructive) {
                    showingClearConfirm = true
                } label: {
                    Text("Clear")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    if let url = DebugLogger.shared.exportToFile() {
                        exportItem = ExportItem(url: url)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .alert("Clear Debug Logs?", isPresented: $showingClearConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                DebugLogger.shared.clear()
            }
        } message: {
            Text("This will delete all \(logger.entries.count) log entries. You can't undo this.")
        }
        .sheet(item: $exportItem) { item in
            NavigationStack {
                VStack {
                    Text("Debug Log Export")
                        .font(.title)
                        .padding()

                    Text(item.url.lastPathComponent)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button {
                        let activityVC = UIActivityViewController(activityItems: [item.url], applicationActivities: nil)

                        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                           let window = windowScene.windows.first,
                           let rootVC = window.rootViewController {
                            var topVC = rootVC
                            while let presented = topVC.presentedViewController {
                                topVC = presented
                            }
                            topVC.present(activityVC, animated: true)
                        }
                    } label: {
                        Label("Share Log File", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                }
                .navigationTitle("Export Logs")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            exportItem = nil
                        }
                    }
                }
            }
        }
    }
}

// ShareSheet is defined in Sources/Views/Utilities/ShareSheet.swift

// MARK: - Crash Log View

struct CrashLogView: View {
    @State private var crashLog: String = ""
    @State private var showingShareSheet = false
    @State private var exportURL: URL?
    @State private var showingClearConfirm = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                if crashLog.isEmpty {
                    Text("No crash log available")
                        .foregroundColor(.secondary)
                } else {
                    Text(crashLog)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            } header: {
                Text("Crash Details")
            } footer: {
                if !crashLog.isEmpty {
                    Text("Share this with the developer to help diagnose the issue.")
                }
            }

            if !crashLog.isEmpty {
                Section {
                    Button {
                        if let url = CrashLogManager.shared.exportCrashLog() {
                            exportURL = url
                            showingShareSheet = true
                        }
                    } label: {
                        Label("Share Crash Report", systemImage: "square.and.arrow.up")
                    }

                    Button(role: .destructive) {
                        showingClearConfirm = true
                    } label: {
                        Label("Delete Crash Report", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Crash Report")
        .onAppear {
            crashLog = CrashLogManager.shared.previousCrashLog ?? ""
        }
        .sheet(isPresented: $showingShareSheet) {
            if let url = exportURL {
                ShareSheet(activityItems: [url])
            }
        }
        .alert("Delete Crash Report?", isPresented: $showingClearConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                CrashLogManager.shared.clearPreviousCrash()
                dismiss()
            }
        } message: {
            Text("The crash report will be permanently deleted.")
        }
    }
}

// MARK: - Error Catalog View

struct ErrorCatalogView: View {
    @ObservedObject var logger = DebugLogger.shared
    @State private var showingExport = false
    @State private var exportURL: URL?
    @State private var showingClearConfirm = false
    @State private var errorCount = 0

    var body: some View {
        List {
            // Always show count at top
            Section {
                HStack {
                    Text("Total Errors")
                    Spacer()
                    Text("\(logger.errorCatalog.count)")
                        .foregroundColor(.red)
                }

                // Clear button inline for reliability
                Button(role: .destructive) {
                    showingClearConfirm = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Clear All Errors")
                    }
                }
                .disabled(logger.errorCatalog.isEmpty)
            }

            if logger.errorCatalog.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.green)
                    Text("No Errors Recorded")
                        .font(.headline)
                    Text("All systems running smoothly")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                Section("Recent Errors (newest first)") {
                    ForEach(logger.errorCatalog.suffix(100).reversed()) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.category)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.red)
                                Spacer()
                                Text(entry.timestamp, style: .date)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(entry.timestamp, style: .time)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text(entry.message)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.primary)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Error Catalog")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !logger.errorCatalog.isEmpty {
                    Button {
                        let content = logger.exportErrorCatalog()
                        let fileName = "hrv_error_catalog_\(Int(Date().timeIntervalSince1970)).txt"
                        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                        if let data = content.data(using: .utf8) {
                            try? data.write(to: tempURL)
                            exportURL = tempURL
                            Task { @MainActor in
                                showingExport = true
                            }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .alert("Clear All Errors?", isPresented: $showingClearConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Clear \(logger.errorCatalog.count) Errors", role: .destructive) {
                errorCount = logger.errorCatalog.count
                DebugLogger.shared.clearErrorCatalog()
                debugLog("[ErrorCatalog] Cleared \(errorCount) errors")
            }
        } message: {
            Text("This will permanently delete all \(logger.errorCatalog.count) error records.")
        }
        .sheet(isPresented: $showingExport) {
            if let url = exportURL {
                ShareSheet(activityItems: [url])
            }
        }
    }
}

// MARK: - Add Tag Sheet

private struct AddTagSheet: View {
    @Binding var tagName: String
    @Binding var tagColor: Color
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let presetColors: [Color] = [
        .red, .orange, .yellow, .green, .mint, .teal,
        .cyan, .blue, .indigo, .purple, .pink, .brown
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Tag Name") {
                    TextField("Enter tag name", text: $tagName)
                }

                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(presetColors, id: \.self) { color in
                            Circle()
                                .fill(color)
                                .frame(width: 40, height: 40)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary, lineWidth: tagColor == color ? 3 : 0)
                                )
                                .onTapGesture {
                                    tagColor = color
                                }
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section("Preview") {
                    HStack {
                        Spacer()
                        Text(tagName.isEmpty ? "Tag Name" : tagName)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(tagColor)
                            .foregroundColor(.white)
                            .cornerRadius(16)
                        Spacer()
                    }
                }
            }
            .navigationTitle("New Tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave()
                        dismiss()
                    }
                    .disabled(tagName.isEmpty)
                }
            }
        }
    }
}

// MARK: - Metric Explanations View

struct MetricExplanationsView: View {
    var body: some View {
        List {
            Section {
                MetricExplanationRow(
                    metric: "RMSSD",
                    fullName: "Root Mean Square of Successive Differences",
                    description: "The most commonly used HRV metric. RMSSD reflects parasympathetic (rest-and-digest) nervous system activity. Higher values generally indicate better recovery and cardiovascular health.",
                    interpretation: "Higher is generally better. Values typically range from 20-100ms depending on age and fitness."
                )

                MetricExplanationRow(
                    metric: "SDNN",
                    fullName: "Standard Deviation of NN Intervals",
                    description: "Measures overall heart rate variability. SDNN reflects both sympathetic and parasympathetic activity and is influenced by both short and long-term factors.",
                    interpretation: "Higher values indicate greater overall variability. Normal range: 50-100ms for healthy adults."
                )

                MetricExplanationRow(
                    metric: "pNN50",
                    fullName: "Percentage of NN50",
                    description: "The percentage of successive RR intervals that differ by more than 50ms. Like RMSSD, it reflects parasympathetic activity.",
                    interpretation: "Higher percentages indicate greater parasympathetic activity. Typical range: 5-25%."
                )
            } header: {
                Text("Time Domain")
            }

            Section {
                MetricExplanationRow(
                    metric: "LF Power",
                    fullName: "Low Frequency Power (0.04-0.15 Hz)",
                    description: "Reflects a mix of sympathetic and parasympathetic activity. Often associated with baroreceptor activity and blood pressure regulation.",
                    interpretation: "Influenced by both nervous system branches. Context-dependent interpretation."
                )

                MetricExplanationRow(
                    metric: "HF Power",
                    fullName: "High Frequency Power (0.15-0.4 Hz)",
                    description: "Strongly associated with parasympathetic (vagal) activity and respiratory sinus arrhythmia.",
                    interpretation: "Higher values indicate greater parasympathetic activity. Decreases with stress and exercise."
                )

                MetricExplanationRow(
                    metric: "LF/HF Ratio",
                    fullName: "Sympathovagal Balance",
                    description: "The ratio of low frequency to high frequency power. Sometimes used as an indicator of sympathetic-parasympathetic balance.",
                    interpretation: "Higher ratios may indicate sympathetic dominance. Typical range: 1-2 at rest."
                )
            } header: {
                Text("Frequency Domain")
            }

            Section {
                MetricExplanationRow(
                    metric: "SD1",
                    fullName: "Poincaré Plot Short-term Variability",
                    description: "Measures beat-to-beat variability from Poincaré plot analysis. Strongly correlated with RMSSD and parasympathetic activity.",
                    interpretation: "Higher values indicate greater short-term variability."
                )

                MetricExplanationRow(
                    metric: "SD2",
                    fullName: "Poincaré Plot Long-term Variability",
                    description: "Measures longer-term variability from Poincaré plot. Reflects both sympathetic and parasympathetic influences.",
                    interpretation: "Higher values indicate greater long-term variability."
                )

                MetricExplanationRow(
                    metric: "DFA α1",
                    fullName: "Detrended Fluctuation Analysis",
                    description: "Measures the fractal-like correlation properties of heart rate. Used to assess aerobic fitness and identify physiological states.",
                    interpretation: "~1.0 at rest, decreases with exercise intensity. Values <0.75 may indicate high stress or overtraining."
                )
            } header: {
                Text("Nonlinear Analysis")
            }

            Section {
                MetricExplanationRow(
                    metric: "Stress Index",
                    fullName: "Baevsky's Stress Index",
                    description: "Derived from heart rate histogram analysis. Higher values indicate greater sympathetic activity and stress load.",
                    interpretation: "Lower is generally better. Typical range: 50-150 at rest, can exceed 300+ during stress."
                )

                MetricExplanationRow(
                    metric: "Readiness Score",
                    fullName: "Recovery Readiness",
                    description: "A composite score combining multiple HRV metrics compared to your personal baseline. Indicates overall recovery status.",
                    interpretation: "Scale of 1-10. Above 7: Good recovery. 5-7: Moderate. Below 5: Consider rest."
                )
            } header: {
                Text("Composite Metrics")
            }
        }
        .navigationTitle("Metric Guide")
    }
}

private struct MetricExplanationRow: View {
    let metric: String
    let fullName: String
    let description: String
    let interpretation: String

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metric)
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text(fullName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(description)
                        .font(.subheadline)

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lightbulb.fill")
                            .foregroundColor(.yellow)
                            .font(.caption)
                        Text(interpretation)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                    .background(Color.yellow.opacity(0.1))
                    .cornerRadius(8)
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Export Data View

struct ExportDataView: View {
    @EnvironmentObject var collector: RRCollector
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var showingShareSheet = false

    var body: some View {
        List {
            Section {
                Button {
                    exportRRData()
                } label: {
                    Label("Export RR Intervals (CSV)", systemImage: "waveform.path")
                }
                .disabled(isExporting)

                Button {
                    exportCSV()
                } label: {
                    Label("Export Summary (CSV)", systemImage: "tablecells")
                }
                .disabled(isExporting)

                Button {
                    exportAllData()
                } label: {
                    Label("Export All Sessions (JSON)", systemImage: "doc.text")
                }
                .disabled(isExporting)
            } header: {
                Text("Export Options")
            } footer: {
                Text("RR Intervals exports the raw data needed to recalculate all HRV metrics. Use this for backup and recovery.")
            }

            Section("Statistics") {
                HStack {
                    Text("Total Sessions")
                    Spacer()
                    Text("\(collector.archive.entries.count)")
                        .foregroundColor(.secondary)
                }

                if let oldest = collector.archive.entries.last {
                    HStack {
                        Text("First Recording")
                        Spacer()
                        Text(oldest.date, style: .date)
                            .foregroundColor(.secondary)
                    }
                }

                if let newest = collector.archive.entries.first {
                    HStack {
                        Text("Latest Recording")
                        Spacer()
                        Text(newest.date, style: .date)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Export Data")
        .overlay {
            if isExporting {
                ProgressView("Exporting...")
                    .padding()
                    .background(.regularMaterial)
                    .cornerRadius(10)
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            if let url = exportURL {
                ShareSheet(activityItems: [url])
            }
        }
    }

    private func exportRRData() {
        isExporting = true

        Task {
            do {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd_HHmm"

                // Build one big CSV with all sessions
                var csv = "session_date,timestamp_ms,rr_ms\n"
                var sessionCount = 0

                for entry in collector.archive.entries {
                    guard let session = try collector.archive.retrieve(entry.sessionId),
                          let rrSeries = session.rrSeries else {
                        continue
                    }

                    let sessionDateStr = dateFormatter.string(from: session.startDate)

                    for point in rrSeries.points {
                        csv += "\(sessionDateStr),\(point.t_ms),\(point.rr_ms)\n"
                    }
                    sessionCount += 1
                }

                // Write to temp file
                let exportFormatter = DateFormatter()
                exportFormatter.dateFormat = "yyyyMMdd_HHmmss"
                let timestamp = exportFormatter.string(from: Date())
                let fileName = "FlowRecovery_RR_\(timestamp).csv"
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                try csv.write(to: tempURL, atomically: true, encoding: .utf8)

                debugLog("Exported RR data: \(sessionCount) sessions")

                await MainActor.run {
                    exportURL = tempURL
                    isExporting = false
                    showingShareSheet = true
                }
            } catch {
                debugLog("RR export failed: \(error)")
                await MainActor.run {
                    isExporting = false
                }
            }
        }
    }

    private func exportCSV() {
        isExporting = true

        Task {
            do {
                // Build CSV header
                var csv = "date,session_type,recovery_score,rmssd,tags,notes\n"

                // Add each session as a row
                let dateFormatter = ISO8601DateFormatter()

                for entry in collector.archive.entries {
                    let dateStr = dateFormatter.string(from: entry.date)
                    let sessionType = entry.sessionType.rawValue
                    let recoveryScore = entry.recoveryScore.map { String(format: "%.1f", $0) } ?? ""
                    let rmssd = entry.meanRMSSD.map { String(format: "%.2f", $0) } ?? ""
                    let tags = entry.tags.map { $0.name }.joined(separator: ";")
                    let notes = (entry.notes ?? "").replacingOccurrences(of: ",", with: ";").replacingOccurrences(of: "\n", with: " ")

                    csv += "\"\(dateStr)\",\"\(sessionType)\",\(recoveryScore),\(rmssd),\"\(tags)\",\"\(notes)\"\n"
                }

                // Write to temp file
                let exportFormatter = DateFormatter()
                exportFormatter.dateFormat = "yyyyMMdd_HHmmss"
                let timestamp = exportFormatter.string(from: Date())
                let fileName = "FlowRecovery_Summary_\(timestamp).csv"
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                try csv.write(to: tempURL, atomically: true, encoding: .utf8)

                await MainActor.run {
                    exportURL = tempURL
                    isExporting = false
                    showingShareSheet = true
                }
            } catch {
                debugLog("CSV export failed: \(error)")
                await MainActor.run {
                    isExporting = false
                }
            }
        }
    }

    private func exportAllData() {
        isExporting = true

        Task {
            do {
                // Collect all sessions
                var allSessions: [HRVSession] = []
                for entry in collector.archive.entries {
                    if let session = try collector.archive.retrieve(entry.sessionId) {
                        allSessions.append(session)
                    }
                }

                // Encode to JSON
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let jsonData = try encoder.encode(allSessions)

                // Write to temp file
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
                let timestamp = dateFormatter.string(from: Date())
                let fileName = "FlowRecovery_Export_\(timestamp).json"
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                try jsonData.write(to: tempURL)

                await MainActor.run {
                    exportURL = tempURL
                    isExporting = false
                    showingShareSheet = true
                }
            } catch {
                debugLog("Export failed: \(error)")
                await MainActor.run {
                    isExporting = false
                }
            }
        }
    }
}

// MARK: - Archive Diagnostics View

struct ArchiveDiagnosticsView: View {
    @EnvironmentObject var collector: RRCollector
    @State private var diagnosticInfo: String = "Loading..."
    @State private var isRepairing = false
    @State private var showingRepairConfirm = false
    @State private var showingClearConfirm = false
    @State private var repairResult: String = ""
    @State private var showingResult = false

    var body: some View {
        List {
            Section("Archive Index") {
                Text(diagnosticInfo)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            Section("Actions") {
                Button {
                    refreshDiagnostics()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                Button {
                    showingRepairConfirm = true
                } label: {
                    Label("Repair Archive", systemImage: "wrench.and.screwdriver")
                }
                .disabled(isRepairing)

                Button(role: .destructive) {
                    showingClearConfirm = true
                } label: {
                    Label("Clear All Archive Data", systemImage: "trash")
                }
            }

            Section("File System") {
                Button {
                    scanFileSystem()
                } label: {
                    Label("Scan Archive Directory", systemImage: "folder.badge.questionmark")
                }
            }
        }
        .navigationTitle("Archive Diagnostics")
        .onAppear {
            refreshDiagnostics()
        }
        .alert("Repair Archive?", isPresented: $showingRepairConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Repair") {
                performRepair()
            }
        } message: {
            Text("This will remove corrupted/encrypted files and rebuild the index from valid JSON files.")
        }
        .alert("Clear All Data?", isPresented: $showingClearConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Clear Everything", role: .destructive) {
                clearAllData()
            }
        } message: {
            Text("This will permanently delete ALL archived sessions. This cannot be undone!")
        }
        .alert("Result", isPresented: $showingResult) {
            Button("OK") { }
        } message: {
            Text(repairResult)
        }
    }

    private func refreshDiagnostics() {
        let entries = collector.archive.entries
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        var info = "Index entries: \(entries.count)\n\n"

        if entries.isEmpty {
            info += "No sessions in index."
        } else {
            info += "Sessions by date:\n"
            for (i, entry) in entries.prefix(50).enumerated() {
                let dateStr = dateFormatter.string(from: entry.date)
                let rmssd = entry.meanRMSSD.map { String(format: "%.1f", $0) } ?? "?"
                info += "\(i+1). \(dateStr) - RMSSD: \(rmssd)\n"
                info += "   ID: \(entry.sessionId.uuidString.prefix(8))...\n"
                info += "   Path: ...\(entry.filePath.suffix(40))\n\n"
            }
            if entries.count > 50 {
                info += "... and \(entries.count - 50) more\n"
            }
        }

        diagnosticInfo = info
    }

    private func scanFileSystem() {
        let archive = collector.archive
        let fm = FileManager.default

        // Get archive directory from the archive
        guard let containerURL = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.chrissharp.flowrecovery") else {
            diagnosticInfo = "ERROR: Cannot access app group container"
            return
        }

        let archiveDir = containerURL.appendingPathComponent("HRVArchive")

        var info = "Archive Directory:\n\(archiveDir.path)\n\n"

        do {
            let files = try fm.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey])

            let jsonFiles = files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.contains("index") && !$0.lastPathComponent.contains("deleted") }
            let encryptedFiles = files.filter { $0.pathExtension == "encrypted" }
            let indexFile = files.first { $0.lastPathComponent == "index.json" }

            info += "Files found:\n"
            info += "- JSON sessions: \(jsonFiles.count)\n"
            info += "- Encrypted files: \(encryptedFiles.count)\n"
            info += "- Index file: \(indexFile != nil ? "YES" : "NO")\n\n"

            if !encryptedFiles.isEmpty {
                info += "Encrypted files (cannot read):\n"
                for file in encryptedFiles.prefix(10) {
                    info += "  - \(file.lastPathComponent)\n"
                }
                if encryptedFiles.count > 10 {
                    info += "  ... and \(encryptedFiles.count - 10) more\n"
                }
                info += "\nRun 'Repair Archive' to remove these.\n"
            }

            info += "\nIndex entries: \(archive.entries.count)\n"
            info += "Mismatch: \(abs(jsonFiles.count - archive.entries.count)) files\n"

        } catch {
            info += "Error scanning: \(error.localizedDescription)"
        }

        diagnosticInfo = info
    }

    private func performRepair() {
        isRepairing = true

        Task {
            let count = collector.archive.repairArchive()
            await MainActor.run {
                isRepairing = false
                repairResult = "Repair complete. \(count) sessions recovered."
                showingResult = true
                refreshDiagnostics()
            }
        }
    }

    private func clearAllData() {
        let fm = FileManager.default
        guard let containerURL = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.chrissharp.flowrecovery") else {
            repairResult = "ERROR: Cannot access app group container"
            showingResult = true
            return
        }

        let archiveDir = containerURL.appendingPathComponent("HRVArchive")

        do {
            // Remove entire archive directory
            try fm.removeItem(at: archiveDir)
            // Recreate empty directory
            try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)

            repairResult = "All archive data cleared. Restart app to reinitialize."
            showingResult = true
            refreshDiagnostics()
        } catch {
            repairResult = "Error clearing data: \(error.localizedDescription)"
            showingResult = true
        }
    }
}

// ShareSheet is defined in Sources/Views/Utilities/ShareSheet.swift

// MARK: - Exportable URL Wrapper

/// Identifiable wrapper for URL to use with .sheet(item:)
private struct ExportableURL: Identifiable {
    let id = UUID()
    let url: URL
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(SettingsManager.shared)
    }
}
