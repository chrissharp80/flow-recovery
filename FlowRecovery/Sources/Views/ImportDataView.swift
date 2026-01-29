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
import UniformTypeIdentifiers

/// View for importing RR data from external files
struct ImportDataView: View {
    @EnvironmentObject var collector: RRCollector
    @Environment(\.dismiss) private var dismiss

    @State private var showingFilePicker = false
    @State private var importResult: RRDataImporter.ImportResult?
    @State private var eliteHRVResult: RRDataImporter.EliteHRVSummaryResult?
    @State private var flowHRVResult: RRDataImporter.FlowHRVMultiSessionResult?
    @State private var importedSession: HRVSession?
    @State private var isImporting = false
    @State private var isAnalyzing = false
    @State private var isSavingBatch = false
    @State private var errorMessage: String?
    @State private var showingResults = false
    @State private var batchImportProgress: (current: Int, total: Int)?
    @State private var importStatusMessage: String = ""
    @State private var importLogs: [String] = []

    private let importer = RRDataImporter()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    headerSection

                    // Format info
                    formatInfoSection

                    // Import button
                    importButtonSection

                    // Import result preview - Standard RR data
                    if let result = importResult {
                        importPreviewSection(result)
                    }

                    // Import result preview - Elite HRV summary
                    if let eliteResult = eliteHRVResult {
                        eliteHRVPreviewSection(eliteResult)
                    }

                    // Import result preview - Flow Recovery multi-session
                    if let flowResult = flowHRVResult {
                        flowHRVPreviewSection(flowResult)
                    }

                    // Import status/logs display
                    if isImporting || isAnalyzing || isSavingBatch || !importLogs.isEmpty {
                        importStatusSection
                    }

