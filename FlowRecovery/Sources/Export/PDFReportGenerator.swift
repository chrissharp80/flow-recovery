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
import PDFKit
import UIKit

/// Generates professional PDF reports for HRV analysis results
/// Includes Poincaré plot, PSD graph, and tachogram visualizations
final class PDFReportGenerator {

    // MARK: - Configuration

    /// Sleep data from HealthKit (passed in for accurate reporting)
    struct SleepData {
        let sleepStart: Date?
        let sleepEnd: Date?
        let totalSleepMinutes: Int
        let inBedMinutes: Int
        let deepSleepMinutes: Int?
        let remSleepMinutes: Int?
        let awakeMinutes: Int
        let sleepEfficiency: Double

        var totalSleepFormatted: String {
            let hours = totalSleepMinutes / 60
            let mins = totalSleepMinutes % 60
            return hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
        }

        var deepSleepFormatted: String? {
            guard let deep = deepSleepMinutes else { return nil }
            let hours = deep / 60
            let mins = deep % 60
            return hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
        }

        static let empty = SleepData(
            sleepStart: nil, sleepEnd: nil,
            totalSleepMinutes: 0, inBedMinutes: 0,
            deepSleepMinutes: nil, remSleepMinutes: nil,
            awakeMinutes: 0, sleepEfficiency: 0
        )

        init(sleepStart: Date? = nil, sleepEnd: Date? = nil, totalSleepMinutes: Int, inBedMinutes: Int, deepSleepMinutes: Int?, remSleepMinutes: Int?, awakeMinutes: Int, sleepEfficiency: Double) {
            self.sleepStart = sleepStart
            self.sleepEnd = sleepEnd
            self.totalSleepMinutes = totalSleepMinutes
            self.inBedMinutes = inBedMinutes
            self.deepSleepMinutes = deepSleepMinutes
            self.remSleepMinutes = remSleepMinutes
            self.awakeMinutes = awakeMinutes
            self.sleepEfficiency = sleepEfficiency
        }

        init(from healthKit: HealthKitManager.SleepData?) {
            guard let hk = healthKit else {
                self = .empty
                return
            }
            self.sleepStart = hk.sleepStart
            self.sleepEnd = hk.sleepEnd
            self.totalSleepMinutes = hk.totalSleepMinutes
            self.inBedMinutes = hk.inBedMinutes
            self.deepSleepMinutes = hk.deepSleepMinutes
            self.remSleepMinutes = hk.remSleepMinutes
            self.awakeMinutes = hk.awakeMinutes
            self.sleepEfficiency = hk.sleepEfficiency
        }
    }

    struct SleepTrendData {
        let averageSleepMinutes: Double
        let averageDeepSleepMinutes: Double?
        let averageEfficiency: Double
        let trend: AnalysisSummaryGenerator.SleepTrendInput.SleepTrend
        let nightsAnalyzed: Int

        static let empty = SleepTrendData(
            averageSleepMinutes: 0, averageDeepSleepMinutes: nil,
            averageEfficiency: 0, trend: .insufficient, nightsAnalyzed: 0
        )

        init(averageSleepMinutes: Double, averageDeepSleepMinutes: Double?, averageEfficiency: Double, trend: AnalysisSummaryGenerator.SleepTrendInput.SleepTrend, nightsAnalyzed: Int) {
            self.averageSleepMinutes = averageSleepMinutes
            self.averageDeepSleepMinutes = averageDeepSleepMinutes
            self.averageEfficiency = averageEfficiency
            self.trend = trend
            self.nightsAnalyzed = nightsAnalyzed
        }

        init(from healthKit: HealthKitManager.SleepTrendStats?) {
            guard let hk = healthKit else {
                self = .empty
                return
            }
            self.averageSleepMinutes = hk.averageSleepMinutes
            self.averageDeepSleepMinutes = hk.averageDeepSleepMinutes
            self.averageEfficiency = hk.averageEfficiency
            self.nightsAnalyzed = hk.nightsAnalyzed
            switch hk.trend {
            case .improving: self.trend = .improving
            case .declining: self.trend = .declining
            case .stable: self.trend = .stable
            case .insufficient: self.trend = .insufficient
            }
        }
    }

    struct Config {
        var pageSize: CGSize = CGSize(width: 612, height: 792)  // Letter size
        var margins: UIEdgeInsets = UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40)
        var titleFont: UIFont = .systemFont(ofSize: 22, weight: .bold)
        var headingFont: UIFont = .systemFont(ofSize: 14, weight: .semibold)
        var subheadingFont: UIFont = .systemFont(ofSize: 11, weight: .medium)
        var bodyFont: UIFont = .systemFont(ofSize: 10)
        var captionFont: UIFont = .systemFont(ofSize: 8)
        var monoFont: UIFont = .monospacedSystemFont(ofSize: 9, weight: .regular)

