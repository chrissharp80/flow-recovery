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

/// Recording view for HRV data collection - supports both overnight H10 recording and quick streaming
struct RecordView: View {
    @EnvironmentObject var collector: RRCollector
    @EnvironmentObject var settingsManager: SettingsManager
    @Binding var selectedTab: MainTabView.Tab
    @State private var selectedTags: Set<ReadingTag> = []
    @State private var showingTagPicker = false
    @State private var sessionNotes = ""
    @State private var showingError = false
    @State private var showingMorningResults = false
    @State private var showingQuickResults = false
    @State private var fetchFailed = false
    @State private var isRetrying = false
    @State private var reanalyzedResult: HRVAnalysisResult? = nil  // For manual window reanalysis
    @State private var isReanalyzing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Connection Section
                connectionSection

                // Recording Sections (only when connected)
                if collector.polarManager.connectionState == .connected {
                    // Retry Fetch Section (shown when fetch failed)
                    if fetchFailed {
                        retryFetchSection
                    }

                    // Recoverable Data Section (shown when H10 has stored exercise and we're not busy)
                    if collector.polarManager.hasStoredExercise && !fetchFailed && !collector.needsAcceptance && collector.polarManager.recordingState == .idle && collector.polarManager.fetchProgress == nil {
                        recoverableDataSection
                    }

                    // Tag Selection
                    tagSelectionSection

                    // Overnight Recording Section (H10 internal storage)
                    overnightRecordingSection

                    // Quick Reading Section (streaming mode)
                    quickReadingSection
                }

                // Live Data Section (when streaming)
                if collector.polarManager.isStreaming {
                    liveDataSection
                }

                // Verification Section (when pending acceptance)
                if let verification = collector.verificationResult {
                    verificationSection(verification)
                }

                // Results Preview for overnight (tap to see full results)
                if collector.needsAcceptance,
                   let session = collector.currentSession,
                   let result = session.analysisResult {
                    morningResultsPreview(session: session, result: result)
                }

                // Results Preview (for streaming readings) - tap to see full report
                if let session = collector.currentSession,
                   session.state == .complete,
                   !collector.needsAcceptance,
                   let result = session.analysisResult {
                    quickResultsPreview(session: session, result: result)
                }

