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

/// Live waveform display for real-time RR interval visualization
struct LiveWaveformView: View {
    let rrPoints: [RRPoint]
    let maxPoints: Int
    let showGrid: Bool
    let accentColor: Color

    init(
        rrPoints: [RRPoint],
        maxPoints: Int = 60,
        showGrid: Bool = true,
        accentColor: Color = .green
    ) {
        self.rrPoints = rrPoints
        self.maxPoints = maxPoints
        self.showGrid = showGrid
        self.accentColor = accentColor
    }

    // Display the last N points
    private var displayPoints: [RRPoint] {
        let count = rrPoints.count
        if count <= maxPoints {
            return Array(rrPoints)
        }
        return Array(rrPoints.suffix(maxPoints))
    }

    // Y-axis range
    private var yRange: (min: Double, max: Double) {
        let values = displayPoints.map { Double($0.rr_ms) }
        guard !values.isEmpty else { return (400, 1200) }

        let minVal = values.min() ?? 400
        let maxVal = values.max() ?? 1200

        // Add 10% padding
        let padding = (maxVal - minVal) * 0.1
        return (max(300, minVal - padding), min(2000, maxVal + padding))
    }

    // Current heart rate
    private var currentHR: Int? {
        guard let lastRR = displayPoints.last else { return nil }
        return Int(60000.0 / Double(lastRR.rr_ms))
    }

    // Current RR
    private var currentRR: Int? {
        displayPoints.last?.rr_ms
    }

    var body: some View {
        VStack(spacing: 8) {
            // Header with current values
            HStack {
                if let hr = currentHR {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .foregroundColor(.red)
                        Text("\(hr)")
                            .font(.title2.monospacedDigit().bold())
                        Text("bpm")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if let rr = currentRR {
                    HStack(spacing: 4) {
                        Text("\(rr)")
                            .font(.title2.monospacedDigit().bold())
                        Text("ms")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal)

            // Waveform
            GeometryReader { geometry in
                ZStack {
                    // Background grid
                    if showGrid {
                        gridView(size: geometry.size)
                    }

                    // RR waveform
                    waveformPath(size: geometry.size)
                        .stroke(accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                    // Current value marker
                    if !displayPoints.isEmpty {
                        currentMarker(size: geometry.size)
                    }
                }
            }
            .frame(height: 150)
            .background(Color.black.opacity(0.05))
            .cornerRadius(12)

            // Y-axis labels
            HStack {
                Text("\(Int(yRange.max))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text("RR (ms)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(yRange.min))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Grid

    private func gridView(size: CGSize) -> some View {
        Canvas { context, _ in
            let horizontalLines = 4
            let verticalLines = 6

            // Horizontal grid lines
            for i in 0...horizontalLines {
                let y = size.height * CGFloat(i) / CGFloat(horizontalLines)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(.gray.opacity(0.2)), lineWidth: 0.5)
            }

            // Vertical grid lines
            for i in 0...verticalLines {
                let x = size.width * CGFloat(i) / CGFloat(verticalLines)
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(.gray.opacity(0.2)), lineWidth: 0.5)
            }
        }
    }

    // MARK: - Waveform Path

    private func waveformPath(size: CGSize) -> Path {
        var path = Path()
        guard displayPoints.count >= 2 else { return path }

        let xStep = size.width / CGFloat(maxPoints - 1)
        let yMin = yRange.min
        let yMax = yRange.max
        let yScale = size.height / (yMax - yMin)

        // Start offset to right-align if fewer points than max
        let startOffset = CGFloat(maxPoints - displayPoints.count) * xStep

        for (index, point) in displayPoints.enumerated() {
            let x = startOffset + CGFloat(index) * xStep
            let y = size.height - (Double(point.rr_ms) - yMin) * yScale

            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        return path
    }

    // MARK: - Current Marker

    private func currentMarker(size: CGSize) -> some View {
        let xStep = size.width / CGFloat(maxPoints - 1)
        let yMin = yRange.min
        let yMax = yRange.max
        let yScale = size.height / (yMax - yMin)

        let startOffset = CGFloat(maxPoints - displayPoints.count) * xStep
        let lastIndex = displayPoints.count - 1
        let lastPoint = displayPoints[lastIndex]

        let x = startOffset + CGFloat(lastIndex) * xStep
        let y = size.height - (Double(lastPoint.rr_ms) - yMin) * yScale

        return Circle()
            .fill(accentColor)
            .frame(width: 8, height: 8)
            .position(x: x, y: y)
            .shadow(color: accentColor.opacity(0.5), radius: 4)
    }
}

// MARK: - Tachogram View (Bar-style)

struct TachogramBarView: View {
    let rrPoints: [RRPoint]
    let maxPoints: Int
    let accentColor: Color

    init(
        rrPoints: [RRPoint],
        maxPoints: Int = 30,
        accentColor: Color = .blue
    ) {
        self.rrPoints = rrPoints
        self.maxPoints = maxPoints
        self.accentColor = accentColor
    }

    private var displayPoints: [RRPoint] {
        let count = rrPoints.count
        if count <= maxPoints {
            return Array(rrPoints)
        }
        return Array(rrPoints.suffix(maxPoints))
    }

    private var meanRR: Double {
        guard !displayPoints.isEmpty else { return 800 }
        return Double(displayPoints.map { $0.rr_ms }.reduce(0, +)) / Double(displayPoints.count)
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(displayPoints.enumerated()), id: \.offset) { index, point in
                    let normalizedHeight = CGFloat(point.rr_ms) / CGFloat(meanRR * 1.5)
                    let barHeight = min(geometry.size.height, geometry.size.height * normalizedHeight)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor(for: point.rr_ms))
                        .frame(height: barHeight)
                }
            }
        }
    }

    private func barColor(for rr: Int) -> Color {
        let deviation = abs(Double(rr) - meanRR) / meanRR
        if deviation > 0.2 {
            return .orange
        } else if deviation > 0.1 {
            return .yellow
        }
        return accentColor
    }
}

// MARK: - Poincaré Live View

struct PoincareLiveView: View {
    let rrPoints: [RRPoint]
    let maxPoints: Int

    init(rrPoints: [RRPoint], maxPoints: Int = 100) {
        self.rrPoints = rrPoints
        self.maxPoints = maxPoints
    }

    private var displayPoints: [RRPoint] {
        let count = rrPoints.count
        if count <= maxPoints {
            return Array(rrPoints)
        }
        return Array(rrPoints.suffix(maxPoints))
    }

    private var rrPairs: [(x: Double, y: Double)] {
        guard displayPoints.count >= 2 else { return [] }
        var pairs = [(Double, Double)]()
        for i in 0..<(displayPoints.count - 1) {
            pairs.append((Double(displayPoints[i].rr_ms), Double(displayPoints[i + 1].rr_ms)))
        }
        return pairs
    }

    private var axisRange: (min: Double, max: Double) {
        let allValues = displayPoints.map { Double($0.rr_ms) }
        guard !allValues.isEmpty else { return (400, 1200) }
        let minVal = allValues.min() ?? 400
        let maxVal = allValues.max() ?? 1200
        let padding = (maxVal - minVal) * 0.15
        return (minVal - padding, maxVal + padding)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)

            ZStack {
                // Identity line
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size))
                    path.addLine(to: CGPoint(x: size, y: 0))
                }
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)

                // Plot points
                ForEach(Array(rrPairs.enumerated()), id: \.offset) { index, pair in
                    let x = (pair.x - axisRange.min) / (axisRange.max - axisRange.min) * Double(size)
                    let y = size - (pair.y - axisRange.min) / (axisRange.max - axisRange.min) * Double(size)

                    Circle()
                        .fill(pointColor(for: index))
                        .frame(width: 6, height: 6)
                        .position(x: x, y: y)
                }
            }
            .frame(width: size, height: size)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func pointColor(for index: Int) -> Color {
        // Fade older points
        let opacity = 0.3 + 0.7 * Double(index) / Double(max(1, rrPairs.count - 1))
        return Color.blue.opacity(opacity)
    }
}