        // Colors
        var primaryColor: UIColor = UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1.0)
        var secondaryColor: UIColor = UIColor(red: 0.3, green: 0.7, blue: 0.4, alpha: 1.0)
        var accentColor: UIColor = UIColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 1.0)
    }

    private let config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    // MARK: - Public API

    /// Generate PDF report for an HRV session
    /// Supports both full sessions (with RR series) and summary-only sessions (imported data)
    /// - Parameters:
    ///   - session: The HRV session to generate a report for
    ///   - flags: Optional artifact flags
    ///   - sleepData: HealthKit sleep data for accurate sleep reporting
    ///   - sleepTrend: Sleep trend data for context
    ///   - recentSessions: Recent sessions for trend comparison
    func generateReport(for session: HRVSession,
                        flags: [ArtifactFlags]? = nil,
                        sleepData: SleepData? = nil,
                        sleepTrend: SleepTrendData? = nil,
                        recentSessions: [HRVSession] = [],
                        healthKitHR: (mean: Double, min: Double, max: Double, nadirTime: Date)? = nil) -> Data? {
        guard let result = session.analysisResult else { return nil }

        let series = session.rrSeries  // Optional - may be nil for imported data
        let artifactFlags = flags ?? session.artifactFlags ?? []
        let hasRawData = series != nil && !series!.points.isEmpty

        // Store sleep data for use in drawing methods
        let healthKitSleep = sleepData
        let healthKitSleepTrend = sleepTrend
        let sessions = recentSessions

        let pdfMetaData = [
            kCGPDFContextCreator: "Flow Recovery",
            kCGPDFContextTitle: "HRV Analysis Report",
            kCGPDFContextAuthor: "Flow Recovery"
        ]

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = pdfMetaData as [String: Any]

        let pageRect = CGRect(origin: .zero, size: config.pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)

        let data = renderer.pdfData { context in
            var pageNumber = 1

            // Page 1: Header, Summary, Key Metrics
            context.beginPage()
            var yPosition = drawHeader(session: session, result: result, in: context, pageRect: pageRect)
            yPosition = drawSummaryCard(result: result, ans: result.ansMetrics, yPosition: yPosition, in: context, pageRect: pageRect)

            // Overnight stats (sleep, nadir, peak HRV) if we have raw data
            if hasRawData, let series = series {
                yPosition = drawOvernightStatsSection(series: series, result: result, session: session,
                                                       sleepData: healthKitSleep,
                                                       healthKitHR: healthKitHR,
                                                       yPosition: yPosition, in: context, pageRect: pageRect)
            }

            yPosition = drawTimeDomainSection(result.timeDomain, yPosition: yPosition, in: context, pageRect: pageRect)

            if let fd = result.frequencyDomain {
                yPosition = drawFrequencyDomainSection(fd, yPosition: yPosition, in: context, pageRect: pageRect)
            }

            yPosition = drawNonlinearSection(result.nonlinear, yPosition: yPosition, in: context, pageRect: pageRect)

            if let ans = result.ansMetrics {
                yPosition = drawANSSection(ans, yPosition: yPosition, in: context, pageRect: pageRect)
            }

            // Tags & Notes
            if !session.tags.isEmpty || session.notes != nil {
                yPosition = drawTagsAndNotesSection(session: session, yPosition: yPosition, in: context, pageRect: pageRect)
            }

            // If this is imported data without raw RR, add a note
            if !hasRawData {
                yPosition = drawImportedDataNote(yPosition: yPosition, session: session, in: context, pageRect: pageRect)
            }

            drawFooter(pageNumber: pageNumber, in: context, pageRect: pageRect)
            pageNumber += 1

            // Page 2: Visualizations (only if we have raw RR data)
            if hasRawData, let series = series {
                context.beginPage()
                yPosition = config.margins.top

                // Overnight HR chart
                yPosition = drawOvernightHRChart(series: series, result: result,
                                                  yPosition: yPosition, in: context, pageRect: pageRect)

                // Poincaré plot
                yPosition = drawPoincarePlot(series: series, flags: artifactFlags, result: result,
                                             yPosition: yPosition, in: context, pageRect: pageRect)

                // PSD graph
                if let fd = result.frequencyDomain {
                    yPosition = drawPSDGraph(series: series, flags: artifactFlags, fd: fd,
                                             yPosition: yPosition, in: context, pageRect: pageRect)
                }

                // Tachogram
                yPosition = drawTachogram(series: series, flags: artifactFlags, result: result,
                                          yPosition: yPosition, in: context, pageRect: pageRect)

                yPosition = drawQualitySection(result, session: session, yPosition: yPosition, in: context, pageRect: pageRect)

                // Window Selection Info
                if result.windowStartMs != nil || result.windowSelectionReason != nil {
                    yPosition = drawWindowSelectionSection(result: result, yPosition: yPosition, in: context, pageRect: pageRect)
                }

                drawFooter(pageNumber: pageNumber, in: context, pageRect: pageRect)
                pageNumber += 1
            }

            // Page 3: Analysis Summary ("What This Means")
            context.beginPage()
            yPosition = config.margins.top

            yPosition = drawAnalysisSummarySection(result: result, session: session,
                                                    sleepData: healthKitSleep,
                                                    sleepTrend: healthKitSleepTrend,
                                                    recentSessions: sessions,
                                                    yPosition: yPosition, in: context, pageRect: pageRect)

            drawFooter(pageNumber: pageNumber, in: context, pageRect: pageRect)
        }

        return data
    }

    /// Draw a note indicating this is imported data
    private func drawImportedDataNote(yPosition: CGFloat, session: HRVSession, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let y = yPosition + 10

        // Draw info box
        let boxHeight: CGFloat = 50
        let boxRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: boxHeight)
        UIColor(red: 0.95, green: 0.95, blue: 0.98, alpha: 1.0).setFill()
        UIBezierPath(roundedRect: boxRect, cornerRadius: 6).fill()

        // Icon
        let iconAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16),
            .foregroundColor: UIColor.systemBlue
        ]
        "ℹ️".draw(at: CGPoint(x: config.margins.left + 10, y: y + 15), withAttributes: iconAttributes)

        // Note text
        let noteText: String
        if let source = session.importedMetrics?.source {
            noteText = "Imported from \(source). Raw RR data not available - visualizations omitted."
        } else {
            noteText = "Summary data only. Raw RR intervals not available for visualization."
        }

        let noteAttributes: [NSAttributedString.Key: Any] = [
            .font: config.bodyFont,
            .foregroundColor: UIColor.darkGray
        ]
        let noteRect = CGRect(x: config.margins.left + 35, y: y + 10, width: contentWidth - 50, height: 30)
        noteText.draw(in: noteRect, withAttributes: noteAttributes)

        return y + boxHeight + 15
    }

    /// Generate and save PDF to temporary file, return URL
    /// - Parameters:
    ///   - session: The HRV session to generate a report for
    ///   - sleepData: HealthKit sleep data for accurate sleep reporting
    ///   - sleepTrend: Sleep trend data for context
    ///   - recentSessions: Recent sessions for trend comparison
    func generateReportURL(for session: HRVSession,
                           sleepData: SleepData? = nil,
                           sleepTrend: SleepTrendData? = nil,
                           recentSessions: [HRVSession] = [],
                           healthKitHR: (mean: Double, min: Double, max: Double, nadirTime: Date)? = nil) -> URL? {
        guard let data = generateReport(for: session,
                                         sleepData: sleepData,
                                         sleepTrend: sleepTrend,
                                         recentSessions: recentSessions,
                                         healthKitHR: healthKitHR) else { return nil }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "HRV_Report_\(dateFormatter.string(from: session.startDate)).pdf"
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(filename)

        do {
            try data.write(to: fileURL)
            return fileURL
        } catch {
            debugLog("[PDFReportGenerator] Failed to write PDF: \(error)")
            return nil
        }
    }

    // MARK: - Header & Summary

    private func drawHeader(session: HRVSession, result: HRVAnalysisResult, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        var yPosition = config.margins.top

        // Title with accent bar
        let accentRect = CGRect(x: config.margins.left, y: yPosition, width: 4, height: 28)
        config.primaryColor.setFill()
        UIBezierPath(roundedRect: accentRect, cornerRadius: 2).fill()

        let title = "HRV Analysis Report"
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: config.titleFont,
            .foregroundColor: UIColor.black
        ]
        let titleRect = CGRect(x: config.margins.left + 12, y: yPosition, width: contentWidth - 12, height: 28)
        title.draw(in: titleRect, withAttributes: titleAttributes)
        yPosition += 35

        // Session info row
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        let totalBeats = session.rrSeries?.points.count ?? 0
        let infoText = "Date: \(dateFormatter.string(from: session.startDate))  •  Recording: \(String(format: "%.1f", session.rrSeries?.durationMinutes ?? 0)) min (\(totalBeats) beats)"
        let infoAttributes: [NSAttributedString.Key: Any] = [
            .font: config.bodyFont,
            .foregroundColor: UIColor.darkGray
        ]
        let infoRect = CGRect(x: config.margins.left, y: yPosition, width: contentWidth, height: 16)
        infoText.draw(in: infoRect, withAttributes: infoAttributes)
        yPosition += 18

        // User demographics row (age and sex if available)
        let settings = SettingsManager.shared.settings
        var demographicParts: [String] = []
        if let age = settings.age {
            demographicParts.append("Age: \(age)")
        }
        if let sex = settings.biologicalSex, sex != .other {
            demographicParts.append("Sex: \(sex.rawValue)")
        }
        if !demographicParts.isEmpty {
            let demographicText = demographicParts.joined(separator: "  •  ")
            let demographicAttr: [NSAttributedString.Key: Any] = [
                .font: config.captionFont,
                .foregroundColor: UIColor.gray
            ]
            let demographicRect = CGRect(x: config.margins.left, y: yPosition, width: contentWidth, height: 14)
            demographicText.draw(in: demographicRect, withAttributes: demographicAttr)
            yPosition += 16
        }

        yPosition += 7

        return yPosition
    }

    private func drawSummaryCard(result: HRVAnalysisResult, ans: ANSMetrics?, yPosition: CGFloat, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        var y = yPosition

        // Large HRV Hero Section
        let heroHeight: CGFloat = 90
        let heroRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: heroHeight)
        UIColor(white: 0.97, alpha: 1.0).setFill()
        UIBezierPath(roundedRect: heroRect, cornerRadius: 10).fill()

        // Large RMSSD value in center-left
        let rmssd = result.timeDomain.rmssd
        let rmssdColor = hrvScoreColor(rmssd)

        let rmssdValueAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 48, weight: .bold),
            .foregroundColor: rmssdColor
        ]
        let rmssdValue = String(format: "%.0f", rmssd)
        let rmssdSize = rmssdValue.size(withAttributes: rmssdValueAttr)
        rmssdValue.draw(at: CGPoint(x: config.margins.left + 20, y: y + 15), withAttributes: rmssdValueAttr)

        // "ms" unit
        let unitAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: UIColor.gray
        ]
        "ms".draw(at: CGPoint(x: config.margins.left + 25 + rmssdSize.width, y: y + 40), withAttributes: unitAttr)

        // HRV label and assessment
        let hrvLabelAttr: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.gray
        ]
        "HRV (RMSSD)".draw(at: CGPoint(x: config.margins.left + 20, y: y + 68), withAttributes: hrvLabelAttr)

        // Assessment badge
        let assessment = hrvScoreLabel(rmssd)
        let badgeAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: rmssdColor
        ]
        let badgeSize = assessment.size(withAttributes: badgeAttr)
        let badgeRect = CGRect(x: config.margins.left + 85, y: y + 66, width: badgeSize.width + 12, height: 16)
        rmssdColor.withAlphaComponent(0.15).setFill()
        UIBezierPath(roundedRect: badgeRect, cornerRadius: 8).fill()
        assessment.draw(at: CGPoint(x: badgeRect.minX + 6, y: y + 68), withAttributes: badgeAttr)

        // Age context (e.g., "above average for your age")
        if let ageContext = hrvAgeContext(rmssd) {
            let contextAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 8, weight: .regular),
                .foregroundColor: UIColor.gray
            ]
            let contextText = ageContext.capitalized
            contextText.draw(at: CGPoint(x: badgeRect.maxX + 8, y: y + 68), withAttributes: contextAttr)
        }

        // Readiness gauge on the right side (if available)
        if let readiness = ans?.readinessScore {
            drawReadinessGauge(score: readiness, centerX: heroRect.maxX - 70, centerY: y + 45, radius: 35, in: context)
        }

        y += heroHeight + 10

        // HR Stats Row
        let statsHeight: CGFloat = 50
        let statsRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: statsHeight)
        UIColor(white: 0.98, alpha: 1.0).setFill()
        UIBezierPath(roundedRect: statsRect, cornerRadius: 8).fill()

        let boxWidth = contentWidth / 4
        let hrStats: [(String, String, UIColor)] = [
            ("Min HR", String(format: "%.0f bpm", result.timeDomain.minHR), config.secondaryColor),
            ("Avg HR", String(format: "%.0f bpm", result.timeDomain.meanHR), config.accentColor),
            ("Max HR", String(format: "%.0f bpm", result.timeDomain.maxHR), UIColor(red: 0.8, green: 0.4, blue: 0.5, alpha: 1)),
            ("SDNN", String(format: "%.1f ms", result.timeDomain.sdnn), config.primaryColor)
        ]

        for (i, stat) in hrStats.enumerated() {
            let boxX = config.margins.left + CGFloat(i) * boxWidth
            drawCompactStatBox(title: stat.0, value: stat.1, color: stat.2,
                               rect: CGRect(x: boxX + 4, y: y + 6, width: boxWidth - 8, height: statsHeight - 12))
        }

        return y + statsHeight + 15
    }

    private func drawReadinessGauge(score: Double, centerX: CGFloat, centerY: CGFloat, radius: CGFloat, in context: UIGraphicsPDFRendererContext) {
        let ctx = context.cgContext

        // Background arc
        ctx.saveGState()
        UIColor(white: 0.9, alpha: 1.0).setStroke()
        let bgPath = UIBezierPath(arcCenter: CGPoint(x: centerX, y: centerY),
                                   radius: radius,
                                   startAngle: .pi * 0.75,
                                   endAngle: .pi * 2.25,
                                   clockwise: true)
        bgPath.lineWidth = 8
        bgPath.lineCapStyle = .round
        bgPath.stroke()

        // Colored arc based on score
        let scoreColor = readinessColor(score)
        scoreColor.setStroke()
        let scoreAngle = .pi * 0.75 + (.pi * 1.5 * CGFloat(score / 10.0))
        let scorePath = UIBezierPath(arcCenter: CGPoint(x: centerX, y: centerY),
                                      radius: radius,
                                      startAngle: .pi * 0.75,
                                      endAngle: scoreAngle,
                                      clockwise: true)
        scorePath.lineWidth = 8
        scorePath.lineCapStyle = .round
        scorePath.stroke()

        ctx.restoreGState()

        // Score text in center
        let scoreText = String(format: "%.1f", score)
        let scoreAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18, weight: .bold),
            .foregroundColor: scoreColor
        ]
        let scoreSize = scoreText.size(withAttributes: scoreAttr)
        scoreText.draw(at: CGPoint(x: centerX - scoreSize.width / 2, y: centerY - 10), withAttributes: scoreAttr)

        // "/10" below
        let subAttr: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.gray
        ]
        "/10".draw(at: CGPoint(x: centerX - 8, y: centerY + 8), withAttributes: subAttr)

        // "Readiness" label below gauge
        let labelAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 7, weight: .medium),
            .foregroundColor: UIColor.gray
        ]
        "Readiness".draw(at: CGPoint(x: centerX - 18, y: centerY + radius + 2), withAttributes: labelAttr)
    }

    private func drawCompactStatBox(title: String, value: String, color: UIColor, rect: CGRect) {
        // Title
        let titleAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 7, weight: .medium),
            .foregroundColor: UIColor.gray
        ]
        title.draw(at: CGPoint(x: rect.minX + 4, y: rect.minY), withAttributes: titleAttr)

        // Value
        let valueAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: color
        ]
        value.draw(at: CGPoint(x: rect.minX + 4, y: rect.minY + 12), withAttributes: valueAttr)
    }

    /// Get age-adjusted HRV interpretation using user settings
    private func ageAdjustedInterpretation(_ rmssd: Double) -> RMSSDInterpretation {
        let settings = SettingsManager.shared.settings
        let sex: AgeAdjustedHRV.Sex? = {
            switch settings.biologicalSex {
            case .male: return .male
            case .female: return .female
            case .other, .none: return nil
            }
        }()
        return AgeAdjustedHRV.interpret(rmssd: rmssd, age: settings.age, sex: sex)
    }

    private func hrvScoreColor(_ rmssd: Double) -> UIColor {
        switch ageAdjustedInterpretation(rmssd).category {
        case .excellent: return config.secondaryColor
        case .good: return config.secondaryColor.withAlphaComponent(0.8)
        case .fair: return UIColor(red: 0.85, green: 0.65, blue: 0.2, alpha: 1)
        case .reduced: return UIColor.orange
        case .low: return config.accentColor
        }
    }

    private func hrvScoreLabel(_ rmssd: Double) -> String {
        ageAdjustedInterpretation(rmssd).label
    }

    /// Returns age context string for PDF reports
    private func hrvAgeContext(_ rmssd: Double) -> String? {
        ageAdjustedInterpretation(rmssd).ageContext
    }

    private func readinessColor(_ score: Double) -> UIColor {
        if score >= 7 { return config.secondaryColor }
        if score >= 5 { return UIColor(red: 0.85, green: 0.65, blue: 0.2, alpha: 1) }
        return config.accentColor
    }

    private func drawSummaryBox(title: String, value: String, color: UIColor, rect: CGRect) {
        // Value
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 20, weight: .bold),
            .foregroundColor: color
        ]
        let valueRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 28)
        value.draw(in: valueRect, withAttributes: valueAttributes)

        // Title
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.gray
        ]
        let titleRect = CGRect(x: rect.minX, y: rect.minY + 30, width: rect.width, height: 14)
        title.draw(in: titleRect, withAttributes: titleAttributes)
    }

    // MARK: - Visualizations

    private func drawPoincarePlot(series: RRSeries, flags: [ArtifactFlags], result: HRVAnalysisResult,
                                   yPosition: CGFloat, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        _ = pageRect.width - config.margins.left - config.margins.right  // contentWidth (reserved for future use)
        var y = yPosition

        y = drawSectionHeading("Poincaré Plot", yPosition: y, pageRect: pageRect)

        let plotSize: CGFloat = 180
        let plotRect = CGRect(x: config.margins.left, y: y, width: plotSize, height: plotSize)

        // Background
        UIColor(white: 0.98, alpha: 1.0).setFill()
        UIBezierPath(rect: plotRect).fill()

        // Border
        UIColor.lightGray.setStroke()
        UIBezierPath(rect: plotRect).stroke()

        // Get RR pairs
        var rrPairs: [(Double, Double)] = []
        let windowStart = result.windowStart
        let windowEnd = min(result.windowEnd, series.points.count)

        for i in windowStart..<(windowEnd - 1) {
            if i < flags.count && (i + 1) < flags.count {
                if !flags[i].isArtifact && !flags[i + 1].isArtifact {
                    let rr1 = Double(series.points[i].rr_ms)
                    let rr2 = Double(series.points[i + 1].rr_ms)
                    rrPairs.append((rr1, rr2))
                }
            }
        }

        guard !rrPairs.isEmpty else { return y + plotSize + 20 }

        // Find range
        let allRR = rrPairs.flatMap { [$0.0, $0.1] }
        let minRR = allRR.min() ?? 600
        let maxRR = allRR.max() ?? 1200
        let range = max(maxRR - minRR, 100)
        let padding = range * 0.1
        let plotMin = minRR - padding
        let plotMax = maxRR + padding

        // Scale function
        func scale(_ value: Double) -> CGFloat {
            let normalized = (value - plotMin) / (plotMax - plotMin)
            return CGFloat(normalized) * (plotSize - 20) + 10
        }

        // Draw identity line
        let linePath = UIBezierPath()
        linePath.move(to: CGPoint(x: plotRect.minX + 10, y: plotRect.maxY - 10))
        linePath.addLine(to: CGPoint(x: plotRect.maxX - 10, y: plotRect.minY + 10))
        UIColor.lightGray.setStroke()
        linePath.lineWidth = 0.5
        linePath.stroke()

        // Draw SD1/SD2 ellipse
        let meanRR = allRR.reduce(0, +) / Double(allRR.count)
        let centerX = plotRect.minX + scale(meanRR)
        let centerY = plotRect.maxY - scale(meanRR)

        let sd1Px = CGFloat(result.nonlinear.sd1) * (plotSize - 20) / CGFloat(plotMax - plotMin)
        let sd2Px = CGFloat(result.nonlinear.sd2) * (plotSize - 20) / CGFloat(plotMax - plotMin)

        context.cgContext.saveGState()
        context.cgContext.translateBy(x: centerX, y: centerY)
        context.cgContext.rotate(by: -.pi / 4)

        let ellipsePath = UIBezierPath(ovalIn: CGRect(x: -sd2Px, y: -sd1Px, width: sd2Px * 2, height: sd1Px * 2))
        config.primaryColor.withAlphaComponent(0.2).setFill()
        ellipsePath.fill()
        config.primaryColor.withAlphaComponent(0.5).setStroke()
        ellipsePath.lineWidth = 1
        ellipsePath.stroke()

        context.cgContext.restoreGState()

        // Draw points (sample if too many)
        let maxPoints = 500
        let step = max(1, rrPairs.count / maxPoints)
        config.primaryColor.withAlphaComponent(0.6).setFill()

        for i in stride(from: 0, to: rrPairs.count, by: step) {
            let (rr1, rr2) = rrPairs[i]
            let x = plotRect.minX + scale(rr1)
            let y = plotRect.maxY - scale(rr2)
            let dotRect = CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)
            UIBezierPath(ovalIn: dotRect).fill()
        }

        // Labels
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.darkGray
        ]
        "RR(n) ms".draw(at: CGPoint(x: plotRect.midX - 20, y: plotRect.maxY + 2), withAttributes: labelAttributes)

        // Stats next to plot
        let statsX = plotRect.maxX + 20
        let stats = [
            ("SD1", String(format: "%.1f ms", result.nonlinear.sd1)),
            ("SD2", String(format: "%.1f ms", result.nonlinear.sd2)),
            ("SD1/SD2", String(format: "%.3f", result.nonlinear.sd1Sd2Ratio)),
            ("Points", "\(rrPairs.count)")
        ]

        var statsY = y + 10
        for (name, value) in stats {
            let nameAttr: [NSAttributedString.Key: Any] = [.font: config.captionFont, .foregroundColor: UIColor.gray]
            let valueAttr: [NSAttributedString.Key: Any] = [.font: config.monoFont, .foregroundColor: UIColor.black]
            name.draw(at: CGPoint(x: statsX, y: statsY), withAttributes: nameAttr)
            value.draw(at: CGPoint(x: statsX + 50, y: statsY), withAttributes: valueAttr)
            statsY += 14
        }

        return y + plotSize + 20
    }

    private func drawPSDGraph(series: RRSeries, flags: [ArtifactFlags], fd: FrequencyDomainMetrics,
                               yPosition: CGFloat, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        var y = yPosition

        y = drawSectionHeading("Power Spectral Density", yPosition: y, pageRect: pageRect)

        let graphWidth = contentWidth - 100
        let graphHeight: CGFloat = 100
        let graphRect = CGRect(x: config.margins.left, y: y, width: graphWidth, height: graphHeight)

        // Background
        UIColor(white: 0.98, alpha: 1.0).setFill()
        UIBezierPath(rect: graphRect).fill()

        // Compute simple PSD for visualization (using the frequencies we care about)
        let psdData = computeSimplePSD(series: series, flags: flags,
                                        windowStart: 0, windowEnd: series.points.count)

        guard !psdData.isEmpty else { return y + graphHeight + 20 }

        // Find max for scaling
        let maxPower = psdData.map { $0.1 }.max() ?? 1

        // Draw frequency bands background
        let freqToX: (Double) -> CGFloat = { freq in
            let normalized = freq / 0.5  // Max freq 0.5 Hz
            return graphRect.minX + CGFloat(normalized) * graphWidth
        }

        // VLF band (0.003-0.04 Hz) - gray
        let vlfRect = CGRect(x: freqToX(0.003), y: graphRect.minY,
                             width: freqToX(0.04) - freqToX(0.003), height: graphHeight)
        UIColor(white: 0.9, alpha: 0.5).setFill()
        UIBezierPath(rect: vlfRect).fill()

        // LF band (0.04-0.15 Hz) - blue tint
        let lfRect = CGRect(x: freqToX(0.04), y: graphRect.minY,
                            width: freqToX(0.15) - freqToX(0.04), height: graphHeight)
        config.primaryColor.withAlphaComponent(0.15).setFill()
        UIBezierPath(rect: lfRect).fill()

        // HF band (0.15-0.4 Hz) - green tint
        let hfRect = CGRect(x: freqToX(0.15), y: graphRect.minY,
                            width: freqToX(0.4) - freqToX(0.15), height: graphHeight)
        config.secondaryColor.withAlphaComponent(0.15).setFill()
        UIBezierPath(rect: hfRect).fill()

        // Draw PSD curve
        let path = UIBezierPath()
        var first = true

        for (freq, power) in psdData {
            let x = freqToX(freq)
            let normalizedPower = power / maxPower
            let y = graphRect.maxY - CGFloat(normalizedPower) * graphHeight * 0.9

            if first {
                path.move(to: CGPoint(x: x, y: y))
                first = false
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        config.primaryColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()

        // Border
        UIColor.lightGray.setStroke()
        UIBezierPath(rect: graphRect).stroke()

        // X-axis labels
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.darkGray
        ]

        for freq in [0.0, 0.1, 0.2, 0.3, 0.4, 0.5] {
            let x = freqToX(freq)
            let label = String(format: "%.1f", freq)
            label.draw(at: CGPoint(x: x - 8, y: graphRect.maxY + 2), withAttributes: labelAttributes)
        }
        "Frequency (Hz)".draw(at: CGPoint(x: graphRect.midX - 30, y: graphRect.maxY + 14), withAttributes: labelAttributes)

        // Band labels
        let bandLabels: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 7, weight: .medium),
            .foregroundColor: UIColor.gray
        ]
        "VLF".draw(at: CGPoint(x: freqToX(0.02) - 6, y: graphRect.minY + 2), withAttributes: bandLabels)
        "LF".draw(at: CGPoint(x: freqToX(0.095) - 4, y: graphRect.minY + 2), withAttributes: bandLabels)
        "HF".draw(at: CGPoint(x: freqToX(0.275) - 4, y: graphRect.minY + 2), withAttributes: bandLabels)

        // Stats
        let statsX = graphRect.maxX + 10
        var statsY = y + 5
        let stats = [
            ("LF", String(format: "%.0f ms²", fd.lf)),
            ("HF", String(format: "%.0f ms²", fd.hf)),
            ("LF/HF", fd.lfHfRatio.map { String(format: "%.2f", $0) } ?? "—"),
            ("Total", String(format: "%.0f ms²", fd.totalPower))
        ]

        for (name, value) in stats {
            let nameAttr: [NSAttributedString.Key: Any] = [.font: config.captionFont, .foregroundColor: UIColor.gray]
            let valueAttr: [NSAttributedString.Key: Any] = [.font: config.monoFont, .foregroundColor: UIColor.black]
            name.draw(at: CGPoint(x: statsX, y: statsY), withAttributes: nameAttr)
            value.draw(at: CGPoint(x: statsX + 35, y: statsY), withAttributes: valueAttr)
            statsY += 12
        }

        return y + graphHeight + 30
    }

    private func drawTachogram(series: RRSeries, flags: [ArtifactFlags], result: HRVAnalysisResult,
                                yPosition: CGFloat, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        var y = yPosition

        y = drawSectionHeading("RR Tachogram", yPosition: y, pageRect: pageRect)

        let graphHeight: CGFloat = 80
        let graphRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: graphHeight)

        // Background
        UIColor(white: 0.98, alpha: 1.0).setFill()
        UIBezierPath(rect: graphRect).fill()

        let windowStart = result.windowStart
        let windowEnd = min(result.windowEnd, series.points.count)
        guard windowEnd > windowStart else { return y + graphHeight + 15 }

        // Get RR values
        var rrValues: [(Int, Double, Bool)] = []
        for i in windowStart..<windowEnd {
            let isArtifact = i < flags.count ? flags[i].isArtifact : false
            rrValues.append((i - windowStart, Double(series.points[i].rr_ms), isArtifact))
        }

        let minRR = rrValues.map { $0.1 }.min() ?? 600
        let maxRR = rrValues.map { $0.1 }.max() ?? 1200
        let range = max(maxRR - minRR, 50)

        // Draw analysis window indicator
        let windowRect = CGRect(x: graphRect.minX, y: graphRect.minY, width: graphRect.width, height: graphHeight)
        config.primaryColor.withAlphaComponent(0.05).setFill()
        UIBezierPath(rect: windowRect).fill()

        // Draw RR trace
        let path = UIBezierPath()
        var first = true
        let xScale = graphRect.width / CGFloat(rrValues.count - 1)

        for (i, rr, isArtifact) in rrValues {
            let x = graphRect.minX + CGFloat(i) * xScale
            let normalized = (rr - minRR) / range
            let yPos = graphRect.maxY - CGFloat(normalized) * graphHeight * 0.85 - 5

            if first {
                path.move(to: CGPoint(x: x, y: yPos))
                first = false
            } else {
                path.addLine(to: CGPoint(x: x, y: yPos))
            }

            // Mark artifacts
            if isArtifact {
                config.accentColor.setFill()
                let dotRect = CGRect(x: x - 2, y: yPos - 2, width: 4, height: 4)
                UIBezierPath(ovalIn: dotRect).fill()
            }
        }

        config.primaryColor.setStroke()
        path.lineWidth = 0.8
        path.stroke()

        // Border
        UIColor.lightGray.setStroke()
        UIBezierPath(rect: graphRect).stroke()

        // Y-axis labels
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.gray
        ]
        String(format: "%.0f", maxRR).draw(at: CGPoint(x: graphRect.maxX + 3, y: graphRect.minY), withAttributes: labelAttributes)
        String(format: "%.0f", minRR).draw(at: CGPoint(x: graphRect.maxX + 3, y: graphRect.maxY - 10), withAttributes: labelAttributes)
        "ms".draw(at: CGPoint(x: graphRect.maxX + 3, y: graphRect.midY - 5), withAttributes: labelAttributes)

        return y + graphHeight + 15
    }

    // MARK: - Metric Sections

    private func drawTimeDomainSection(_ td: TimeDomainMetrics, yPosition: CGFloat, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        var y = yPosition

        y = drawSectionHeading("Time Domain HRV", yPosition: y, pageRect: pageRect)

        var metrics = [
            ("Mean NN", String(format: "%.1f ms", td.meanRR)),
            ("SDNN", String(format: "%.1f ms", td.sdnn)),
            ("RMSSD", String(format: "%.1f ms", td.rmssd)),
            ("pNN50", String(format: "%.1f%%", td.pnn50)),
            ("Mean HR", String(format: "%.0f bpm", td.meanHR)),
            ("SDSD", String(format: "%.1f ms", td.sdsd)),
        ]

        if let tri = td.triangularIndex {
            metrics.append(("HRV TI", String(format: "%.1f", tri)))
        }

        y = drawCompactMetricsGrid(metrics, yPosition: y, pageRect: pageRect)

        return y + 8
    }

    private func drawFrequencyDomainSection(_ fd: FrequencyDomainMetrics, yPosition: CGFloat, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        var y = yPosition

        y = drawSectionHeading("Frequency Domain HRV", yPosition: y, pageRect: pageRect)

        var metrics: [(String, String)] = []

        if let vlf = fd.vlf {
            metrics.append(("VLF", String(format: "%.0f ms²", vlf)))
        }
        metrics.append(("LF", String(format: "%.0f ms²", fd.lf)))
        metrics.append(("HF", String(format: "%.0f ms²", fd.hf)))
        if let ratio = fd.lfHfRatio {
            metrics.append(("LF/HF", String(format: "%.2f", ratio)))
        }
        metrics.append(("Total", String(format: "%.0f ms²", fd.totalPower)))
        if let lfNu = fd.lfNu, let hfNu = fd.hfNu {
            metrics.append(("LF n.u.", String(format: "%.1f%%", lfNu)))
            metrics.append(("HF n.u.", String(format: "%.1f%%", hfNu)))
        }

        y = drawCompactMetricsGrid(metrics, yPosition: y, pageRect: pageRect)

        return y + 8
    }

    private func drawNonlinearSection(_ nl: NonlinearMetrics, yPosition: CGFloat, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        var y = yPosition

        y = drawSectionHeading("Nonlinear HRV", yPosition: y, pageRect: pageRect)

        var metrics: [(String, String)] = [
            ("SD1", String(format: "%.1f ms", nl.sd1)),
            ("SD2", String(format: "%.1f ms", nl.sd2)),
            ("SD1/SD2", String(format: "%.3f", nl.sd1Sd2Ratio)),
        ]

        if let ae = nl.approxEntropy {
            metrics.append(("ApEn", String(format: "%.3f", ae)))
        }
        if let se = nl.sampleEntropy {
            metrics.append(("SampEn", String(format: "%.3f", se)))
        }
        if let a1 = nl.dfaAlpha1 {
            metrics.append(("DFA α1", String(format: "%.3f", a1)))
        }
        if let a2 = nl.dfaAlpha2 {
            metrics.append(("DFA α2", String(format: "%.3f", a2)))
        }

        y = drawCompactMetricsGrid(metrics, yPosition: y, pageRect: pageRect)

        return y + 8
    }

    private func drawANSSection(_ ans: ANSMetrics, yPosition: CGFloat, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        var y = yPosition

        y = drawSectionHeading("ANS Indexes", yPosition: y, pageRect: pageRect)

        var metrics: [(String, String)] = []

        if let si = ans.stressIndex {
            metrics.append(("Stress Index", String(format: "%.1f", si)))
        }
        if let pns = ans.pnsIndex {
            metrics.append(("PNS Index", String(format: "%+.2f", pns)))
        }
        if let sns = ans.snsIndex {
            metrics.append(("SNS Index", String(format: "%+.2f", sns)))
        }
        if let readiness = ans.readinessScore {
            metrics.append(("Readiness", String(format: "%.1f/10", readiness)))
        }
        if let resp = ans.respirationRate {
            metrics.append(("Resp Rate", String(format: "%.1f/min", resp)))
        }

        y = drawCompactMetricsGrid(metrics, yPosition: y, pageRect: pageRect)

        return y + 8
    }

    private func drawQualitySection(_ result: HRVAnalysisResult, session: HRVSession, yPosition: CGFloat, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        var y = yPosition

        y = drawSectionHeading("Data Quality", yPosition: y, pageRect: pageRect)

        // Calculate window duration for context
        let windowDurationMs = result.windowEndMs.map { end in
            result.windowStartMs.map { start in end - start } ?? 0
        } ?? 0
        let windowDurationMin = Double(windowDurationMs) / 60000.0
        let windowDurationStr = windowDurationMin > 0 ? String(format: "%.1f min", windowDurationMin) : "—"

        let metrics: [(String, String)] = [
            ("Recorded Beats", "\(session.rrSeries?.points.count ?? 0)"),
            ("Analysis Window", windowDurationStr),
            ("Window Beats", "\(result.cleanBeatCount)"),
            ("Artifacts", String(format: "%.1f%%", result.artifactPercentage)),
        ]

        y = drawCompactMetricsGrid(metrics, yPosition: y, pageRect: pageRect)

        // Add explanatory note
        let noteAttr: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.gray
        ]
        let noteText = "Note: HRV metrics are calculated from a 5-minute analysis window selected for optimal data quality, not the full recording."
        let noteRect = CGRect(x: config.margins.left, y: y + 4, width: contentWidth, height: 24)
        noteText.draw(in: noteRect, withAttributes: noteAttr)

        return y + 30
    }

    private func drawWindowSelectionSection(result: HRVAnalysisResult, yPosition: CGFloat, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        var y = yPosition

        y = drawSectionHeading("Analysis Window", yPosition: y, pageRect: pageRect)

        // Card background
        let cardHeight: CGFloat = 70
        let cardRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: cardHeight)
        UIColor(white: 0.97, alpha: 1.0).setFill()
        UIBezierPath(roundedRect: cardRect, cornerRadius: 8).fill()

        var infoY = y + 10

        // Time range
        if let startMs = result.windowStartMs, let endMs = result.windowEndMs {
            let timeStr = "\(formatTimeMs(startMs)) – \(formatTimeMs(endMs)) (\(formatDurationMs(endMs - startMs)))"
            let timeAttr: [NSAttributedString.Key: Any] = [
                .font: config.bodyFont,
                .foregroundColor: UIColor.black
            ]
            "Time Range: ".draw(at: CGPoint(x: config.margins.left + 10, y: infoY), withAttributes: [
                .font: config.captionFont,
                .foregroundColor: UIColor.gray
            ])
            timeStr.draw(at: CGPoint(x: config.margins.left + 70, y: infoY), withAttributes: timeAttr)
            infoY += 16
        }

        // Window stats row
        var statsX = config.margins.left + 10
        if let meanHR = result.windowMeanHR {
            let hrStr = String(format: "Window HR: %.0f bpm", meanHR)
            hrStr.draw(at: CGPoint(x: statsX, y: infoY), withAttributes: [
                .font: config.captionFont,
                .foregroundColor: UIColor.darkGray
            ])
            statsX += 100
        }

        if let stability = result.windowHRStability {
            let stabilityLabel = stabilityLabelFor(stability)
            let stabStr = "Stability: \(stabilityLabel) (CV: \(String(format: "%.2f", stability)))"
            stabStr.draw(at: CGPoint(x: statsX, y: infoY), withAttributes: [
                .font: config.captionFont,
                .foregroundColor: stabilityColorFor(stability)
            ])
        }
        infoY += 16

        // Selection reason
        if let reason = result.windowSelectionReason, !reason.isEmpty {
            let reasonAttr: [NSAttributedString.Key: Any] = [
                .font: config.captionFont,
                .foregroundColor: UIColor.darkGray
            ]
            let reasonRect = CGRect(x: config.margins.left + 10, y: infoY, width: contentWidth - 20, height: 24)
            reason.draw(in: reasonRect, withAttributes: reasonAttr)
        }

        return y + cardHeight + 10
    }

    private func formatTimeMs(_ ms: Int64) -> String {
        let totalSeconds = Int(ms / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func formatDurationMs(_ ms: Int64) -> String {
        let minutes = Int(ms / 60000)
        let seconds = Int((ms % 60000) / 1000)
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    private func stabilityLabelFor(_ cv: Double) -> String {
        if cv < 0.03 { return "Excellent" }
        if cv < 0.05 { return "Good" }
        if cv < 0.08 { return "Fair" }
        return "Variable"
    }

    private func stabilityColorFor(_ cv: Double) -> UIColor {
        if cv < 0.03 { return config.secondaryColor }
        if cv < 0.05 { return config.primaryColor }
        if cv < 0.08 { return UIColor.orange }
        return config.accentColor
    }

    private func drawFooter(pageNumber: Int, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        let footer = "Flow Recovery  •  Page \(pageNumber)  •  \(dateFormatter.string(from: Date()))"
        let footerAttributes: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.gray
        ]

        let footerSize = footer.size(withAttributes: footerAttributes)
        let footerRect = CGRect(
            x: (pageRect.width - footerSize.width) / 2,
            y: pageRect.height - config.margins.bottom + 15,
            width: footerSize.width,
            height: footerSize.height
        )
        footer.draw(in: footerRect, withAttributes: footerAttributes)
    }

    // MARK: - Drawing Helpers

    private func drawSectionHeading(_ text: String, yPosition: CGFloat, pageRect: CGRect) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: config.headingFont,
            .foregroundColor: config.primaryColor
        ]

        let rect = CGRect(x: config.margins.left, y: yPosition, width: pageRect.width - config.margins.left - config.margins.right, height: 18)
        text.draw(in: rect, withAttributes: attributes)

        return yPosition + 20
    }

    private func drawCompactMetricsGrid(_ metrics: [(String, String)], yPosition: CGFloat, pageRect: CGRect) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let columns = 4
        let colWidth = contentWidth / CGFloat(columns)
        let rowHeight: CGFloat = 28
        var y = yPosition

        let nameAttr: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.gray
        ]
        let valueAttr: [NSAttributedString.Key: Any] = [
            .font: config.monoFont,
            .foregroundColor: UIColor.black
        ]

        for (i, metric) in metrics.enumerated() {
            let col = i % columns
            let row = i / columns

            if col == 0 && row > 0 {
                y += rowHeight
            }

            let x = config.margins.left + CGFloat(col) * colWidth

            // Background for alternating rows
            if row % 2 == 0 && col == 0 {
                let rowRect = CGRect(x: config.margins.left, y: y - 2, width: contentWidth, height: rowHeight)
                UIColor(white: 0.97, alpha: 1.0).setFill()
                UIBezierPath(rect: rowRect).fill()
            }

            metric.0.draw(at: CGPoint(x: x, y: y), withAttributes: nameAttr)
            metric.1.draw(at: CGPoint(x: x, y: y + 10), withAttributes: valueAttr)
        }

        let totalRows = (metrics.count + columns - 1) / columns
        return y + CGFloat(totalRows > 0 ? 1 : 0) * rowHeight
    }

    // MARK: - PSD Computation Helper

    private func computeSimplePSD(series: RRSeries, flags: [ArtifactFlags], windowStart: Int, windowEnd: Int) -> [(Double, Double)] {
        // Extract clean RR for PSD
        var cleanRR: [Double] = []
        for i in windowStart..<min(windowEnd, series.points.count) {
            if i >= flags.count || !flags[i].isArtifact {
                cleanRR.append(Double(series.points[i].rr_ms))
            }
        }

        guard cleanRR.count >= 64 else { return [] }

        // Simple DFT-based PSD for visualization
        let fs = 4.0  // Resample frequency
        let n = min(cleanRR.count, 512)

        // Resample to uniform grid
        var resampled = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let idx = i * cleanRR.count / n
            resampled[i] = cleanRR[idx]
        }

        // Remove mean
        let mean = resampled.reduce(0, +) / Double(n)
        resampled = resampled.map { $0 - mean }

        // Simple periodogram
        var psd: [(Double, Double)] = []
        let numFreqs = 64

        for k in 1..<numFreqs {
            let freq = Double(k) * fs / Double(n) / 2
            if freq > 0.5 { break }

            var realSum = 0.0
            var imagSum = 0.0

            for i in 0..<n {
                let angle = 2.0 * .pi * Double(k) * Double(i) / Double(n)
                realSum += resampled[i] * cos(angle)
                imagSum += resampled[i] * sin(angle)
            }

            let power = (realSum * realSum + imagSum * imagSum) / Double(n * n)
            psd.append((freq, power))
        }

        return psd
    }

    // MARK: - Overnight Stats Section

    private func drawOvernightStatsSection(series: RRSeries, result: HRVAnalysisResult, session: HRVSession,
                                            sleepData: SleepData?,
                                            healthKitHR: (mean: Double, min: Double, max: Double, nadirTime: Date)?,
                                            yPosition: CGFloat, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        var y = yPosition

        y = drawSectionHeading("Overnight Summary", yPosition: y, pageRect: pageRect)

        // Calculate overnight stats from RR data
        let points = series.points
        guard points.count > 100 else { return y }

        let minHR: Double
        let maxHR: Double
        let nadirTime: Date

        if let hkStats = healthKitHR {
            // Use HealthKit HR (Apple Watch samples - ground truth)
            minHR = hkStats.min
            maxHR = hkStats.max
            nadirTime = hkStats.nadirTime
            debugLog("[PDF] Using HealthKit HR: nadir=\(minHR), max=\(maxHR)")
        } else {
            // Fall back to calculated HR from RR intervals
            let hrStats = calculateRollingWindowHRStats(points: points)
            minHR = hrStats.nadir
            maxHR = hrStats.max
            nadirTime = hrStats.nadirTime ?? session.startDate
            debugLog("[PDF] Using calculated HR: nadir=\(minHR), max=\(maxHR)")
        }

        // Calculate rolling RMSSD to find peak HRV within 30-70% of recording
        // Note: PDFReportGenerator doesn't have HealthKit sleep boundaries, so we use recording duration
        let windowSize = 30
        let startTimeMs = points.first?.t_ms ?? 0
        let endTimeMs = points.last?.t_ms ?? startTimeMs
        let recordingDurationMs = endTimeMs - startTimeMs

        // Calculate 30-70% band based on recording duration
        let limitEarlyMs = startTimeMs + Int64(Double(recordingDurationMs) * 0.30)
        let limitLateMs = startTimeMs + Int64(Double(recordingDurationMs) * 0.70)

        var peakRMSSD = 0.0
        var peakHRVIndex = 0
        for i in stride(from: 0, to: points.count - windowSize, by: 10) {
            let midIndex = i + windowSize / 2
            let midTimeMs = points[min(midIndex, points.count - 1)].t_ms

            // Only consider windows within 30-70% band
            guard midTimeMs >= limitEarlyMs && midTimeMs <= limitLateMs else { continue }

            var diffs: [Double] = []
            for j in i..<(i + windowSize - 1) {
                let diff = Double(points[j + 1].rr_ms) - Double(points[j].rr_ms)
                diffs.append(diff * diff)
            }
            let rmssd = sqrt(diffs.reduce(0, +) / Double(diffs.count))
            if rmssd > peakRMSSD {
                peakRMSSD = rmssd
                peakHRVIndex = midIndex
            }
        }

        // Fallback to global peak if no data in 30-70% band
        if peakRMSSD == 0.0 {
            for i in stride(from: 0, to: points.count - windowSize, by: 10) {
                var diffs: [Double] = []
                for j in i..<(i + windowSize - 1) {
                    let diff = Double(points[j + 1].rr_ms) - Double(points[j].rr_ms)
                    diffs.append(diff * diff)
                }
                let rmssd = sqrt(diffs.reduce(0, +) / Double(diffs.count))
                if rmssd > peakRMSSD {
                    peakRMSSD = rmssd
                    peakHRVIndex = i + windowSize / 2
                }
            }
        }

        let peakHRVTimeMs = points[min(peakHRVIndex, points.count - 1)].t_ms
        let peakHRVOffsetMs = peakHRVTimeMs - startTimeMs
        let peakHRVTime = session.startDate.addingTimeInterval(Double(peakHRVOffsetMs) / 1000.0)

        // Recording duration
        let durationMs = (points.last?.t_ms ?? 0) - startTimeMs
        let durationMinutes = Int(durationMs / 60000)
        let durationHours = durationMinutes / 60
        let durationMins = durationMinutes % 60
        let durationFormatted = durationHours > 0 ? "\(durationHours)h \(durationMins)m" : "\(durationMins)m"

        // Use actual HealthKit sleep data when available, otherwise estimate
        let sleepMinutes: Int
        let deepSleepMinutes: Int
        let sleepFormatted: String
        let deepFormatted: String
        let sleepLabel: String
        let deepLabel: String

        if let hkSleep = sleepData, hkSleep.totalSleepMinutes > 0 {
            // Use totalSleepMinutes which is the actual sum of asleep stages
            // This excludes awake periods during the night (sleepEnd - sleepStart would include them)
            sleepMinutes = hkSleep.totalSleepMinutes
            deepSleepMinutes = hkSleep.deepSleepMinutes ?? 0

            let sleepHours = sleepMinutes / 60
            let sleepMins = sleepMinutes % 60
            sleepFormatted = sleepHours > 0 ? "\(sleepHours)h \(sleepMins)m" : "\(sleepMins)m"
            deepFormatted = hkSleep.deepSleepFormatted ?? "N/A"
            sleepLabel = "Time Asleep"
            deepLabel = deepSleepMinutes > 0 ? "Deep Sleep" : "Deep Sleep"
        } else if let hkSleep = sleepData,
                  let sleepStart = hkSleep.sleepStart,
                  let sleepEnd = hkSleep.sleepEnd {
            // Fallback: If no totalSleepMinutes but have boundaries, use boundary diff
            // This is less accurate as it includes awake periods
            let sleepDurationSeconds = sleepEnd.timeIntervalSince(sleepStart)
            sleepMinutes = Int(sleepDurationSeconds / 60)
            deepSleepMinutes = hkSleep.deepSleepMinutes ?? 0

            let sleepHours = sleepMinutes / 60
            let sleepMins = sleepMinutes % 60
            sleepFormatted = sleepHours > 0 ? "\(sleepHours)h \(sleepMins)m" : "\(sleepMins)m"
            deepFormatted = hkSleep.deepSleepFormatted ?? "N/A"
            sleepLabel = "Time Asleep"
            deepLabel = deepSleepMinutes > 0 ? "Deep Sleep" : "Deep Sleep"
        } else {
            // Fall back to estimation from recording duration
            if durationMinutes > 180 {
                sleepMinutes = Int(Double(durationMinutes) * 0.90)
                deepSleepMinutes = Int(Double(sleepMinutes) * 0.20)
            } else {
                sleepMinutes = Int(Double(durationMinutes) * 0.85)
                deepSleepMinutes = Int(Double(sleepMinutes) * 0.15)
            }

            let sleepHours = sleepMinutes / 60
            let sleepMins = sleepMinutes % 60
            sleepFormatted = sleepHours > 0 ? "\(sleepHours)h \(sleepMins)m" : "\(sleepMins)m"

            let deepHours = deepSleepMinutes / 60
            let deepMins = deepSleepMinutes % 60
            deepFormatted = deepHours > 0 ? "\(deepHours)h \(deepMins)m" : "\(deepMins)m"

            sleepLabel = "Est. Sleep"
            deepLabel = "Est. Deep"
        }

        // Draw stats in two rows
        let cardHeight: CGFloat = 100
        let cardRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: cardHeight)
        UIColor(white: 0.97, alpha: 1.0).setFill()
        UIBezierPath(roundedRect: cardRect, cornerRadius: 8).fill()

        let boxWidth = contentWidth / 4
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"

        // Row 1: Duration, Sleep, Deep Sleep, HR Range
        let row1Stats: [(String, String, UIColor)] = [
            ("Recording", durationFormatted, config.primaryColor),
            (sleepLabel, sleepFormatted, UIColor(red: 0.4, green: 0.3, blue: 0.7, alpha: 1)),
            (deepLabel, deepFormatted, UIColor(red: 0.3, green: 0.4, blue: 0.7, alpha: 1)),
            ("HR Range", "\(Int(minHR))-\(Int(maxHR))", config.secondaryColor)
        ]

        for (i, stat) in row1Stats.enumerated() {
            let boxX = config.margins.left + CGFloat(i) * boxWidth
            drawCompactStatBox(title: stat.0, value: stat.1, color: stat.2,
                               rect: CGRect(x: boxX + 4, y: y + 8, width: boxWidth - 8, height: 36))
        }

        // Row 2: Nadir HR, Peak HRV with times
        let row2Stats: [(String, String, UIColor)] = [
            ("Nadir HR", "\(Int(minHR)) bpm", UIColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1)),
            ("@ Time", timeFormatter.string(from: nadirTime), UIColor.darkGray),
            ("Peak HRV", String(format: "%.0f ms", peakRMSSD), config.primaryColor),
            ("@ Time", timeFormatter.string(from: peakHRVTime), UIColor.darkGray)
        ]

        for (i, stat) in row2Stats.enumerated() {
            let boxX = config.margins.left + CGFloat(i) * boxWidth
            drawCompactStatBox(title: stat.0, value: stat.1, color: stat.2,
                               rect: CGRect(x: boxX + 4, y: y + 52, width: boxWidth - 8, height: 36))
        }

        return y + cardHeight + 15
    }

    // MARK: - Overnight HR Chart

    private func drawOvernightHRChart(series: RRSeries, result: HRVAnalysisResult,
                                       yPosition: CGFloat, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        var y = yPosition

        y = drawSectionHeading("Overnight Heart Rate", yPosition: y, pageRect: pageRect)

        let graphHeight: CGFloat = 100
        let xAxisHeight: CGFloat = 18
        let graphRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: graphHeight)

        // Background
        UIColor(white: 0.98, alpha: 1.0).setFill()
        UIBezierPath(rect: graphRect).fill()

        let points = series.points
        guard points.count > 10 else { return y + graphHeight + xAxisHeight + 15 }

        // Compute HR values with downsampling for display
        // Filter out artifact values (RR < 300ms or > 2000ms)
        let sampleStep = max(1, points.count / 500)
        var hrData: [(Int, Double)] = []
        for i in stride(from: 0, to: points.count, by: sampleStep) {
            let rr = points[i].rr_ms
            guard rr >= 300 && rr <= 2000 else { continue }
            let hr = 60000.0 / Double(rr)
            hrData.append((i, hr))
        }

        guard !hrData.isEmpty else { return y + graphHeight + xAxisHeight + 15 }

        let minHR = hrData.map { $0.1 }.min() ?? 50
        let maxHR = hrData.map { $0.1 }.max() ?? 100
        let range = max(maxHR - minHR, 10)

        // Draw grid lines
        UIColor(white: 0.9, alpha: 1.0).setStroke()
        for hrLine in stride(from: Int(minHR / 10) * 10, through: Int(maxHR), by: 10) {
            let normalized = (Double(hrLine) - minHR) / range
            let lineY = graphRect.maxY - CGFloat(normalized) * graphHeight
            let linePath = UIBezierPath()
            linePath.move(to: CGPoint(x: graphRect.minX, y: lineY))
            linePath.addLine(to: CGPoint(x: graphRect.maxX, y: lineY))
            linePath.lineWidth = 0.5
            linePath.stroke()
        }

        // Mark analysis window
        let windowStartPct = CGFloat(result.windowStart) / CGFloat(points.count)
        let windowEndPct = CGFloat(result.windowEnd) / CGFloat(points.count)
        let windowRect = CGRect(
            x: graphRect.minX + windowStartPct * graphRect.width,
            y: graphRect.minY,
            width: (windowEndPct - windowStartPct) * graphRect.width,
            height: graphHeight
        )
        config.primaryColor.withAlphaComponent(0.1).setFill()
        UIBezierPath(rect: windowRect).fill()

        // Draw HR curve
        let path = UIBezierPath()
        var first = true
        let xScale = graphRect.width / CGFloat(points.count)

        for (idx, hr) in hrData {
            let x = graphRect.minX + CGFloat(idx) * xScale
            let normalized = (hr - minHR) / range
            let yPos = graphRect.maxY - CGFloat(normalized) * graphHeight * 0.9 - 5

            if first {
                path.move(to: CGPoint(x: x, y: yPos))
                first = false
            } else {
                path.addLine(to: CGPoint(x: x, y: yPos))
            }
        }

        config.accentColor.setStroke()
        path.lineWidth = 1.0
        path.stroke()

        // Border
        UIColor.lightGray.setStroke()
        UIBezierPath(rect: graphRect).stroke()

        // Y-axis labels
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.gray
        ]
        String(format: "%.0f", maxHR).draw(at: CGPoint(x: graphRect.maxX + 3, y: graphRect.minY), withAttributes: labelAttributes)
        String(format: "%.0f", minHR).draw(at: CGPoint(x: graphRect.maxX + 3, y: graphRect.maxY - 10), withAttributes: labelAttributes)
        "bpm".draw(at: CGPoint(x: graphRect.maxX + 3, y: graphRect.midY - 5), withAttributes: labelAttributes)

        // X-axis time labels showing actual clock times
        let xAxisY = graphRect.maxY + 3
        guard let firstPoint = points.first, let lastPoint = points.last else {
            return y + graphHeight + xAxisHeight + 15
        }
        let startTimeMs = firstPoint.t_ms
        let endTimeMs = lastPoint.t_ms
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"

        // Draw 5 evenly-spaced time labels
        let labelCount = 5
        for i in 0..<labelCount {
            let fraction = CGFloat(i) / CGFloat(labelCount - 1)
            let x = graphRect.minX + fraction * graphRect.width
            let relativeMs = startTimeMs + Int64(Double(endTimeMs - startTimeMs) * Double(fraction))
            let actualTime = series.startDate.addingTimeInterval(Double(relativeMs) / 1000.0)
            let timeStr = timeFormatter.string(from: actualTime)

            // Center align the label (except first and last)
            var labelX = x
            let labelSize = timeStr.size(withAttributes: labelAttributes)
            if i == 0 {
                // Left align first label
                labelX = graphRect.minX
            } else if i == labelCount - 1 {
                // Right align last label
                labelX = graphRect.maxX - labelSize.width
            } else {
                // Center align middle labels
                labelX = x - labelSize.width / 2
            }

            timeStr.draw(at: CGPoint(x: labelX, y: xAxisY), withAttributes: labelAttributes)
        }

        // Legend for analysis window (moved down to account for x-axis labels)
        let legendY = graphRect.maxY + xAxisHeight + 2
        config.primaryColor.withAlphaComponent(0.3).setFill()
        UIBezierPath(rect: CGRect(x: config.margins.left, y: legendY, width: 12, height: 8)).fill()
        "Analysis Window".draw(at: CGPoint(x: config.margins.left + 16, y: legendY - 2), withAttributes: labelAttributes)

        return y + graphHeight + xAxisHeight + 20
    }

    // MARK: - Tags & Notes Section

    private func drawTagsAndNotesSection(session: HRVSession, yPosition: CGFloat,
                                          in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        var y = yPosition

        y = drawSectionHeading("Tags & Notes", yPosition: y, pageRect: pageRect)

        // Tags
        if !session.tags.isEmpty {
            var tagX = config.margins.left
            let tagHeight: CGFloat = 18
            let tagSpacing: CGFloat = 6

            for tag in session.tags {
                let tagText = tag.name
                let tagAttributes: [NSAttributedString.Key: Any] = [
                    .font: config.captionFont,
                    .foregroundColor: UIColor.darkGray
                ]
                let tagSize = tagText.size(withAttributes: tagAttributes)
                let tagWidth = tagSize.width + 16

                // Check if we need to wrap to next line
                if tagX + tagWidth > config.margins.left + contentWidth {
                    tagX = config.margins.left
                    y += tagHeight + 4
                }

                // Draw tag pill
                let tagRect = CGRect(x: tagX, y: y, width: tagWidth, height: tagHeight)
                UIColor(white: 0.9, alpha: 1.0).setFill()
                UIBezierPath(roundedRect: tagRect, cornerRadius: 9).fill()

                tagText.draw(at: CGPoint(x: tagX + 8, y: y + 3), withAttributes: tagAttributes)
                tagX += tagWidth + tagSpacing
            }

            y += tagHeight + 10
        }

        // Notes
        if let notes = session.notes, !notes.isEmpty {
            let notesRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: 60)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byWordWrapping

            let attributedNotes = NSAttributedString(string: notes, attributes: [
                .font: config.bodyFont,
                .foregroundColor: UIColor.darkGray,
                .paragraphStyle: paragraphStyle
            ])

            attributedNotes.draw(in: notesRect)

            // Calculate actual height used
            let boundingRect = attributedNotes.boundingRect(with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                                                             options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                             context: nil)
            y += min(boundingRect.height + 10, 70)
        }

        return y + 8
    }

    // MARK: - Analysis Summary Section (Uses Shared Generator)

    /// Draws the analysis summary section using the shared AnalysisSummaryGenerator
    /// This ensures the PDF contains 100% of the same content as MorningResultsView
    private func drawAnalysisSummarySection(result: HRVAnalysisResult, session: HRVSession,
                                             sleepData: SleepData?,
                                             sleepTrend: SleepTrendData?,
                                             recentSessions: [HRVSession],
                                             yPosition: CGFloat, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        var y = yPosition

        // Convert sleep data to SleepInput for the generator
        let sleepInput: AnalysisSummaryGenerator.SleepInput
        if let sd = sleepData, sd.totalSleepMinutes > 0 {
            sleepInput = AnalysisSummaryGenerator.SleepInput(
                totalSleepMinutes: sd.totalSleepMinutes,
                inBedMinutes: sd.inBedMinutes,
                deepSleepMinutes: sd.deepSleepMinutes,
                remSleepMinutes: sd.remSleepMinutes,
                awakeMinutes: sd.awakeMinutes,
                sleepEfficiency: sd.sleepEfficiency
            )
        } else {
            // Fall back to estimation from session data
            sleepInput = computeSleepInputFromSession(session)
        }

        // Convert sleep trend to SleepTrendInput
        let sleepTrendInput: AnalysisSummaryGenerator.SleepTrendInput?
        if let st = sleepTrend, st.nightsAnalyzed > 0 {
            sleepTrendInput = AnalysisSummaryGenerator.SleepTrendInput(
                averageSleepMinutes: st.averageSleepMinutes,
                averageDeepSleepMinutes: st.averageDeepSleepMinutes,
                averageEfficiency: st.averageEfficiency,
                trend: st.trend,
                nightsAnalyzed: st.nightsAnalyzed
            )
        } else {
            sleepTrendInput = nil
        }

        // Use the shared generator - same code that powers MorningResultsView
        let generator = AnalysisSummaryGenerator(
            result: result,
            session: session,
            recentSessions: recentSessions,
            selectedTags: Set(session.tags),
            sleep: sleepInput,
            sleepTrend: sleepTrendInput
        )
        let summary = generator.generate()

        // Title with icon
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: config.titleFont,
            .foregroundColor: UIColor.black
        ]
        "What This Means".draw(at: CGPoint(x: config.margins.left, y: y), withAttributes: titleAttributes)
        y += 35

        // Diagnostic color based on score
        let color = diagnosticColorForScore(summary.diagnosticScore)

        // Draw diagnostic card
        let cardHeight: CGFloat = 110
        let cardRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: cardHeight)
        color.withAlphaComponent(0.08).setFill()
        UIBezierPath(roundedRect: cardRect, cornerRadius: 12).fill()

        // Left side: colored accent bar
        let accentRect = CGRect(x: config.margins.left, y: y, width: 6, height: cardHeight)
        color.setFill()
        UIBezierPath(roundedRect: accentRect, byRoundingCorners: [.topLeft, .bottomLeft], cornerRadii: CGSize(width: 12, height: 12)).fill()

        // Title in card
        let diagTitleAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18, weight: .bold),
            .foregroundColor: color
        ]
        summary.diagnosticTitle.draw(at: CGPoint(x: config.margins.left + 20, y: y + 12), withAttributes: diagTitleAttr)

        // "Primary Assessment" subtitle
        let subtitleAttr: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.gray
        ]
        "Primary Assessment".draw(at: CGPoint(x: config.margins.left + 20, y: y + 34), withAttributes: subtitleAttr)

        // Explanation
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attributedExplanation = NSAttributedString(string: summary.diagnosticExplanation, attributes: [
            .font: UIFont.systemFont(ofSize: 11),
            .foregroundColor: UIColor.darkGray,
            .paragraphStyle: paragraphStyle
        ])
        let explainRect = CGRect(x: config.margins.left + 20, y: y + 50, width: contentWidth - 40, height: 55)
        attributedExplanation.draw(in: explainRect)

        y += cardHeight + 20

        // === MOST LIKELY EXPLANATIONS (Probable Causes) ===
        if !summary.probableCauses.isEmpty {
            y = drawSectionHeading("Most Likely Explanations", yPosition: y, pageRect: pageRect)

            for (index, cause) in summary.probableCauses.enumerated() {
                y = drawProbableCauseRow(
                    rank: index + 1,
                    cause: cause.cause,
                    confidence: cause.confidence,
                    explanation: cause.explanation,
                    yPosition: y,
                    contentWidth: contentWidth,
                    pageRect: pageRect
                )
            }
            y += 10
        }

        // === KEY FINDINGS ===
        y = drawSectionHeading("Key Findings", yPosition: y, pageRect: pageRect)

        for finding in summary.keyFindings {
            // Draw bullet point
            config.primaryColor.setFill()
            let bulletDot = CGRect(x: config.margins.left + 8, y: y + 5, width: 4, height: 4)
            UIBezierPath(ovalIn: bulletDot).fill()

            // Draw finding text with word wrap
            let findingParagraphStyle = NSMutableParagraphStyle()
            findingParagraphStyle.lineBreakMode = .byWordWrapping

            let attributedFinding = NSAttributedString(string: finding, attributes: [
                .font: UIFont.systemFont(ofSize: 10),
                .foregroundColor: UIColor.darkGray,
                .paragraphStyle: findingParagraphStyle
            ])

            let findingRect = CGRect(x: config.margins.left + 20, y: y, width: contentWidth - 30, height: 32)
            attributedFinding.draw(in: findingRect)
            y += 18
        }

        y += 15

        // === WHAT TO DO ===
        y = drawSectionHeading("What To Do", yPosition: y, pageRect: pageRect)

        for step in summary.actionableSteps {
            // Draw arrow
            let arrowAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: config.secondaryColor
            ]
            "→".draw(at: CGPoint(x: config.margins.left + 6, y: y - 1), withAttributes: arrowAttr)

            // Draw recommendation text with word wrap
            let recParagraphStyle = NSMutableParagraphStyle()
            recParagraphStyle.lineBreakMode = .byWordWrapping

            let attributedRec = NSAttributedString(string: step, attributes: [
                .font: UIFont.systemFont(ofSize: 10),
                .foregroundColor: UIColor.darkGray,
                .paragraphStyle: recParagraphStyle
            ])

            let recRect = CGRect(x: config.margins.left + 22, y: y, width: contentWidth - 32, height: 32)
            attributedRec.draw(in: recRect)
            y += 20
        }

        // Disclaimer at bottom
        y += 15
        let disclaimerAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8),
            .foregroundColor: UIColor.gray
        ]
        let disclaimer = "Note: This analysis is for informational purposes only and should not be used as a substitute for professional medical advice."
        let disclaimerRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: 20)
        disclaimer.draw(in: disclaimerRect, withAttributes: disclaimerAttr)

        return y + 25
    }

    /// Draw a probable cause row (matches MorningResultsView's ProbableCauseRow)
    private func drawProbableCauseRow(rank: Int, cause: String, confidence: String, explanation: String,
                                       yPosition: CGFloat, contentWidth: CGFloat, pageRect: CGRect) -> CGFloat {
        let y = yPosition

        // Background card
        let cardHeight: CGFloat = 50
        let cardRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: cardHeight)
        UIColor(white: 0.97, alpha: 1.0).setFill()
        UIBezierPath(roundedRect: cardRect, cornerRadius: 8).fill()

        // Rank number
        let rankAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: config.primaryColor
        ]
        "\(rank).".draw(at: CGPoint(x: config.margins.left + 10, y: y + 8), withAttributes: rankAttr)

        // Cause title
        let causeAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: UIColor.black
        ]
        cause.draw(at: CGPoint(x: config.margins.left + 30, y: y + 6), withAttributes: causeAttr)

        // Confidence badge
        let confidenceAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8, weight: .medium),
            .foregroundColor: UIColor.gray
        ]
        confidence.draw(at: CGPoint(x: config.margins.left + 30, y: y + 22), withAttributes: confidenceAttr)

        // Explanation (truncated if needed)
        let explainAttr: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.darkGray
        ]
        let truncatedExplanation = explanation.count > 120 ? String(explanation.prefix(117)) + "..." : explanation
        let explainRect = CGRect(x: config.margins.left + 10, y: y + 34, width: contentWidth - 20, height: 14)
        truncatedExplanation.draw(in: explainRect, withAttributes: explainAttr)

        return y + cardHeight + 8
    }

    /// Convert session data to SleepInput for the generator
    private func computeSleepInputFromSession(_ session: HRVSession) -> AnalysisSummaryGenerator.SleepInput {
        guard let series = session.rrSeries, !series.points.isEmpty else {
            return .empty
        }

        let points = series.points
        guard let firstPoint = points.first else { return .empty }

        let startTime = firstPoint.t_ms
        let recordingDurationMs = (points.last?.t_ms ?? 0) - startTime
        let recordingDurationMinutes = Int(recordingDurationMs / 60000)

        // Estimate sleep from recording duration
        var sleepMinutes = 0
        var deepSleepMinutes = 0
        var awakeMinutes = 0

        if recordingDurationMinutes > 180 {
            sleepMinutes = Int(Double(recordingDurationMinutes) * 0.90)
            deepSleepMinutes = Int(Double(sleepMinutes) * 0.20)
            awakeMinutes = recordingDurationMinutes - sleepMinutes
        } else {
            sleepMinutes = Int(Double(recordingDurationMinutes) * 0.85)
            deepSleepMinutes = Int(Double(sleepMinutes) * 0.15)
            awakeMinutes = recordingDurationMinutes - sleepMinutes
        }

        let sleepEfficiency = recordingDurationMinutes > 0 ? Double(sleepMinutes) / Double(recordingDurationMinutes) * 100 : 0

        return AnalysisSummaryGenerator.SleepInput(
            totalSleepMinutes: sleepMinutes,
            inBedMinutes: recordingDurationMinutes,
            deepSleepMinutes: deepSleepMinutes,
            remSleepMinutes: nil,
            awakeMinutes: awakeMinutes,
            sleepEfficiency: sleepEfficiency
        )
    }

    /// Get color for diagnostic score
    private func diagnosticColorForScore(_ score: Double) -> UIColor {
        if score >= 80 { return config.secondaryColor }
        if score >= 60 { return config.primaryColor }
        if score >= 40 { return UIColor.orange }
        return config.accentColor
    }

    /// Calculate HR statistics using rolling 10-second windows
    /// Returns proper nadir, max, and nadir timestamp
    private func calculateRollingWindowHRStats(points: [RRPoint]) -> (nadir: Double, max: Double, nadirTime: Date?) {
        guard !points.isEmpty else {
            return (nadir: 50, max: 100, nadirTime: nil)
        }

        // Check if we have stored HR data from streaming
        let hasStoredHR = points.contains { $0.hr != nil }

        if hasStoredHR {
            // Use stored HR from Polar sensor
            let hrValues = points.compactMap { point -> Double? in
                guard let hr = point.hr, hr >= 30 && hr <= 200 else { return nil }
                return Double(hr)
            }

            guard !hrValues.isEmpty else {
                return (nadir: 50, max: 100, nadirTime: nil)
            }

            let nadir = hrValues.min() ?? 50
            let max = hrValues.max() ?? 100

            // Find time of nadir
            if let nadirIndex = points.firstIndex(where: { Double($0.hr ?? 0) == nadir }) {
                let nadirOffsetMs = points[nadirIndex].t_ms - (points.first?.t_ms ?? 0)
                let nadirTime = Date().addingTimeInterval(Double(nadirOffsetMs) / 1000.0)  // Will be adjusted by caller
                return (nadir: nadir, max: max, nadirTime: nadirTime)
            }

            return (nadir: nadir, max: max, nadirTime: nil)
        }

        // No stored HR - calculate using rolling 10-second windows
        let windowDurationMs: Int64 = 10000 // 10 seconds
        var hrSamples: [(hr: Double, index: Int)] = []

        var i = 0
        while i < points.count {
            // Collect beats for next 10-second window
            var windowBeats: [Int] = []
            var windowDurationActual: Int64 = 0
            var j = i

            while j < points.count && windowDurationActual < windowDurationMs {
                let rr = points[j].rr_ms
                if rr >= 300 && rr <= 2000 {  // Sanity filter
                    windowBeats.append(rr)
                    windowDurationActual += Int64(rr)
                }
                j += 1
            }

            // Need at least 5 beats for meaningful HR calculation
            if windowBeats.count >= 5 && windowDurationActual > 0 {
                // HR = (number of beats / duration in ms) * 60000
                let windowHR = (Double(windowBeats.count) / Double(windowDurationActual)) * 60000.0

                // Sanity check: 30-200 bpm
                if windowHR >= 30 && windowHR <= 200 {
                    hrSamples.append((hr: windowHR, index: i))
                }
            }

            // Advance by ~5 seconds (50% overlap)
            i = j > i + 5 ? i + 5 : j
        }

        guard !hrSamples.isEmpty else {
            return (nadir: 50, max: 100, nadirTime: nil)
        }

        let nadir = hrSamples.map { $0.hr }.min() ?? 50
        let max = hrSamples.map { $0.hr }.max() ?? 100

        // Find time of nadir
        if let nadirSample = hrSamples.first(where: { $0.hr == nadir }) {
            let nadirOffsetMs = points[nadirSample.index].t_ms - (points.first?.t_ms ?? 0)
            let nadirTime = Date().addingTimeInterval(Double(nadirOffsetMs) / 1000.0)  // Will be adjusted by caller
            return (nadir: nadir, max: max, nadirTime: nadirTime)
        }

        return (nadir: nadir, max: max, nadirTime: nil)
    }
}
