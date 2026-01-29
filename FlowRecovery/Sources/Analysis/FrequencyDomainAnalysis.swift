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

// MARK: - Frequency Domain Analysis
//
// This implementation follows standard HRV spectral analysis methodology:
//
// ## Windowing Choice: Hann Window
// - The Hann (Hanning) window is chosen over rectangular/Hamming/Blackman because:
//   1. Good frequency resolution with minimal spectral leakage
//   2. Widely used in HRV research, enabling comparison with published data
//   3. Side lobes -31dB below main lobe (better than rectangular's -13dB)
//   4. Smooth taper to zero at edges reduces edge artifacts in RR data
// - Trade-off: Slight loss of frequency resolution vs rectangular, but the leakage
//   reduction is critical for accurate LF/HF band power estimation
//
// ## Welch's Method
// - Overlapping segments with averaging reduces variance in PSD estimate
// - 50% overlap is standard for Hann window (optimal for minimum variance)
// - 256-sample segments at 4Hz = 64 seconds per segment
//   - This provides ~0.016 Hz frequency resolution (sufficient for LF/HF bands)
//   - Short enough to capture multiple segments in a 5-minute window
//   - Long enough for stable spectral estimates
//
// ## Resampling at 4 Hz
// - RR intervals are non-uniformly sampled (event-based)
// - Linear interpolation to uniform 4 Hz grid enables FFT
// - 4 Hz is standard in HRV analysis (Nyquist = 2 Hz, well above HF 0.4 Hz)
// - Higher sampling adds no information but increases computation
//
// ## Band Boundaries (per Task Force 1996 guidelines)
// - VLF: 0.003-0.04 Hz (requires 10+ min window for meaningful estimate)
// - LF: 0.04-0.15 Hz (mix of sympathetic/parasympathetic, also baroreceptor)
// - HF: 0.15-0.4 Hz (parasympathetic, respiratory sinus arrhythmia)
//
// References:
// - Task Force of ESC/NASPE (1996). Circulation 93:1043-1065
// - Welch, P.D. (1967). IEEE Trans Audio Electroacoustics AU-15:70-73

/// Frequency domain analysis using Welch's method
final class FrequencyDomainAnalyzer {

    // MARK: - DFT Cache

    private static var dftSetupCache: [Int: OpaquePointer] = [:]
    private static let dftCacheLock = NSLock()
    private static let maxCacheSize = 10 // Limit cache to prevent unbounded growth