// MARK: - Heart Rate Zones View

struct HeartRateZoneView: View {
    let currentHR: Int
    let maxHR: Int

    private var zonePercentage: Double {
        Double(currentHR) / Double(maxHR) * 100
    }

    private var zone: (name: String, color: Color) {
        switch zonePercentage {
        case ..<60:
            return ("Recovery", .gray)
        case 60..<70:
            return ("Zone 1", .blue)
        case 70..<80:
            return ("Zone 2", .green)
        case 80..<90:
            return ("Zone 3", .yellow)
        case 90..<100:
            return ("Zone 4", .orange)
        default:
            return ("Max", .red)
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(zone.name)
                .font(.caption.bold())
                .foregroundColor(zone.color)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))

                    // Fill
                    RoundedRectangle(cornerRadius: 4)
                        .fill(zone.color)
                        .frame(width: geometry.size.width * min(1, zonePercentage / 100))
                }
            }
            .frame(height: 8)

            Text("\(Int(zonePercentage))% max")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Live Stats Card

struct LiveStatsCard: View {
    let rrPoints: [RRPoint]

    private var stats: (rmssd: Double, sdnn: Double, meanHR: Double)? {
        guard rrPoints.count >= 10 else { return nil }

        let rrValues = rrPoints.suffix(30).map { Double($0.rr_ms) }
        let n = rrValues.count

        // Mean
        let mean = rrValues.reduce(0, +) / Double(n)

        // SDNN
        let variance = rrValues.map { pow($0 - mean, 2) }.reduce(0, +) / Double(n - 1)
        let sdnn = sqrt(variance)

        // RMSSD
        var sumSquaredDiff = 0.0
        for i in 1..<n {
            let diff = rrValues[i] - rrValues[i - 1]
            sumSquaredDiff += diff * diff
        }
        let rmssd = sqrt(sumSquaredDiff / Double(n - 1))

        // Mean HR
        let meanHR = 60000.0 / mean

        return (rmssd, sdnn, meanHR)
    }

    var body: some View {
        HStack(spacing: 16) {
            if let s = stats {
                StatItem(label: "RMSSD", value: String(format: "%.0f", s.rmssd), unit: "ms")
                StatItem(label: "SDNN", value: String(format: "%.0f", s.sdnn), unit: "ms")
                StatItem(label: "Avg HR", value: String(format: "%.0f", s.meanHR), unit: "bpm")
            } else {
                Text("Collecting data...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }
}

private struct StatItem: View {
    let label: String
    let value: String
    let unit: String

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title3.monospacedDigit().bold())
                Text(unit)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        // Generate sample RR points
        let samplePoints: [RRPoint] = (0..<50).map { i in
            let baseRR = 800 + Int.random(in: -100...100)
            return RRPoint(t_ms: Int64(i * 800), rr_ms: baseRR)
        }

        LiveWaveformView(rrPoints: samplePoints)
            .padding()

        TachogramBarView(rrPoints: samplePoints)
            .frame(height: 80)
            .padding()

        PoincareLiveView(rrPoints: samplePoints)
            .frame(height: 150)
            .padding()

        LiveStatsCard(rrPoints: samplePoints)
            .padding()
    }
}