                    // Error display
                    if let error = errorMessage {
                        errorSection(error)
                    }
                }
                .padding()
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("Import Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.commaSeparatedText, .json, .plainText],
                allowsMultipleSelection: false
            ) { result in
                handleFileSelection(result)
            }
            .fullScreenCover(isPresented: $showingResults) {
                if let session = importedSession, let analysisResult = session.analysisResult {
                    NavigationStack {
                        MorningResultsView(
                            session: session,
                            result: analysisResult,
                            recentSessions: collector.archivedSessions,
                            onDiscard: {
                                importedSession = nil
                                importResult = nil
                                showingResults = false
                            }
                        )
                        .navigationTitle("Imported Reading")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") {
                                    Task {
                                        await saveImportedSession()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(AppTheme.primary.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 32))
                    .foregroundColor(AppTheme.primary)
            }

            Text("Import RR Data")
                .font(.title2.bold())
                .foregroundColor(AppTheme.textPrimary)

            Text("Import RR interval data from other HRV apps or devices to analyze with this app.")
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top)
    }

    // MARK: - Format Info

    private var formatInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Supported Formats")
                .font(.headline)
                .foregroundColor(AppTheme.textPrimary)

            ForEach(RRDataImporter.ImportFormat.allCases) { format in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: formatIcon(format))
                        .font(.body)
                        .foregroundColor(AppTheme.primary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(format.rawValue)
                            .font(.subheadline.bold())
                            .foregroundColor(AppTheme.textPrimary)
                        Text(format.description)
                            .font(.caption)
                            .foregroundColor(AppTheme.textTertiary)
                    }

                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
    }

    private func formatIcon(_ format: RRDataImporter.ImportFormat) -> String {
        switch format {
        case .csv: return "tablecells"
        case .json: return "curlybraces"
        case .txt: return "doc.text"
        case .kubios: return "waveform.path.ecg"
        case .eliteHRV: return "heart.text.square"
        case .flowHRVMultiSession: return "arrow.triangle.branch"
        }
    }

    // MARK: - Import Button

    private var importButtonSection: some View {
        Button {
            showingFilePicker = true
        } label: {
            HStack {
                if isImporting {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "folder.badge.plus")
                }
                Text(isImporting ? "Importing..." : "Select File")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.zen(AppTheme.primary))
        .disabled(isImporting)
    }

    // MARK: - Import Preview

    private func importPreviewSection(_ result: RRDataImporter.ImportResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(AppTheme.sage)
                Text("File Loaded Successfully")
                    .font(.headline)
                    .foregroundColor(AppTheme.textPrimary)
            }

            // File info
            VStack(spacing: 8) {
                ImportInfoRow(label: "File", value: result.originalFileName)
                ImportInfoRow(label: "Format", value: result.sourceFormat.rawValue)
                ImportInfoRow(label: "Beats", value: "\(result.beatCount)")
                ImportInfoRow(label: "Duration", value: String(format: "%.1f min", result.durationMinutes))

                if let date = result.recordingDate {
                    ImportInfoRow(label: "Recorded", value: formatDate(date))
                }
            }

            Divider()

            // Analyze button
            Button {
                Task {
                    await analyzeImportedData()
                }
            } label: {
                HStack {
                    if isAnalyzing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "waveform.path.ecg")
                    }
                    Text(isAnalyzing ? "Analyzing..." : "Analyze Data")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.zen(AppTheme.sage))
            .disabled(isAnalyzing)
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
    }

    // MARK: - Error Section

    private func errorSection(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(AppTheme.terracotta)

            VStack(alignment: .leading, spacing: 4) {
                Text("Import Error")
                    .font(.subheadline.bold())
                    .foregroundColor(AppTheme.terracotta)
                Text(message)
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }

            Spacer()

            Button {
                errorMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
        .padding()
        .background(AppTheme.terracotta.opacity(0.1))
        .cornerRadius(AppTheme.cornerRadius)
    }

    // MARK: - Elite HRV Preview

    private func eliteHRVPreviewSection(_ result: RRDataImporter.EliteHRVSummaryResult) -> some View {
        // Filter out sessions that already exist in the archive
        let newSessions = result.sessions.filter { session in
            !collector.archive.sessionExists(for: session.date)
        }
        let alreadyImportedCount = result.sessions.count - newSessions.count

        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(AppTheme.sage)
                Text("Elite HRV Summary Loaded")
                    .font(.headline)
                    .foregroundColor(AppTheme.textPrimary)
            }

            // Summary info
            VStack(spacing: 8) {
                ImportInfoRow(label: "File", value: result.originalFileName)
                ImportInfoRow(label: "Total Sessions", value: "\(result.sessions.count)")
                if alreadyImportedCount > 0 {
                    ImportInfoRow(label: "Already Imported", value: "\(alreadyImportedCount)")
                    ImportInfoRow(label: "New Sessions", value: "\(newSessions.count)")
                }

                if let firstDate = newSessions.first?.date,
                   let lastDate = newSessions.last?.date {
                    ImportInfoRow(label: "Date Range", value: formatDateRange(firstDate, lastDate))
                }

                // Average RMSSD of new sessions
                if !newSessions.isEmpty {
                    let avgRMSSD = newSessions.map(\.rmssd).reduce(0, +) / Double(newSessions.count)
                    ImportInfoRow(label: "Avg RMSSD", value: String(format: "%.1f ms", avgRMSSD))
                }
            }

            // Session list preview (show first few NEW sessions)
            if !newSessions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("New Sessions Preview")
                        .font(.subheadline.bold())
                        .foregroundColor(AppTheme.textPrimary)

                    ForEach(newSessions.prefix(5), id: \.date) { session in
                        HStack {
                            Text(formatDate(session.date))
                                .font(.caption)
                                .foregroundColor(AppTheme.textSecondary)
                            Spacer()
                            Text(String(format: "RMSSD: %.1f", session.rmssd))
                                .font(.caption.bold())
                                .foregroundColor(AppTheme.primary)
                            Text("\(session.beatCount) beats")
                                .font(.caption)
                                .foregroundColor(AppTheme.textTertiary)
                        }
                    }

                    if newSessions.count > 5 {
                        Text("...and \(newSessions.count - 5) more")
                            .font(.caption)
                            .foregroundColor(AppTheme.textTertiary)
                            .italic()
                    }
                }
                .padding(.vertical, 8)

                Divider()
            }

            // Import button - only show if there are new sessions
            if newSessions.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(AppTheme.sage)
                    Text("All sessions already imported")
                        .font(.subheadline)
                        .foregroundColor(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                Button {
                    Task {
                        await importAllEliteHRVSessions()
                    }
                } label: {
                    HStack {
                        if isSavingBatch {
                            ProgressView()
                                .tint(.white)
                            if let progress = batchImportProgress {
                                Text("Importing \(progress.current)/\(progress.total)...")
                            }
                        } else {
                            Image(systemName: "square.and.arrow.down.on.square")
                            Text("Import \(newSessions.count) New Sessions")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.zen(AppTheme.sage))
                .disabled(isSavingBatch)
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
    }

    private func formatDateRange(_ start: Date, _ end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return "\(formatter.string(from: start)) - \(formatter.string(from: end))"
    }

    // MARK: - Flow Recovery Multi-Session Preview

    private func flowHRVPreviewSection(_ result: RRDataImporter.FlowHRVMultiSessionResult) -> some View {
        // Log session dates for debugging
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        log("=== Import Session Dates ===")
        for session in result.sessions {
            log("Session: \(session.sessionDate) -> Parsed: \(dateFormatter.string(from: session.date)) (\(session.beatCount) beats)")
        }

        log("=== Archive Index Dates ===")
        for entry in collector.archive.entries.prefix(20) {
            log("Archive: \(dateFormatter.string(from: entry.date)) - ID: \(entry.sessionId.uuidString.prefix(8))")
        }
        if collector.archive.entries.count > 20 {
            log("... and \(collector.archive.entries.count - 20) more archive entries")
        }

        // Filter out sessions that already exist in the archive
        let newSessions = result.sessions.filter { session in
            let exists = collector.archive.sessionExists(for: session.date)
            if exists {
                log("DUPLICATE: \(session.sessionDate) matches existing archive entry")
            }
            return !exists
        }
        let alreadyImportedCount = result.sessions.count - newSessions.count

        log("Result: \(newSessions.count) new, \(alreadyImportedCount) duplicates")

        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(AppTheme.sage)
                Text("Flow Recovery Export Loaded")
                    .font(.headline)
                    .foregroundColor(AppTheme.textPrimary)
            }

            // Summary info
            VStack(spacing: 8) {
                ImportInfoRow(label: "File", value: result.originalFileName)
                ImportInfoRow(label: "Total Sessions", value: "\(result.sessions.count)")
                if alreadyImportedCount > 0 {
                    ImportInfoRow(label: "Already Imported", value: "\(alreadyImportedCount)")
                    ImportInfoRow(label: "New Sessions", value: "\(newSessions.count)")
                }

                if let firstDate = newSessions.first?.date,
                   let lastDate = newSessions.last?.date {
                    ImportInfoRow(label: "Date Range", value: formatDateRange(firstDate, lastDate))
                }

                // Total beats
                let totalBeats = newSessions.reduce(0) { $0 + $1.beatCount }
                ImportInfoRow(label: "Total RR Intervals", value: "\(totalBeats)")

                // Average duration
                if !newSessions.isEmpty {
                    let avgDuration = newSessions.map(\.durationMinutes).reduce(0, +) / Double(newSessions.count)
                    ImportInfoRow(label: "Avg Duration", value: String(format: "%.1f min", avgDuration))
                }
            }

            // Session list preview (show first few NEW sessions)
            if !newSessions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("New Sessions Preview")
                        .font(.subheadline.bold())
                        .foregroundColor(AppTheme.textPrimary)

                    ForEach(newSessions.prefix(5), id: \.sessionDate) { session in
                        HStack {
                            Text(formatDate(session.date))
                                .font(.caption)
                                .foregroundColor(AppTheme.textSecondary)
                            Spacer()
                            Text("\(session.beatCount) beats")
                                .font(.caption.bold())
                                .foregroundColor(AppTheme.primary)
                            Text(String(format: "%.1f min", session.durationMinutes))
                                .font(.caption)
                                .foregroundColor(AppTheme.textTertiary)
                        }
                    }

                    if newSessions.count > 5 {
                        Text("...and \(newSessions.count - 5) more")
                            .font(.caption)
                            .foregroundColor(AppTheme.textTertiary)
                            .italic()
                    }
                }
                .padding(.vertical, 8)

                Divider()

                // Note about full analysis
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(AppTheme.primary)
                    Text("Each session will be fully analyzed with artifact detection and HRV metrics calculation.")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)
                }
                .padding(.vertical, 4)
            }

            // Import button - only show if there are new sessions
            if newSessions.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(AppTheme.sage)
                    Text("All sessions already imported")
                        .font(.subheadline)
                        .foregroundColor(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                Button {
                    Task {
                        await importAllFlowHRVSessions()
                    }
                } label: {
                    HStack {
                        if isSavingBatch {
                            ProgressView()
                                .tint(.white)
                            if let progress = batchImportProgress {
                                Text("Analyzing \(progress.current)/\(progress.total)...")
                            }
                        } else {
                            Image(systemName: "square.and.arrow.down.on.square")
                            Text("Import & Analyze \(newSessions.count) Sessions")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.zen(AppTheme.sage))
                .disabled(isSavingBatch)
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
    }

    // MARK: - Import Status Section

    private var importStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if isImporting || isAnalyzing || isSavingBatch {
                    ProgressView()
                        .scaleEffect(0.8)
                }
                Text(importStatusMessage.isEmpty ? "Processing..." : importStatusMessage)
                    .font(.subheadline.bold())
                    .foregroundColor(AppTheme.textPrimary)
                Spacer()

                // Clear logs button when not actively processing
                if !isImporting && !isAnalyzing && !isSavingBatch && !importLogs.isEmpty {
                    Button {
                        importLogs = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(AppTheme.textTertiary)
                    }
                }
            }

            // Log display
            if !importLogs.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(importLogs.enumerated()), id: \.offset) { _, log in
                            Text(log)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(log.contains("ERROR") || log.contains("FAIL") ? AppTheme.terracotta :
                                                    log.contains("SUCCESS") || log.contains("COMPLETE") ? AppTheme.sage :
                                                    AppTheme.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .padding(8)
                .background(Color.black.opacity(0.05))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
    }

    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logEntry = "[\(timestamp)] \(message)"
        debugLog("[Import] \(message)")  // Also print to console
        Task { @MainActor in
            importLogs.append(logEntry)
            // Keep only last 50 logs
            if importLogs.count > 50 {
                importLogs.removeFirst()
            }
        }
    }

    private func updateStatus(_ message: String) {
        Task { @MainActor in
            importStatusMessage = message
        }
        log(message)
    }

    // MARK: - Actions

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        errorMessage = nil
        importResult = nil
        eliteHRVResult = nil
        flowHRVResult = nil
        importLogs = []

        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            isImporting = true

            Task {
                do {
                    updateStatus("Opening file: \(url.lastPathComponent)")

                    // First, check if it's Elite HRV format by reading the file
                    guard url.startAccessingSecurityScopedResource() else {
                        log("ERROR: Cannot access file - security scope denied")
                        throw RRDataImporter.ImportError.fileNotFound
                    }
                    defer { url.stopAccessingSecurityScopedResource() }

                    log("Reading file contents...")
                    guard let data = try? Data(contentsOf: url) else {
                        log("ERROR: Failed to read file data")
                        throw RRDataImporter.ImportError.unreadableFile
                    }

                    log("File size: \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")

                    guard let content = String(data: data, encoding: .utf8) else {
                        log("ERROR: Cannot decode file as UTF-8 text")
                        throw RRDataImporter.ImportError.unreadableFile
                    }

                    let lineCount = content.components(separatedBy: .newlines).count
                    log("File has \(lineCount) lines")

                    // Check for Flow Recovery multi-session RR export format first
                    if importer.isFlowHRVMultiSession(content) {
                        log("Detected Flow Recovery multi-session RR export format")
                        updateStatus("Parsing Flow Recovery sessions...")

                        let flowResult = try importer.parseFlowHRVMultiSession(content, fileName: url.lastPathComponent)
                        log("SUCCESS: Found \(flowResult.sessions.count) sessions with raw RR data")

                        let totalBeats = flowResult.sessions.reduce(0) { $0 + $1.beatCount }
                        log("Total RR intervals: \(totalBeats)")

                        await MainActor.run {
                            flowHRVResult = flowResult
                            isImporting = false
                            importStatusMessage = "Ready to import \(flowResult.sessions.count) sessions"
                        }
                    }
                    // Check for Elite HRV format
                    else if importer.isEliteHRVSummary(content) {
                        log("Detected Elite HRV summary format")
                        updateStatus("Parsing Elite HRV summary...")

                        let eliteResult = try importer.parseEliteHRVSummary(content, fileName: url.lastPathComponent)
                        log("SUCCESS: Parsed \(eliteResult.sessions.count) sessions")

                        await MainActor.run {
                            eliteHRVResult = eliteResult
                            isImporting = false
                            importStatusMessage = "Ready to import \(eliteResult.sessions.count) sessions"
                        }
                    } else {
                        log("Detected standard RR data format")
                        updateStatus("Parsing RR intervals...")

                        let importedResult = try await importer.importFile(at: url)
                        log("SUCCESS: Found \(importedResult.beatCount) RR intervals")
                        log("Duration: \(String(format: "%.1f", importedResult.durationMinutes)) minutes")
                        log("Format: \(importedResult.sourceFormat.rawValue)")

                        await MainActor.run {
                            importResult = importedResult
                            isImporting = false
                            importStatusMessage = "File loaded - \(importedResult.beatCount) beats"
                        }
                    }
                } catch {
                    log("ERROR: \(error.localizedDescription)")
                    await MainActor.run {
                        errorMessage = error.localizedDescription
                        isImporting = false
                        importStatusMessage = "Import failed"
                    }
                }
            }

        case .failure(let error):
            log("ERROR: File picker error - \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    private func analyzeImportedData() async {
        guard let result = importResult else { return }

        await MainActor.run {
            isAnalyzing = true
        }

        updateStatus("Creating session from imported data...")
        log("Source file: \(result.originalFileName)")
        log("RR intervals: \(result.beatCount)")

        // Create session from import
        var session = importer.createSession(from: result)
        log("Session created with \(session.rrSeries?.points.count ?? 0) points")

        // Run artifact detection and analysis
        // This reuses the same pipeline as live recordings
        guard let series = session.rrSeries else {
            log("ERROR: No RR series in session")
            await MainActor.run {
                errorMessage = "Analysis failed - no RR data"
                isAnalyzing = false
            }
            return
        }

        updateStatus("Detecting artifacts...")
        let detector = ArtifactDetector()
        let flags = detector.detectArtifacts(in: series)
        session.artifactFlags = flags

        let artifactCount = flags.filter { $0.isArtifact }.count
        let artifactPct = Double(artifactCount) / Double(flags.count) * 100
        log("Artifacts detected: \(artifactCount)/\(flags.count) (\(String(format: "%.1f", artifactPct))%)")

        if artifactPct > 25 {
            log("WARNING: High artifact percentage may affect analysis quality")
        }

        updateStatus("Running HRV analysis...")
        log("Computing time domain metrics...")

        // Use the same analysis pipeline as overnight recordings
        let windowSelector = WindowSelector()

        // Find best window (for short recordings, analyzes all data)
        let window = windowSelector.findBestWindow(in: series, flags: flags)

        // Determine analysis window
        let windowStart = window?.startIndex ?? 0
        let windowEnd = window?.endIndex ?? series.points.count

        // Run time domain analysis
        guard let timeDomain = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: windowStart,
            windowEnd: windowEnd
        ) else {
            log("ERROR: Time domain analysis failed")
            await MainActor.run {
                errorMessage = "Analysis failed - insufficient clean data"
                isAnalyzing = false
            }
            return
        }

        // Run frequency domain
        let frequencyDomain = FrequencyDomainAnalyzer.computeFrequencyDomain(
            series,
            flags: flags,
            windowStart: windowStart,
            windowEnd: windowEnd
        )

        // Run nonlinear analysis
        guard let nonlinear = NonlinearAnalyzer.computeNonlinear(
            series,
            flags: flags,
            windowStart: windowStart,
            windowEnd: windowEnd
        ) else {
            log("ERROR: Nonlinear analysis failed")
            await MainActor.run {
                errorMessage = "Analysis failed - insufficient clean data"
                isAnalyzing = false
            }
            return
        }

        // Extract clean RR intervals for stress analysis
        var cleanRR: [Double] = []
        for i in windowStart..<windowEnd {
            if !flags[i].isArtifact {
                cleanRR.append(Double(series.points[i].rr_ms))
            }
        }

        // Compute stress metrics
        let stressIndex = StressAnalyzer.computeStressIndex(cleanRR)
        let respirationRate = RespirationAnalyzer.estimateRespirationRate(cleanRR)

        // Calculate artifact percentage for the analysis window
        let windowArtifactCount = flags[windowStart..<windowEnd].filter { $0.isArtifact }.count
        let artifactPercentage = Double(windowArtifactCount) / Double(windowEnd - windowStart) * 100

        let analysisResult = HRVAnalysisResult(
            windowStart: windowStart,
            windowEnd: windowEnd,
            timeDomain: timeDomain,
            frequencyDomain: frequencyDomain,
            nonlinear: nonlinear,
            ansMetrics: ANSMetrics(
                stressIndex: stressIndex,
                pnsIndex: nil,
                snsIndex: nil,
                readinessScore: nil,
                respirationRate: respirationRate,
                nocturnalHRDip: nil,
                daytimeRestingHR: nil,
                nocturnalMedianHR: nil
            ),
            artifactPercentage: artifactPercentage,
            cleanBeatCount: cleanRR.count,
            analysisDate: Date()
        )

        session.analysisResult = analysisResult
        session.state = .complete
        session.recoveryScore = window?.recoveryScore

        log("SUCCESS: Analysis complete")
        log("RMSSD: \(String(format: "%.1f", analysisResult.timeDomain.rmssd)) ms")
        log("Clean beats: \(analysisResult.cleanBeatCount)")
        if let score = session.recoveryScore {
            log("Readiness score: \(String(format: "%.1f", score))")
        }

        await MainActor.run {
            importedSession = session
            isAnalyzing = false
            importStatusMessage = "Analysis complete"
            showingResults = true
        }
    }

    private func saveImportedSession() async {
        guard let session = importedSession else { return }

        do {
            try await collector.saveImportedSession(session)
            await MainActor.run {
                showingResults = false
                dismiss()
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to save: \(error.localizedDescription)"
                showingResults = false
            }
        }
    }

    private func importAllEliteHRVSessions() async {
        guard let eliteResult = eliteHRVResult else { return }

        await MainActor.run {
            isSavingBatch = true
            batchImportProgress = (0, eliteResult.sessions.count)
        }

        updateStatus("Preparing batch import of \(eliteResult.sessions.count) sessions...")
        log("Source: \(eliteResult.originalFileName)")
        log("Using Elite HRV's pre-computed metrics directly (no re-analysis)")

        let startTime = Date()

        // Create all sessions first (fast, in-memory)
        var sessions: [HRVSession] = []
        for (index, summary) in eliteResult.sessions.enumerated() {
            await MainActor.run {
                batchImportProgress = (index + 1, eliteResult.sessions.count)
            }

            if index % 50 == 0 {
                updateStatus("Creating sessions: \(index + 1)/\(eliteResult.sessions.count)")
            }

            let session = importer.createAnalyzedSession(
                from: summary,
                originalFileName: eliteResult.originalFileName
            )
            sessions.append(session)
        }

        log("Created \(sessions.count) sessions in memory")
        updateStatus("Saving to archive...")

        // Batch save all sessions at once
        do {
            let processedCount = try await collector.saveImportedSessionsBatch(sessions)
            let unchangedCount = sessions.count - processedCount

            let elapsed = Date().timeIntervalSince(startTime)
            log("Batch import completed in \(String(format: "%.1f", elapsed))s")
            log("Results: \(processedCount) processed (new + updated), \(unchangedCount) unchanged")

            await MainActor.run {
                isSavingBatch = false
                batchImportProgress = nil

                if processedCount > 0 {
                    log("SUCCESS: Processed \(processedCount) sessions with Elite HRV metrics")
                    importStatusMessage = "COMPLETE: \(processedCount) sessions imported/updated"
                    if unchangedCount > 0 {
                        log("Note: \(unchangedCount) sessions were already up to date")
                    }
                    // Don't dismiss immediately so user can see the success log
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.dismiss()
                    }
                } else if unchangedCount > 0 {
                    importStatusMessage = "All \(unchangedCount) sessions already up to date"
                    log("All sessions were already imported with same data")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.dismiss()
                    }
                } else {
                    errorMessage = "No valid sessions to import"
                    importStatusMessage = "Import failed"
                }
            }
        } catch {
            log("FAIL: Batch save error: \(error.localizedDescription)")
            await MainActor.run {
                isSavingBatch = false
                batchImportProgress = nil
                errorMessage = "Failed to save sessions: \(error.localizedDescription)"
                importStatusMessage = "Import failed"
            }
        }
    }

    private func importAllFlowHRVSessions() async {
        guard let flowResult = flowHRVResult else {
            log("ERROR: flowHRVResult is nil")
            return
        }

        log("=== IMPORT START ===")
        log("Total sessions in CSV: \(flowResult.sessions.count)")

        // Log all sessions from CSV
        for (i, session) in flowResult.sessions.enumerated() {
            log("CSV[\(i)]: date=\(session.sessionDate) parsed=\(session.date) beats=\(session.beatCount)")
        }

        // Log archive state
        log("Archive has \(collector.archive.entries.count) entries")
        for entry in collector.archive.entries {
            log("Archive: \(entry.date) ID=\(entry.sessionId.uuidString.prefix(8))")
        }

        // Filter to only new sessions
        log("=== DUPLICATE CHECK ===")
        var newSessions: [RRDataImporter.FlowHRVMultiSessionResult.SessionRRData] = []
        for session in flowResult.sessions {
            let exists = collector.archive.sessionExists(for: session.date)
            log("Check \(session.sessionDate): exists=\(exists)")
            if !exists {
                newSessions.append(session)
            }
        }

        log("New sessions after filter: \(newSessions.count)")

        guard !newSessions.isEmpty else {
            log("ERROR: No new sessions to import - all filtered as duplicates")
            await MainActor.run {
                importStatusMessage = "All sessions already imported"
            }
            return
        }

        await MainActor.run {
            isSavingBatch = true
            batchImportProgress = (0, newSessions.count)
        }

        log("=== ANALYSIS START ===")
        updateStatus("Preparing to import \(newSessions.count) sessions with full HRV analysis...")

        let startTime = Date()
        var analyzedSessions: [HRVSession] = []
        var failedCount = 0

        // HealthKit manager for fetching sleep data
        let healthKit = HealthKitManager()

        // Process each session - run analysis on background thread per session
        for (index, sessionData) in newSessions.enumerated() {
            // Update progress on main thread
            await MainActor.run {
                batchImportProgress = (index + 1, newSessions.count)
            }
            log("Analyzing[\(index)]: \(sessionData.sessionDate) with \(sessionData.beatCount) beats")

            // Fetch HealthKit sleep data for this session's date (before Task.detached)
            var sleepStartMs: Int64? = nil
            var wakeTimeMs: Int64? = nil
            let sessionStartDate = sessionData.date
            let sessionDurationMs = sessionData.rrIntervals.reduce(0, +)
            let sessionEndDate = sessionStartDate.addingTimeInterval(Double(sessionDurationMs) / 1000.0)

            do {
                let sleepData = try await healthKit.fetchSleepData(for: sessionStartDate, recordingEnd: sessionEndDate)
                if let sleepStart = sleepData.sleepStart {
                    sleepStartMs = Int64(sleepStart.timeIntervalSince(sessionStartDate) * 1000)
                    log("  HealthKit sleep start: \(sleepStart) (\(sleepStartMs! / 60000) min into recording)")
                } else {
                    log("  HealthKit: no sleep start found")
                }
                if let sleepEnd = sleepData.sleepEnd {
                    wakeTimeMs = Int64(sleepEnd.timeIntervalSince(sessionStartDate) * 1000)
                    log("  HealthKit wake time: \(sleepEnd) (\(wakeTimeMs! / 60000) min into recording)")
                } else {
                    log("  HealthKit: no wake time found")
                }
                if sleepStartMs == nil && wakeTimeMs == nil {
                    log("  HealthKit: NO SLEEP DATA for this date - using full recording as sleep period")
                }
            } catch {
                log("  HealthKit ERROR: \(error.localizedDescription)")
            }

            // Create session with RR data
            var session = importer.createSessionFromFlowHRVData(
                sessionData,
                originalFileName: flowResult.originalFileName
            )

            // Use the same analysis pipeline as overnight recordings
            guard let series = session.rrSeries else {
                log("  FAILED: No RR series")
                failedCount += 1
                continue
            }

            // Detect artifacts
            let artifactDetector = ArtifactDetector()
            let flags = artifactDetector.detectArtifacts(in: series)
            session.artifactFlags = flags

            // Find best window with HealthKit sleep data
            let windowSelector = WindowSelector()
            let window = windowSelector.findBestWindow(
                in: series,
                flags: flags,
                sleepStartMs: sleepStartMs,
                wakeTimeMs: wakeTimeMs
            )

            // Log window selection result
            if let w = window {
                log("  Window found: \(w.selectionReason)")
                log("  Window position: \(String(format: "%.0f", (w.relativePosition ?? 0) * 100))%, classification: \(w.windowClassification.rawValue)")
                log("  Recovery score: \(String(format: "%.1f", w.recoveryScore ?? -1))")
            } else {
                log("  WARNING: No organized recovery window found - recovery score will be nil")
                log("  (WindowSelector returns nil when no window has DFA α1 in 0.75-1.0 range)")
            }

            // Determine analysis window
            let windowStart = window?.startIndex ?? 0
            let windowEnd = window?.endIndex ?? series.points.count

            // Run time domain analysis
            guard let timeDomain = TimeDomainAnalyzer.computeTimeDomain(
                series,
                flags: flags,
                windowStart: windowStart,
                windowEnd: windowEnd
            ) else {
                log("  FAILED: Time domain analysis failed")
                failedCount += 1
                continue
            }

            // Run frequency domain
            let frequencyDomain = FrequencyDomainAnalyzer.computeFrequencyDomain(
                series,
                flags: flags,
                windowStart: windowStart,
                windowEnd: windowEnd
            )

            // Run nonlinear analysis
            guard let nonlinear = NonlinearAnalyzer.computeNonlinear(
                series,
                flags: flags,
                windowStart: windowStart,
                windowEnd: windowEnd
            ) else {
                log("  FAILED: Nonlinear analysis failed")
                failedCount += 1
                continue
            }

            // Extract clean RR intervals for stress analysis
            var cleanRR: [Double] = []
            for i in windowStart..<windowEnd {
                if !flags[i].isArtifact {
                    cleanRR.append(Double(series.points[i].rr_ms))
                }
            }

            // Compute stress metrics
            let stressIndex = StressAnalyzer.computeStressIndex(cleanRR)
            let respirationRate = RespirationAnalyzer.estimateRespirationRate(cleanRR)

            // Calculate artifact percentage
            let artifactCount = flags[windowStart..<windowEnd].filter { $0.isArtifact }.count
            let artifactPercentage = Double(artifactCount) / Double(windowEnd - windowStart) * 100

            var analysisResult = HRVAnalysisResult(
                windowStart: windowStart,
                windowEnd: windowEnd,
                timeDomain: timeDomain,
                frequencyDomain: frequencyDomain,
                nonlinear: nonlinear,
                ansMetrics: ANSMetrics(
                    stressIndex: stressIndex,
                    pnsIndex: nil,
                    snsIndex: nil,
                    readinessScore: nil,
                    respirationRate: respirationRate,
                    nocturnalHRDip: nil,
                    daytimeRestingHR: nil,
                    nocturnalMedianHR: nil
                ),
                artifactPercentage: artifactPercentage,
                cleanBeatCount: cleanRR.count,
                analysisDate: Date()
            )

            // Add window metadata if we found a window
            if let w = window {
                analysisResult.windowStartMs = series.points[w.startIndex].t_ms
                analysisResult.windowEndMs = series.points[w.endIndex - 1].endMs
                analysisResult.windowMeanHR = w.meanHR
                analysisResult.windowHRStability = w.hrStability
                analysisResult.windowSelectionReason = w.selectionReason
                analysisResult.windowRelativePosition = w.relativePosition
                analysisResult.windowClassification = w.windowClassification.rawValue
                analysisResult.isOrganizedRecovery = w.windowClassification == .organizedRecovery
            }

            session.analysisResult = analysisResult
            session.state = .complete
            session.recoveryScore = window?.recoveryScore
            log("  SUCCESS: RMSSD=\(String(format: "%.1f", analysisResult.timeDomain.rmssd))")
            analyzedSessions.append(session)

            // Yield to keep UI responsive between sessions
            await Task.yield()
        }

        log("=== ANALYSIS COMPLETE ===")
        log("Analyzed: \(analyzedSessions.count) success, \(failedCount) failed")

        // Batch save all analyzed sessions
        log("=== SAVING TO ARCHIVE ===")
        updateStatus("Saving \(analyzedSessions.count) sessions to archive...")

        do {
            log("Calling saveImportedSessionsBatch with \(analyzedSessions.count) sessions")
            let processedCount = try await collector.saveImportedSessionsBatch(analyzedSessions)
            let unchangedCount = analyzedSessions.count - processedCount

            let elapsed = Date().timeIntervalSince(startTime)
            log("=== SAVE COMPLETE ===")
            log("Time: \(String(format: "%.1f", elapsed))s")
            log("Saved: \(processedCount), Unchanged: \(unchangedCount), Failed: \(failedCount)")

            // Verify archive state after save
            log("Archive now has \(collector.archive.entries.count) entries")

            await MainActor.run {
                isSavingBatch = false
                batchImportProgress = nil

                if processedCount > 0 {
                    log("SUCCESS: Import complete!")
                    importStatusMessage = "COMPLETE: \(processedCount) sessions imported"

                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self.dismiss()
                    }
                } else if unchangedCount > 0 {
                    importStatusMessage = "All \(unchangedCount) sessions already up to date"
                    log("All sessions were already imported")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.dismiss()
                    }
                } else {
                    log("ERROR: No valid sessions saved!")
                    errorMessage = "No valid sessions to import"
                    importStatusMessage = "Import failed"
                }
            }
        } catch {
            log("ERROR: Save failed: \(error)")
            await MainActor.run {
                isSavingBatch = false
                batchImportProgress = nil
                errorMessage = "Failed to save sessions: \(error.localizedDescription)"
                importStatusMessage = "Import failed"
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Import Info Row

private struct ImportInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline.bold())
                .foregroundColor(AppTheme.textPrimary)
        }
    }
}

#Preview {
    ImportDataView()
        .environmentObject(RRCollector())
}