                // Acceptance Section (for overnight recordings)
                if collector.needsAcceptance {
                    acceptanceSection
                }
            }
            .padding()
        }
        .navigationTitle("Record")
        .background(AppTheme.background)
        .sheet(isPresented: $showingTagPicker) {
            TagPickerSheet(
                selectedTags: $selectedTags,
                availableTags: settingsManager.settings.allTags
            )
        }
        .fullScreenCover(isPresented: $showingMorningResults) {
            if let session = collector.currentSession,
               let originalResult = session.analysisResult {
                let displayResult = reanalyzedResult ?? originalResult
                NavigationStack {
                    MorningResultsView(
                        session: session,
                        result: displayResult,
                        recentSessions: collector.archivedSessions,
                        onDiscard: {
                            discardMorningReading()
                            showingMorningResults = false
                            reanalyzedResult = nil
                        },
                        onReanalyze: { session, method in
                            await collector.reanalyzeSession(session, method: method)
                        },
                        onReanalyzeAt: { timestampMs in
                            Task {
                                isReanalyzing = true
                                if let newResult = await collector.reanalyzeAtPosition(session, targetMs: timestampMs) {
                                    await MainActor.run {
                                        reanalyzedResult = newResult
                                        isReanalyzing = false
                                    }
                                } else {
                                    await MainActor.run {
                                        isReanalyzing = false
                                    }
                                }
                            }
                        }
                    )
                    .overlay {
                        if isReanalyzing {
                            ZStack {
                                Color.black.opacity(0.3)
                                VStack(spacing: 12) {
                                    ProgressView()
                                        .tint(.white)
                                    Text("Reanalyzing...")
                                        .font(.caption)
                                        .foregroundColor(.white)
                                }
                                .padding(20)
                                .background(Color.black.opacity(0.7))
                                .cornerRadius(12)
                            }
                            .ignoresSafeArea()
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                // Save session with any reanalyzed result
                                if let newResult = reanalyzedResult {
                                    collector.updateCurrentSessionResult(newResult)
                                }
                                saveMorningReading()
                                showingMorningResults = false
                                reanalyzedResult = nil
                            }
                        }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showingQuickResults) {
            if let session = collector.currentSession,
               let result = session.analysisResult {
                NavigationStack {
                    MorningResultsView(
                        session: session,
                        result: result,
                        recentSessions: collector.archivedSessions,
                        onDiscard: {
                            // Delete from archive if saved
                            try? collector.archive.delete(session.id)
                            showingQuickResults = false
                            collector.resetSession()
                        }
                    )
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                // Already saved for streaming, just dismiss and reset
                                showingQuickResults = false
                                collector.resetSession()
                            }
                        }
                    }
                }
            }
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(collector.lastError?.localizedDescription ?? "Unknown error")
        }
        .onReceive(collector.$lastError) { error in
            // Don't show error popup during overnight streaming - user is asleep and can't act on it
            // Error will be visible when they wake up and try to get morning reading
            if error != nil && !collector.isOvernightStreaming {
                showingError = true
            }
        }
    }

    // MARK: - Morning Results Preview

    private func morningResultsPreview(session: HRVSession, result: HRVAnalysisResult) -> some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Morning Analysis Ready")
                        .font(.headline)
                        .foregroundStyle(AppTheme.primaryGradient)
                    Text(session.startDate, style: .date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "moon.stars.fill")
                    .font(.title2)
                    .foregroundStyle(AppTheme.primaryGradient)
            }

            // Key metrics preview
            HStack(spacing: 16) {
                MetricPreviewCard(
                    title: "RMSSD",
                    value: String(format: "%.0f", result.timeDomain.rmssd),
                    unit: "ms",
                    color: AppTheme.primary
                )

                if let readiness = result.ansMetrics?.readinessScore {
                    MetricPreviewCard(
                        title: "Readiness",
                        value: String(format: "%.1f", readiness),
                        unit: "/10",
                        color: AppTheme.readinessColor(readiness)
                    )
                }

                MetricPreviewCard(
                    title: "HR",
                    value: String(format: "%.0f", result.timeDomain.meanHR),
                    unit: "bpm",
                    color: AppTheme.accent
                )
            }

            // View full results button
            Button(action: { showingMorningResults = true }) {
                HStack {
                    Text("View Full Report")
                    Image(systemName: "chart.xyaxis.line")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.primary)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(AppTheme.primaryGradient, lineWidth: 2)
                )
        )
    }

    private func saveMorningReading() {
        Task {
            if let session = collector.currentSession {
                // Auto-add morning tag for overnight recordings (they're morning readings by definition)
                var tagsToSave = selectedTags
                tagsToSave.insert(ReadingTag.morning)
                try? collector.archive.updateTags(session.id, tags: Array(tagsToSave), notes: sessionNotes.isEmpty ? nil : sessionNotes)
            }
            try? await collector.acceptSession()
            await MainActor.run {
                selectedTags.removeAll()
                sessionNotes = ""
            }
        }
    }

    private func discardMorningReading() {
        Task {
            await collector.rejectSession()
            await MainActor.run {
                selectedTags.removeAll()
                sessionNotes = ""
            }
        }
    }

    // MARK: - Connection Section

    private var connectionSection: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Polar H10")
                    .font(.headline)
                Spacer()
                connectionStatusBadge
            }

            switch collector.polarManager.connectionState {
            case .disconnected:
                disconnectedView
            case .scanning:
                scanningView
            case .connecting:
                connectingView
            case .connected:
                connectedView
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private var connectionStatusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connectionColor)
                .frame(width: 8, height: 8)
            Text(connectionStatusText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(.systemBackground))
        .clipShape(Capsule())
    }

    private var connectionColor: Color {
        switch collector.polarManager.connectionState {
        case .disconnected: return .gray
        case .scanning: return .yellow
        case .connecting: return .orange
        case .connected: return .green
        }
    }

    private var connectionStatusText: String {
        switch collector.polarManager.connectionState {
        case .disconnected: return "Disconnected"
        case .scanning: return "Scanning"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        }
    }

    private var disconnectedView: some View {
        VStack(spacing: 12) {
            if collector.polarManager.lastConnectedDeviceId != nil {
                Button(action: { collector.polarManager.connectToLastDevice() }) {
                    Label("Reconnect to Last Device", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            Button(action: { collector.polarManager.startScanning() }) {
                Label("Scan for Devices", systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Text("Put on your Polar H10 strap and moisten the electrodes")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var scanningView: some View {
        VStack(spacing: 12) {
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Scanning for Polar H10...")
                    .font(.subheadline)
            }

            if !collector.polarManager.discoveredDevices.isEmpty {
                VStack(spacing: 8) {
                    ForEach(collector.polarManager.discoveredDevices) { device in
                        Button(action: { collector.polarManager.connect(deviceId: device.id) }) {
                            HStack {
                                Image(systemName: "heart.fill")
                                    .foregroundColor(.red)
                                Text(device.name)
                                Spacer()
                                Text("\(device.rssi) dBm")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .background(Color(.systemBackground))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button(action: { collector.polarManager.stopScanning() }) {
                Text("Stop Scanning")
            }
            .buttonStyle(.bordered)
        }
    }

    private var connectingView: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.8)
            Text("Connecting...")
                .font(.subheadline)
        }
    }

    private var connectedView: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(collector.polarManager.connectedDeviceId ?? "Unknown")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    if let battery = collector.polarManager.batteryLevel {
                        HStack(spacing: 4) {
                            Image(systemName: batteryIcon(battery))
                            Text("\(battery)%")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if collector.polarManager.isRecordingOnDevice {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text("Recording")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }

            // Live HR display when connected (always on from PolarManager)
            if let liveHR = collector.polarManager.currentHeartRate {
                HStack(spacing: 8) {
                    Image(systemName: "heart.fill")
                        .foregroundColor(.red)
                        .font(.title2)
                        .symbolEffect(.pulse, options: .repeating)
                    Text("\(liveHR)")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .foregroundColor(AppTheme.terracotta)
                    Text("bpm")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            }

            Button(action: { collector.polarManager.disconnect() }) {
                Text("Disconnect")
            }
            .buttonStyle(.bordered)
            .disabled(collector.polarManager.recordingState != .idle)
        }
    }

    private func batteryIcon(_ level: Int) -> String {
        switch level {
        case 0..<25: return "battery.25"
        case 25..<50: return "battery.50"
        case 50..<75: return "battery.75"
        default: return "battery.100"
        }
    }

    // MARK: - Tag Selection

    private var tagSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reading Type")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ReadingTag.systemTags) { tag in
                        TagChip(
                            tag: tag,
                            isSelected: selectedTags.contains(tag),
                            onTap: { toggleTag(tag) }
                        )
                    }

                    Button {
                        showingTagPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("More")
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.gray.opacity(0.2))
                        .foregroundColor(.primary)
                        .cornerRadius(16)
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    // MARK: - Morning Reading Section (Overnight Recording)

    private var overnightRecordingSection: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Morning Reading")
                        .font(.headline)
                    Text("Overnight streaming via Bluetooth")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                recordingStatusBadge
            }

            // Overnight streaming mode active
            if collector.isOvernightStreaming {
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "moon.zzz.fill")
                            .foregroundColor(AppTheme.primary)
                        Text("Streaming overnight...")
                            .font(.subheadline)
                            .foregroundColor(AppTheme.textPrimary)
                    }

                    // Elapsed time and heartbeats collected
                    HStack(spacing: 20) {
                        VStack {
                            Text(formatStreamingTime(collector.streamingElapsedSeconds))
                                .font(.title2)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .foregroundColor(AppTheme.primary)
                            Text("Elapsed")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        VStack {
                            Text("\(collector.collectedPoints.count)")
                                .font(.title2)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .foregroundColor(AppTheme.sage)
                            Text("Heartbeats")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if let hr = collector.polarManager.currentHeartRate {
                            VStack {
                                Text("\(hr)")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                                    .foregroundColor(AppTheme.accent)
                                Text("BPM")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 8)

                    Text("Keep the app open - silent audio keeps it running in background.")
                        .font(.caption)
                        .foregroundColor(AppTheme.sage)
                        .multilineTextAlignment(.center)

                    Text("Tap 'Get Morning Reading' when you wake up.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(AppTheme.sectionTint)
                .cornerRadius(AppTheme.smallCornerRadius)
            }

            // Legacy: H10 internal recording mode
            if collector.polarManager.isRecordingOnDevice && !collector.isOvernightStreaming && collector.polarManager.fetchProgress == nil {
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "moon.zzz.fill")
                            .foregroundColor(AppTheme.primary)
                        Text("Recording overnight (internal)...")
                            .font(.subheadline)
                            .foregroundColor(AppTheme.textPrimary)
                    }

                    Text("Go to sleep. H10 stores data internally - you can close the app.")
                        .font(.caption)
                        .foregroundColor(AppTheme.sage)
                        .multilineTextAlignment(.center)

                    Text("Open the app in the morning to retrieve your reading.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(AppTheme.sectionTint)
                .cornerRadius(AppTheme.smallCornerRadius)
            }

            // Fetch progress section (for legacy internal recording)
            if let progress = collector.polarManager.fetchProgress {
                fetchProgressView(progress)
            }

            overnightActionButtons

            if !collector.polarManager.isRecordingOnDevice && !collector.isOvernightStreaming && collector.polarManager.recordingState == .idle && collector.polarManager.fetchProgress == nil {
                VStack(spacing: 4) {
                    Text("Start before bed - retrieve when you wake up")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Analysis uses best 5-min window from last 60 min of sleep")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    /// Format streaming time as HH:MM:SS
    private func formatStreamingTime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }

    // MARK: - Fetch Progress View

    private func fetchProgressView(_ progress: PolarManager.FetchProgress) -> some View {
        VStack(spacing: 12) {
            // Status icon and message
            HStack(spacing: 10) {
                progressIcon(for: progress.stage)
                    .font(.title2)
                    .foregroundColor(progressColor(for: progress.stage))

                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.statusMessage.isEmpty ? progress.stage.rawValue : progress.statusMessage)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(AppTheme.textPrimary)

                    if progress.attempt > 1 {
                        Text("Attempt \(progress.attempt) of \(progress.maxAttempts)")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                Spacer()

                if progress.stage != .complete && progress.stage != .failed {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 8)

                    // Progress fill
                    RoundedRectangle(cornerRadius: 4)
                        .fill(progressColor(for: progress.stage))
                        .frame(width: geometry.size.width * progress.progress, height: 8)
                        .animation(.easeInOut(duration: 0.3), value: progress.progress)
                }
            }
            .frame(height: 8)

            // Percentage and cancel button
            HStack {
                Text("\(Int(progress.progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                Spacer()
                if progress.stage == .retrying || progress.stage == .failed {
                    Text("Data is safe on H10")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // Cancel button - always available during fetch
            if progress.stage != .complete {
                Button(action: {
                    collector.polarManager.cancelFetch()
                }) {
                    Label("Cancel", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius)
                .fill(progressBackgroundColor(for: progress.stage))
        )
    }

    private func progressIcon(for stage: PolarManager.FetchProgress.Stage) -> Image {
        switch stage {
        case .stopping:
            return Image(systemName: "stop.circle")
        case .finalizing:
            return Image(systemName: "externaldrive")
        case .listingExercises:
            return Image(systemName: "magnifyingglass")
        case .fetchingData:
            return Image(systemName: "arrow.down.circle")
        case .reconnecting:
            return Image(systemName: "antenna.radiowaves.left.and.right")
        case .retrying:
            return Image(systemName: "arrow.clockwise")
        case .complete:
            return Image(systemName: "checkmark.circle.fill")
        case .failed:
            return Image(systemName: "exclamationmark.triangle.fill")
        }
    }

    private func progressColor(for stage: PolarManager.FetchProgress.Stage) -> Color {
        switch stage {
        case .stopping, .finalizing, .listingExercises, .fetchingData:
            return AppTheme.primary
        case .reconnecting, .retrying:
            return .orange
        case .complete:
            return AppTheme.sage
        case .failed:
            return .red
        }
    }

    private func progressBackgroundColor(for stage: PolarManager.FetchProgress.Stage) -> Color {
        switch stage {
        case .reconnecting, .retrying:
            return Color.orange.opacity(0.1)
        case .complete:
            return AppTheme.sage.opacity(0.1)
        case .failed:
            return Color.red.opacity(0.1)
        default:
            return AppTheme.sectionTint
        }
    }


    private var recordingStatusBadge: some View {
        HStack(spacing: 6) {
            if collector.isOvernightStreaming || collector.polarManager.isRecordingOnDevice || collector.polarManager.recordingState == .recording {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
            }
            Text(recordingStatusText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(.systemBackground))
        .clipShape(Capsule())
    }

    private var recordingStatusText: String {
        // Overnight streaming mode
        if collector.isOvernightStreaming {
            return "Streaming"
        }

        switch collector.polarManager.recordingState {
        case .idle:
            return collector.polarManager.isRecordingOnDevice ? "Recording" : "Ready"
        case .starting: return "Starting..."
        case .recording: return "Recording"
        case .stopping: return "Stopping..."
        case .fetching: return "Fetching Data..."
        }
    }

    private var overnightActionButtons: some View {
        VStack(spacing: 12) {
            // Overnight streaming active - show stop button
            if collector.isOvernightStreaming {
                Button(action: stopAndFetch) {
                    Label("Get Morning Reading", systemImage: "sunrise.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.zen(AppTheme.sage))
                .disabled(isActionDisabled)
            }
            // Legacy internal recording active - show stop button
            else if collector.polarManager.isRecordingOnDevice || collector.polarManager.recordingState == .recording {
                Button(action: stopAndFetch) {
                    Label("Wake Up - Get Results", systemImage: "sunrise.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.zen(AppTheme.sage))
                .disabled(isActionDisabled)
            }
            // Not recording - show start button
            else {
                Button(action: startOvernightRecording) {
                    Label("Start Overnight Streaming", systemImage: "moon.zzz.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.zen(AppTheme.primary))
                .disabled(isActionDisabled || collector.polarManager.connectionState != .connected)

                if collector.polarManager.connectionState != .connected {
                    Text("Connect to Polar H10 first")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if collector.hasUnrecoveredData {
                    VStack(spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Unrecovered data on H10")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.orange)
                        }
                        Text("Recover or discard before starting new recording")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if isActionDisabled {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
    }

    private var isActionDisabled: Bool {
        switch collector.polarManager.recordingState {
        case .starting, .stopping, .fetching: return true
        case .idle, .recording: return false
        }
    }

    // MARK: - Retry Fetch Section

    private var retryFetchSection: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Data Fetch Failed")
                        .font(.headline)
                        .foregroundColor(.orange)
                    Text("Your recording data is still on the H10")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Text("The recording data was not retrieved successfully. Don't worry - the data is still stored on your Polar H10. Try fetching again.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)

            Button(action: retryFetch) {
                HStack {
                    if isRetrying {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.white)
                    }
                    Label(isRetrying ? "Fetching..." : "Retry Fetch Data", systemImage: "arrow.clockwise")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(isRetrying || collector.polarManager.connectionState != .connected)

            // Cancel button - shows when actively retrying
            if isRetrying {
                Button(action: {
                    collector.polarManager.cancelFetch()
                    isRetrying = false
                }) {
                    Label("Cancel", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            Button(action: {
                fetchFailed = false
                collector.resetSession()
            }) {
                Text("Dismiss")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - Recoverable Data Section

    private var recoverableDataSection: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "externaldrive.fill.badge.checkmark")
                    .foregroundColor(AppTheme.primary)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Data Found on H10")
                        .font(.headline)
                        .foregroundColor(AppTheme.primary)
                    Text("Previous recording available to recover")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Text("Your Polar H10 has stored recording data from a previous session. You can recover this data now or start a new recording (which will clear the old data).")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)

            Button(action: recoverStoredData) {
                Label("Recover Data", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.primary)

            Button(action: discardAndStartFresh) {
                Text("Discard & Start Fresh")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .foregroundColor(.red)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.primary.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(AppTheme.primary.opacity(0.3), lineWidth: 1)
                )
        )
    }

    private func recoverStoredData() {
        Task {
            // Keep screen on during download to prevent iOS from deprioritizing BLE
            await MainActor.run {
                UIApplication.shared.isIdleTimerDisabled = true
            }
            defer {
                Task { @MainActor in
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            }

            do {
                let session = try await collector.recoverFromDevice()
                await MainActor.run {
                    if session?.state == .complete {
                        // Data recovered successfully
                    }
                }
            } catch {
                await MainActor.run {
                    fetchFailed = true
                }
            }
        }
    }

    private func discardAndStartFresh() {
        Task {
            do {
                try await collector.polarManager.discardStoredExercises()
            } catch {
                // Error discarding - will show in lastError
            }
        }
    }

    // MARK: - Quick Reading Section

    private var quickReadingSection: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quick Reading")
                        .font(.headline)
                    Text("Spot check - keep app open during recording")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if collector.polarManager.isStreaming {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(AppTheme.sage)
                            .frame(width: 8, height: 8)
                        Text("Live")
                            .font(.caption)
                            .foregroundColor(AppTheme.sage)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(AppTheme.sectionTint)
                    .clipShape(Capsule())
                }
            }

            if collector.polarManager.isStreaming {
                streamingProgressView
            } else if !collector.polarManager.isRecordingOnDevice && collector.polarManager.recordingState == .idle {
                VStack(spacing: 12) {
                    Text("For daytime checks, post-workout recovery, or if you can't do overnight")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 12) {
                        QuickReadingButton(
                            duration: "2 min",
                            description: "Basic",
                            icon: "clock",
                            color: AppTheme.mist,
                            action: { startStreaming(seconds: 120) }
                        )

                        QuickReadingButton(
                            duration: "3 min",
                            description: "Standard",
                            icon: "clock.fill",
                            color: AppTheme.sage,
                            action: { startStreaming(seconds: 180) }
                        )

                        QuickReadingButton(
                            duration: "5 min",
                            description: "Full",
                            icon: "clock.badge.checkmark",
                            color: AppTheme.primary,
                            action: { startStreaming(seconds: 300) }
                        )
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private struct QuickReadingButton: View {
        let duration: String
        let description: String
        let icon: String
        let color: Color
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                VStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundColor(color)
                    Text(duration)
                        .font(.subheadline.bold())
                        .foregroundColor(AppTheme.textPrimary)
                    Text(description)
                        .font(.caption2)
                        .foregroundColor(AppTheme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(AppTheme.cardBackground)
                .cornerRadius(AppTheme.smallCornerRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius)
                        .stroke(color.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var streamingProgressView: some View {
        VStack(spacing: 12) {
            // Timer and progress header - more compact
            HStack(alignment: .center) {
                // Countdown
                VStack(alignment: .leading, spacing: 2) {
                    Text(formattedStreamingTime)
                        .font(.system(size: 36, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(AppTheme.primary)
                    Text("remaining")
                        .font(.caption)
                        .foregroundColor(AppTheme.textTertiary)
                }

                Spacer()

                // Progress ring with HR
                ZStack {
                    Circle()
                        .stroke(AppTheme.sectionTint, lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: streamingProgress)
                        .stroke(AppTheme.sage, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: streamingProgress)

                    if let hr = currentHeartRate {
                        VStack(spacing: 0) {
                            Text("\(Int(hr))")
                                .font(.system(.title3, design: .rounded).bold())
                                .foregroundColor(AppTheme.terracotta)
                            Text("bpm")
                                .font(.caption2)
                                .foregroundColor(AppTheme.textTertiary)
                        }
                    }
                }
                .frame(width: 70, height: 70)
            }

            // Compact waveform
            if collector.polarManager.streamedRRPoints.count > 10 {
                LiveWaveformView(
                    rrPoints: collector.polarManager.streamedRRPoints,
                    maxPoints: 40,
                    showGrid: false,
                    accentColor: AppTheme.sage
                )
                .frame(height: 60)
            } else {
                // Placeholder while waiting for data
                RoundedRectangle(cornerRadius: 8)
                    .fill(AppTheme.sectionTint)
                    .frame(height: 60)
                    .overlay(
                        Text("Waiting for heart rate data...")
                            .font(.caption)
                            .foregroundColor(AppTheme.textTertiary)
                    )
            }

            // Breathing Mandala for coherence
            VStack(spacing: 4) {
                Text("Breathe with the mandala for coherence")
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)

                BreathingMandalaView.coherence()
                    .frame(width: 180, height: 180)
            }
            .padding(.vertical, 8)

            // Compact stats row
            HStack(spacing: 12) {
                StreamingStatPill(
                    value: "\(collector.collectedPoints.count)",
                    label: "beats",
                    color: AppTheme.primary
                )

                StreamingStatPill(
                    value: formattedElapsedTime,
                    label: "elapsed",
                    color: AppTheme.sage
                )

                if collector.polarManager.streamedRRPoints.count > 5 {
                    let recentRR = collector.polarManager.streamedRRPoints.suffix(20)
                    let avgRR = recentRR.map { Double($0.rr_ms) }.reduce(0, +) / Double(recentRR.count)
                    StreamingStatPill(
                        value: String(format: "%.0f", avgRR),
                        label: "avg RR",
                        color: AppTheme.mist
                    )
                }
            }

            // Running HRV stats (if enough data) - more compact
            if collector.polarManager.streamedRRPoints.count > 30 {
                LiveStatsCard(rrPoints: collector.polarManager.streamedRRPoints)
            }

            // Stop button
            Button(action: stopStreaming) {
                Label("Stop Early", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.zenSecondary)
        }
        .onAppear {
            // Set up auto-complete callback
            collector.onStreamingComplete = { [weak collector] in
                guard let collector = collector else { return }
                Task {
                    let session = await collector.stopStreamingSession()
                    if let session = session, !selectedTags.isEmpty {
                        try? collector.archive.updateTags(session.id, tags: Array(selectedTags), notes: sessionNotes.isEmpty ? nil : sessionNotes)
                    }
                }
            }
        }
        .onDisappear {
            collector.onStreamingComplete = nil
        }
    }

    // MARK: - Streaming Stat Pill

    private struct StreamingStatPill: View {
        let value: String
        let label: String
        let color: Color

        var body: some View {
            VStack(spacing: 2) {
                Text(value)
                    .font(.system(.subheadline, design: .rounded).bold())
                    .foregroundColor(color)
                Text(label)
                    .font(.caption2)
                    .foregroundColor(AppTheme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(AppTheme.sectionTint)
            .cornerRadius(8)
        }
    }

    // MARK: - Live Data Section

    private var liveDataSection: some View {
        VStack(spacing: 16) {
            // Live Heart Rate
            if let hr = currentHeartRate {
                HStack {
                    Image(systemName: "heart.fill")
                        .foregroundColor(.red)
                    Text("\(Int(hr))")
                        .font(.system(.title, design: .rounded).bold())
                    Text("bpm")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }

            // Live Waveform
            if collector.polarManager.streamedRRPoints.count > 10 {
                LiveWaveformView(
                    rrPoints: collector.polarManager.streamedRRPoints,
                    maxPoints: 60,
                    showGrid: true,
                    accentColor: .green
                )

                // Running Stats
                LiveStatsCard(rrPoints: collector.polarManager.streamedRRPoints)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    // MARK: - Verification Section

    private func verificationSection(_ verification: Verification.Result) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text("Data Quality")
                    .font(.headline)
                Spacer()
                qualityBadge(verification.passed)
            }

            if let window = collector.recoveryWindow {
                let durationMinutes = Double(window.endMs - window.startMs) / 60_000.0
                HStack {
                    Text("Analysis Window")
                    Spacer()
                    Text("\(durationMinutes, specifier: "%.1f") min")
                        .foregroundColor(.secondary)
                }
                .font(.subheadline)

                HStack {
                    Text("Quality")
                    Spacer()
                    Text("\(window.qualityScore * 100, specifier: "%.0f")%")
                        .foregroundColor(.secondary)
                }
                .font(.subheadline)

                Text("Best 5-minute window from last 30 minutes")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                qualityRow("Artifact %", value: String(format: "%.1f%%", verification.metrics.artifactPercent),
                          isGood: verification.metrics.artifactPercent < 10)
                qualityRow("Clean Beats", value: "\(verification.metrics.nnCount)",
                          isGood: verification.metrics.nnCount >= 200)

                if !verification.errors.isEmpty {
                    ForEach(verification.errors, id: \.self) { error in
                        HStack {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                                .font(.caption)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }

                if !verification.warnings.isEmpty {
                    ForEach(verification.warnings, id: \.self) { warning in
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text(warning)
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private func qualityBadge(_ passed: Bool) -> some View {
        Text(passed ? "Good" : "Issues Found")
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background((passed ? Color.green : Color.orange).opacity(0.2))
            .foregroundColor(passed ? .green : .orange)
            .cornerRadius(8)
    }

    private func qualityRow(_ label: String, value: String, isGood: Bool) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: isGood ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundColor(isGood ? .green : .orange)
                    .font(.caption)
                Text(value)
            }
        }
        .font(.subheadline)
    }

    // MARK: - Quick Results Preview

    private func quickResultsPreview(session: HRVSession, result: HRVAnalysisResult) -> some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reading Complete")
                        .font(.headline)
                        .foregroundColor(AppTheme.sage)
                    Text(session.startDate, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.title)
                    .foregroundColor(AppTheme.sage)
            }

            // Key metrics in horizontal scroll
            HStack(spacing: 12) {
                QuickMetricCard(
                    title: "RMSSD",
                    value: String(format: "%.0f", result.timeDomain.rmssd),
                    unit: "ms",
                    color: AppTheme.primary
                )

                QuickMetricCard(
                    title: "HR",
                    value: String(format: "%.0f", result.timeDomain.meanHR),
                    unit: "bpm",
                    color: AppTheme.terracotta
                )

                if let readiness = result.ansMetrics?.readinessScore {
                    QuickMetricCard(
                        title: "Ready",
                        value: String(format: "%.1f", readiness),
                        unit: "/10",
                        color: AppTheme.readinessColor(readiness)
                    )
                } else {
                    QuickMetricCard(
                        title: "SDNN",
                        value: String(format: "%.0f", result.timeDomain.sdnn),
                        unit: "ms",
                        color: AppTheme.sdnnColor
                    )
                }
            }

            // View full report button
            Button(action: { showingQuickResults = true }) {
                HStack {
                    Text("View Full Report")
                    Spacer()
                    Image(systemName: "chart.xyaxis.line")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.zen(AppTheme.primary))

            // Quick dismiss
            Button(action: {
                collector.resetSession()
                selectedTags.removeAll()
                sessionNotes = ""
            }) {
                Text("Done")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.zenSecondary)
        }
        .zenCard()
    }

    private struct QuickMetricCard: View {
        let title: String
        let value: String
        let unit: String
        let color: Color

        var body: some View {
            VStack(spacing: 4) {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.system(.title2, design: .rounded).bold())
                        .foregroundColor(color)
                    Text(unit)
                        .font(.caption)
                        .foregroundColor(AppTheme.textTertiary)
                }
                Text(title)
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(AppTheme.sectionTint)
            .cornerRadius(AppTheme.smallCornerRadius)
        }
    }

    // MARK: - Results Section (Legacy - now using quickResultsPreview)

    private func resultsSection(session: HRVSession, result: HRVAnalysisResult) -> some View {
        VStack(spacing: 20) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title)
                VStack(alignment: .leading) {
                    Text("Analysis Complete")
                        .font(.headline)
                    Text(session.startDate, style: .date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                ResultMetricCard(title: "RMSSD", value: result.timeDomain.rmssd, unit: "ms", description: "Parasympathetic activity")
                ResultMetricCard(title: "SDNN", value: result.timeDomain.sdnn, unit: "ms", description: "Overall variability")
                ResultMetricCard(title: "Mean HR", value: result.timeDomain.meanHR, unit: "bpm", description: "Average heart rate")

                if let readiness = result.ansMetrics?.readinessScore {
                    ResultMetricCard(title: "Readiness", value: readiness, unit: "/10", description: "Recovery score")
                }
            }

            // Tags for this session
            VStack(alignment: .leading, spacing: 8) {
                Text("Tags")
                    .font(.subheadline.bold())

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(selectedTags)) { tag in
                            TagChip(tag: tag, isSelected: true, onTap: { toggleTag(tag) })
                        }
                        Button {
                            showingTagPicker = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                Text("Add Tag")
                            }
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(12)
                        }
                    }
                }
            }

            // Notes
            VStack(alignment: .leading, spacing: 8) {
                Text("Notes (optional)")
                    .font(.subheadline.bold())

                TextField("Add notes about this reading...", text: $sessionNotes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    // MARK: - Acceptance Section

    private var acceptanceSection: some View {
        VStack(spacing: 12) {
            Text("Save this reading?")
                .font(.headline)

            Text("Accepting will save the session and clear the H10 memory")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button(action: rejectSession) {
                    Label("Discard", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button(action: acceptSession) {
                    Label("Save", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    // MARK: - Actions

    private func toggleTag(_ tag: ReadingTag) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
    }

    private func startOvernightRecording() {
        Task {
            do {
                // Use overnight streaming mode (background audio keeps app alive)
                try collector.startOvernightStreaming(sessionType: .overnight)
            } catch {
                // Error handled via collector.lastError
            }
        }
    }


    private func stopAndFetch() {
        Task {
            // For overnight streaming mode - no download needed, data already in memory
            if collector.isOvernightStreaming {
                let session = await collector.stopOvernightStreaming()
                await MainActor.run {
                    if session?.state == .complete && session?.analysisResult != nil {
                        fetchFailed = false
                        // Navigate to dashboard after analysis completes
                        selectedTab = .dashboard
                    } else if session?.state == .failed {
                        fetchFailed = true
                    }
                }
                return
            }

            // Legacy: internal recording mode (fenced off) - requires download from H10
            // Keep screen on during download to prevent iOS from deprioritizing BLE
            await MainActor.run {
                UIApplication.shared.isIdleTimerDisabled = true
            }
            defer {
                Task { @MainActor in
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            }

            do {
                let session = try await collector.stopSession()
                await MainActor.run {
                    // Clear fetch failed state on success
                    if session?.state == .complete && session?.analysisResult != nil {
                        fetchFailed = false
                        // Navigate to dashboard after analysis completes
                        selectedTab = .dashboard
                    } else if session?.state == .failed {
                        fetchFailed = true
                    }
                }
            } catch {
                // Error handled via collector.lastError
                await MainActor.run {
                    fetchFailed = true
                }
            }
        }
    }

    private func retryFetch() {
        Task {
            // Keep screen on during download to prevent iOS from deprioritizing BLE
            await MainActor.run {
                UIApplication.shared.isIdleTimerDisabled = true
                isRetrying = true
            }
            defer {
                Task { @MainActor in
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            }

            do {
                let session = try await collector.retryFetchRecording()
                await MainActor.run {
                    isRetrying = false
                    if session?.state == .complete {
                        fetchFailed = false
                    }
                }
            } catch {
                await MainActor.run {
                    isRetrying = false
                    // Keep fetchFailed = true so user can retry again
                }
            }
        }
    }

    private func startStreaming(seconds: Int) {
        debugLog("startStreaming called with \(seconds) seconds")
        do {
            try collector.startStreamingSession(durationSeconds: seconds)
        } catch {
            debugLog("startStreaming error: \(error)")
        }
    }

    private func stopStreaming() {
        Task {
            let session = await collector.stopStreamingSession()
            // Update tags on the session
            if let session = session, !selectedTags.isEmpty {
                try? collector.archive.updateTags(session.id, tags: Array(selectedTags), notes: sessionNotes.isEmpty ? nil : sessionNotes)
            }
        }
    }

    private func acceptSession() {
        Task {
            // Update tags before accepting
            if let session = collector.currentSession {
                try? collector.archive.updateTags(session.id, tags: Array(selectedTags), notes: sessionNotes.isEmpty ? nil : sessionNotes)
            }
            try? await collector.acceptSession()
            await MainActor.run {
                selectedTags.removeAll()
                sessionNotes = ""
            }
        }
    }

    private func rejectSession() {
        Task {
            await collector.rejectSession()
            await MainActor.run {
                selectedTags.removeAll()
                sessionNotes = ""
            }
        }
    }

    // MARK: - Computed Properties

    private var currentHeartRate: Double? {
        let recentPoints = collector.polarManager.streamedRRPoints.suffix(5)
        guard recentPoints.count >= 2 else { return nil }
        let avgRR = recentPoints.map { Double($0.rr_ms) }.reduce(0, +) / Double(recentPoints.count)
        guard avgRR > 0 else { return nil }
        return 60000.0 / avgRR
    }

    private var streamingProgress: Double {
        let target = Double(collector.streamingTargetSeconds)
        let current = Double(collector.streamingElapsedSeconds)
        return min(1.0, current / target)
    }

    private var formattedStreamingTime: String {
        let elapsed = collector.streamingElapsedSeconds
        let remaining = max(0, collector.streamingTargetSeconds - elapsed)
        let minutes = remaining / 60
        let secs = remaining % 60
        return String(format: "%d:%02d", minutes, secs)
    }

    private var formattedElapsedTime: String {
        let seconds = collector.streamingElapsedSeconds
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Supporting Views

struct TagChip: View {
    let tag: ReadingTag
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(tag.name)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? tag.color : tag.color.opacity(0.15))
                .foregroundColor(isSelected ? .white : tag.color)
                .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}

private struct ResultMetricCard: View {
    let title: String
    let value: Double
    let unit: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.bold())
                .foregroundColor(.secondary)

            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(String(format: title == "Readiness" ? "%.1f" : "%.0f", value))
                    .font(.system(.title2, design: .rounded).bold())
                Text(unit)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(description)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }
}

struct TagPickerSheet: View {
    @Binding var selectedTags: Set<ReadingTag>
    let availableTags: [ReadingTag]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("System Tags") {
                    ForEach(ReadingTag.systemTags) { tag in
                        TagRow(tag: tag, isSelected: selectedTags.contains(tag)) {
                            toggleTag(tag)
                        }
                    }
                }

                let customTags = availableTags.filter { !$0.isSystem }
                if !customTags.isEmpty {
                    Section("Custom Tags") {
                        ForEach(customTags) { tag in
                            TagRow(tag: tag, isSelected: selectedTags.contains(tag)) {
                                toggleTag(tag)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func toggleTag(_ tag: ReadingTag) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
    }
}

private struct TagRow: View {
    let tag: ReadingTag
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Circle()
                    .fill(tag.color)
                    .frame(width: 12, height: 12)

                Text(tag.name)
                    .foregroundColor(.primary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.blue)
                }
            }
        }
    }
}

private struct MetricPreviewCard: View {
    let title: String
    let value: String
    let unit: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.title2, design: .rounded).bold())
                    .foregroundColor(color)
                Text(unit)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.tertiarySystemGroupedBackground))
        .cornerRadius(12)
    }
}

#Preview {
    NavigationStack {
        RecordView(selectedTab: .constant(.record))
            .environmentObject(RRCollector())
            .environmentObject(SettingsManager.shared)
    }
}
