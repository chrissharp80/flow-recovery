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
import Accelerate

/// ECG-Derived Respiration Rate Analysis
/// Estimates breathing rate from RR interval modulation
final class RespirationAnalyzer {

    // MARK: - Respiration Rate from RR

    /// Estimate respiration rate from RR interval series
    /// Uses the HF peak in PSD as respiratory frequency
    ///
    /// - Parameters:
    ///   - rr: RR intervals in ms
    ///   - fs: Resampling frequency (default 4 Hz)
    /// - Returns: Respiration rate in breaths/min, or nil if cannot determine
    static func estimateRespirationRate(_ rr: [Double], fs: Double = 4.0) -> Double? {
        guard rr.count >= 60 else { return nil }

        // Resample RR to uniform grid
        let resampled = resampleRR(rr, fs: fs)
        guard resampled.count >= 32 else { return nil }

        // Remove mean
        var mean: Double = 0
        vDSP_meanvD(resampled, 1, &mean, vDSP_Length(resampled.count))
        var centered = resampled.map { $0 - mean }

        // Zero-pad to power of 2
        let log2n = vDSP_Length(ceil(log2(Double(centered.count))))
        let fftN = 1 << Int(log2n)
        centered.append(contentsOf: [Double](repeating: 0, count: fftN - centered.count))

        // Apply Hann window
        var window = [Double](repeating: 0, count: fftN)
        vDSP_hann_windowD(&window, vDSP_Length(fftN), Int32(vDSP_HANN_DENORM))
        vDSP_vmulD(centered, 1, window, 1, &centered, 1, vDSP_Length(fftN))

        // DFT
        guard let dftSetup = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(fftN), .FORWARD) else {
            return nil
        }
        defer { vDSP_DFT_DestroySetupD(dftSetup) }

        var inputImag = [Double](repeating: 0, count: fftN)
        var outputReal = [Double](repeating: 0, count: fftN)
        var outputImag = [Double](repeating: 0, count: fftN)

        vDSP_DFT_ExecuteD(dftSetup, &centered, &inputImag, &outputReal, &outputImag)

        // Compute power spectrum
        let halfN = fftN / 2
        var psd = [Double](repeating: 0, count: halfN + 1)
        for k in 0...halfN {
            psd[k] = outputReal[k] * outputReal[k] + outputImag[k] * outputImag[k]
        }

        // Find peak in respiratory frequency range (0.15-0.4 Hz = 9-24 breaths/min)
        let freqRes = fs / Double(fftN)
        let minBin = Int(0.15 / freqRes)
        let maxBin = min(Int(0.5 / freqRes), halfN)

        guard maxBin > minBin else { return nil }

        var peakBin = minBin
        var peakPower = psd[minBin]

        for k in minBin...maxBin {
            if psd[k] > peakPower {
                peakPower = psd[k]
                peakBin = k
            }
        }

        // Convert to breaths/min
        let peakFreq = Double(peakBin) * freqRes
        let breathsPerMin = peakFreq * 60.0

        // Sanity check (normal range 8-30 breaths/min)
        guard breathsPerMin >= 6 && breathsPerMin <= 40 else { return nil }

        return breathsPerMin
    }

    /// Estimate respiration rate using counting zero crossings
    /// Alternative method that works with shorter segments
    ///
    /// - Parameter rr: RR intervals in ms
    /// - Returns: Respiration rate in breaths/min
    static func estimateRespirationRateZeroCrossing(_ rr: [Double]) -> Double? {
        guard rr.count >= 30 else { return nil }

        // Bandpass filter to isolate respiratory component (0.15-0.4 Hz)
        let filtered = bandpassFilter(rr, lowCut: 0.1, highCut: 0.5)
        guard filtered.count >= 10 else { return nil }

        // Remove mean
        var mean: Double = 0
        vDSP_meanvD(filtered, 1, &mean, vDSP_Length(filtered.count))
        let centered = filtered.map { $0 - mean }

        // Count zero crossings
        var crossings = 0
        for i in 1..<centered.count {
            if (centered[i-1] < 0 && centered[i] >= 0) || (centered[i-1] >= 0 && centered[i] < 0) {
                crossings += 1
            }
        }

        // Estimate duration (sum of RR intervals)
        let durationMs = rr.reduce(0, +)
        let durationMin = durationMs / 60000.0

        guard durationMin > 0 else { return nil }

        // Each breath cycle has 2 zero crossings
        let breathsPerMin = (Double(crossings) / 2.0) / durationMin

        // Sanity check
        guard breathsPerMin >= 6 && breathsPerMin <= 40 else { return nil }

        return breathsPerMin
    }

    // MARK: - Helpers

    /// Simple cubic spline resampling to uniform grid
    private static func resampleRR(_ rr: [Double], fs: Double) -> [Double] {
        guard rr.count >= 4 else { return rr }

        // Build time axis from cumulative RR
        var t = [Double](repeating: 0, count: rr.count)
        var cumTime: Double = 0
        for i in 0..<rr.count {
            t[i] = cumTime / 1000.0  // Convert to seconds
            cumTime += rr[i]
        }

        guard let tFirst = t.first, let tLast = t.last else { return rr }
        let duration = tLast - tFirst
        let sampleCount = Int(duration * fs) + 1
        guard sampleCount >= 4 else { return rr }

        var resampled = [Double](repeating: 0, count: sampleCount)
        var tIdx = 0

        for i in 0..<sampleCount {
            let targetT = tFirst + Double(i) / fs

            // Find surrounding points
            while tIdx < t.count - 1 && t[tIdx + 1] < targetT {
                tIdx += 1
            }

            if tIdx < t.count - 1 && t[tIdx + 1] > t[tIdx] {
                let frac = (targetT - t[tIdx]) / (t[tIdx + 1] - t[tIdx])
                resampled[i] = rr[tIdx] + frac * (rr[tIdx + 1] - rr[tIdx])
            } else {
                resampled[i] = rr[tIdx]
            }
        }

        return resampled
    }

    /// Simple moving average bandpass filter
    private static func bandpassFilter(_ signal: [Double], lowCut: Double, highCut: Double) -> [Double] {
        // Use difference of moving averages as simple bandpass
        let n = signal.count

        // High-pass: subtract slow moving average
        let slowWindow = max(3, Int(1.0 / lowCut))
        var highPassed = signal

        for i in 0..<n {
            let start = max(0, i - slowWindow / 2)
            let end = min(n, i + slowWindow / 2 + 1)
            let windowSum = signal[start..<end].reduce(0, +)
            let windowMean = windowSum / Double(end - start)
            highPassed[i] = signal[i] - windowMean
        }

        // Low-pass: fast moving average
        let fastWindow = max(2, Int(1.0 / highCut))
        var filtered = [Double](repeating: 0, count: n)

        for i in 0..<n {
            let start = max(0, i - fastWindow / 2)
            let end = min(n, i + fastWindow / 2 + 1)
            let windowSum = highPassed[start..<end].reduce(0, +)
            filtered[i] = windowSum / Double(end - start)
        }

        return filtered
    }
}