    /// Get or create cached DFT setup for given size
    static func getDFTSetup(size: Int) -> OpaquePointer? {
        dftCacheLock.lock()
        defer { dftCacheLock.unlock() }

        if let existing = dftSetupCache[size] {
            return existing
        }

        // If cache is full, remove an arbitrary entry to make room
        if dftSetupCache.count >= maxCacheSize, let firstKey = dftSetupCache.keys.first {
            if let oldSetup = dftSetupCache.removeValue(forKey: firstKey) {
                vDSP_DFT_DestroySetupD(oldSetup)
            }
        }

        guard let setup = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(size), .FORWARD) else {
            return nil
        }
        dftSetupCache[size] = setup
        return setup
    }

    /// Call on app termination or memory warning to free DFT resources
    static func teardownDFTCache() {
        dftCacheLock.lock()
        defer { dftCacheLock.unlock() }

        for (_, setup) in dftSetupCache {
            vDSP_DFT_DestroySetupD(setup)
        }
        dftSetupCache.removeAll()
    }

    // MARK: - Constants

    /// Resampling frequency in Hz
    private static let resampleFrequency: Double = 4.0

    /// Frequency band boundaries (Hz)
    private static let vlfRange = HRVConstants.FrequencyBands.vlfLow..<HRVConstants.FrequencyBands.vlfHigh
    private static let lfRange = HRVConstants.FrequencyBands.lfLow..<HRVConstants.FrequencyBands.lfHigh
    private static let hfRange = HRVConstants.FrequencyBands.hfLow...HRVConstants.FrequencyBands.hfHigh

    /// Minimum window duration for VLF analysis (minutes)
    private static let vlfMinDuration: Double = HRVConstants.FrequencyBands.minimumVLFWindowMinutes * 2

    // MARK: - Welch Configuration

    /// Default segment length for Welch's method (256 samples = 64 sec at 4 Hz)
    private static let defaultWelchSegmentLength: Int = 256

    /// Overlap fraction for Welch's method (50%)
    private static let welchOverlap: Double = 0.5

    // MARK: - Public API

    /// Compute frequency domain metrics for a window of RR intervals
    /// - Parameters:
    ///   - series: The complete RR series
    ///   - flags: Artifact flags for each point
    ///   - windowStart: Start index in series
    ///   - windowEnd: End index in series (exclusive)
    /// - Returns: Frequency domain metrics, or nil if insufficient data
    static func computeFrequencyDomain(
        _ series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int,
        windowEnd: Int
    ) -> FrequencyDomainMetrics? {

        let windowPoints = Array(series.points[windowStart..<windowEnd])
        let windowFlags = Array(flags[windowStart..<windowEnd])

        guard windowPoints.count >= 120 else { return nil }

        // Build clean (time, rr) pairs using midpoint
        var t: [Double] = []
        var rr: [Double] = []
        for i in 0..<windowPoints.count where !windowFlags[i].isArtifact {
            t.append(windowPoints[i].midpointMs / 1000.0)
            rr.append(Double(windowPoints[i].rr_ms))
        }

        guard t.count >= 60,
              let tFirst = t.first,
              let tLast = t.last else { return nil }

        // Resample at 4 Hz
        let duration = tLast - tFirst
        let usableWindowMin = duration / 60.0  // VLF gating based on actual analyzed span
        let sampleCount = Int(round(duration * resampleFrequency)) + 1
        guard sampleCount >= 64 else { return nil }

        var resampled = [Double](repeating: 0, count: sampleCount)
        var tIdx = 0
        let tStart = tFirst

        for i in 0..<sampleCount {
            let targetT = tStart + Double(i) / resampleFrequency
            while tIdx < t.count - 1 && t[tIdx + 1] < targetT { tIdx += 1 }

            if tIdx < t.count - 1 && t[tIdx + 1] > t[tIdx] {
                let frac = (targetT - t[tIdx]) / (t[tIdx + 1] - t[tIdx])
                resampled[i] = rr[tIdx] + frac * (rr[tIdx + 1] - rr[tIdx])
            } else {
                resampled[i] = rr[tIdx]
            }
        }

        return computePSD(signal: resampled, fs: resampleFrequency, usableWindowMin: usableWindowMin)
    }

    /// Compute PSD using Welch's method (overlapping segments)
    /// Per design spec: 50% overlap, Hann window, averaged periodograms
    /// - Parameters:
    ///   - signal: Uniformly sampled signal (mean removed internally)
    ///   - fs: Sampling frequency in Hz
    ///   - segmentLength: FFT segment length (default 256 = 64 sec at 4 Hz)
    ///   - usableWindowMin: Duration in minutes for VLF gating
    /// - Returns: Frequency domain metrics
    static func computePSD(
        signal: [Double],
        fs: Double,
        segmentLength: Int? = nil,
        usableWindowMin: Double? = nil
    ) -> FrequencyDomainMetrics {

        var data = signal

        // Mean removal
        let mean = data.reduce(0, +) / Double(data.count)
        data = data.map { $0 - mean }

        let sampleCount = data.count

        // Determine segment length - use default or provided, but cap at signal length
        var segLen = segmentLength ?? defaultWelchSegmentLength

        // For short signals, fall back to single-window FFT
        if sampleCount < segLen {
            return computeSingleWindowPSD(signal: data, fs: fs, usableWindowMin: usableWindowMin)
        }

        // Round segment length to power of 2 for FFT efficiency
        let log2n = vDSP_Length(floor(log2(Double(segLen))))
        let fftN = 1 << Int(log2n)
        segLen = fftN

        // Compute step size for 50% overlap
        let stepSize = Int(Double(segLen) * (1.0 - welchOverlap))

        // Count number of segments
        let numSegments = (sampleCount - segLen) / stepSize + 1
        guard numSegments >= 1 else {
            return computeSingleWindowPSD(signal: data, fs: fs, usableWindowMin: usableWindowMin)
        }

        // Create Hann window
        var window = [Double](repeating: 0, count: segLen)
        vDSP_hann_windowD(&window, vDSP_Length(segLen), Int32(vDSP_HANN_DENORM))

        // Window power: U = (1/N) * Σw²
        var windowPower: Double = 0
        vDSP_dotprD(window, 1, window, 1, &windowPower, vDSP_Length(segLen))
        windowPower /= Double(segLen)

        // Get cached DFT setup
        guard let dftSetup = getDFTSetup(size: segLen) else {
            return FrequencyDomainMetrics(vlf: nil, lf: 0, hf: 0, lfHfRatio: nil, totalPower: 0)
        }

        // Averaged PSD across segments
        let halfN = segLen / 2
        var avgPsd = [Double](repeating: 0, count: halfN + 1)
        let norm = fs * Double(segLen) * windowPower

        // Reusable buffers
        var windowed = [Double](repeating: 0, count: segLen)
        var inputImag = [Double](repeating: 0, count: segLen)
        var outputReal = [Double](repeating: 0, count: segLen)
        var outputImag = [Double](repeating: 0, count: segLen)

        for seg in 0..<numSegments {
            let startIdx = seg * stepSize

            // Extract segment and apply window
            let segment = Array(data[startIdx..<(startIdx + segLen)])
            vDSP_vmulD(segment, 1, window, 1, &windowed, 1, vDSP_Length(segLen))

            // Reset imaginary input
            inputImag = [Double](repeating: 0, count: segLen)

            // DFT
            vDSP_DFT_ExecuteD(
                dftSetup,
                &windowed, &inputImag,
                &outputReal, &outputImag
            )

            // Accumulate one-sided periodogram
            avgPsd[0] += (outputReal[0] * outputReal[0] + outputImag[0] * outputImag[0]) / norm
            for k in 1..<halfN {
                let mag2 = outputReal[k] * outputReal[k] + outputImag[k] * outputImag[k]
                avgPsd[k] += (mag2 * 2.0) / norm
            }
            avgPsd[halfN] += (outputReal[halfN] * outputReal[halfN] + outputImag[halfN] * outputImag[halfN]) / norm
        }

        // Average across segments
        let segmentCount = Double(numSegments)
        for k in 0...halfN {
            avgPsd[k] /= segmentCount
        }

        // Integrate bands
        let freqRes = fs / Double(segLen)
        var vlf = 0.0, lf = 0.0, hf = 0.0

        for k in 0...halfN {
            let freq = Double(k) * freqRes
            let power = avgPsd[k] * freqRes

            if freq >= 0.003 && freq < 0.04 { vlf += power }
            else if freq >= 0.04 && freq < 0.15 { lf += power }
            else if freq >= 0.15 && freq <= 0.4 { hf += power }
        }

        let windowMin = usableWindowMin ?? (Double(sampleCount) / fs / 60.0)

        return FrequencyDomainMetrics(
            vlf: windowMin >= vlfMinDuration ? vlf : nil,
            lf: lf,
            hf: hf,
            lfHfRatio: hf > 0 ? lf / hf : nil,
            totalPower: (windowMin >= vlfMinDuration ? vlf : 0) + lf + hf
        )
    }

    // MARK: - Single Window Fallback

    /// Single-window FFT for short signals (fallback when Welch not possible)
    private static func computeSingleWindowPSD(
        signal: [Double],
        fs: Double,
        usableWindowMin: Double?
    ) -> FrequencyDomainMetrics {

        let sampleCount = signal.count
        let log2n = vDSP_Length(ceil(log2(Double(sampleCount))))
        let fftN = 1 << Int(log2n)

        // Pad with zeros
        var padded = signal
        padded.append(contentsOf: [Double](repeating: 0, count: fftN - sampleCount))

        // Apply Hann window
        var window = [Double](repeating: 0, count: fftN)
        vDSP_hann_windowD(&window, vDSP_Length(fftN), Int32(vDSP_HANN_DENORM))
        vDSP_vmulD(padded, 1, window, 1, &padded, 1, vDSP_Length(fftN))

        // Window power
        var windowPower: Double = 0
        vDSP_dotprD(window, 1, window, 1, &windowPower, vDSP_Length(fftN))
        windowPower /= Double(fftN)

        guard let dftSetup = getDFTSetup(size: fftN) else {
            return FrequencyDomainMetrics(vlf: nil, lf: 0, hf: 0, lfHfRatio: nil, totalPower: 0)
        }

        var inputReal = padded
        var inputImag = [Double](repeating: 0, count: fftN)
        var outputReal = [Double](repeating: 0, count: fftN)
        var outputImag = [Double](repeating: 0, count: fftN)

        vDSP_DFT_ExecuteD(
            dftSetup,
            &inputReal, &inputImag,
            &outputReal, &outputImag
        )

        let halfN = fftN / 2
        var psd = [Double](repeating: 0, count: halfN + 1)
        let norm = fs * Double(fftN) * windowPower

        psd[0] = (outputReal[0] * outputReal[0] + outputImag[0] * outputImag[0]) / norm
        for k in 1..<halfN {
            let mag2 = outputReal[k] * outputReal[k] + outputImag[k] * outputImag[k]
            psd[k] = (mag2 * 2.0) / norm
        }
        psd[halfN] = (outputReal[halfN] * outputReal[halfN] + outputImag[halfN] * outputImag[halfN]) / norm

        let freqRes = fs / Double(fftN)
        var vlf = 0.0, lf = 0.0, hf = 0.0

        for k in 0...halfN {
            let freq = Double(k) * freqRes
            let power = psd[k] * freqRes

            if freq >= 0.003 && freq < 0.04 { vlf += power }
            else if freq >= 0.04 && freq < 0.15 { lf += power }
            else if freq >= 0.15 && freq <= 0.4 { hf += power }
        }

        let windowMin = usableWindowMin ?? (Double(sampleCount) / fs / 60.0)

        return FrequencyDomainMetrics(
            vlf: windowMin >= vlfMinDuration ? vlf : nil,
            lf: lf,
            hf: hf,
            lfHfRatio: hf > 0 ? lf / hf : nil,
            totalPower: (windowMin >= vlfMinDuration ? vlf : 0) + lf + hf
        )
    }
}
