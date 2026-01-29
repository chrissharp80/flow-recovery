//
//  Copyright © 2024-2026 Flow Recovery. All rights reserved.
//
//  This source code is provided for reference and verification purposes only.
//  Unauthorized copying, modification, distribution, or use of this code,
//  via any medium, is strictly prohibited without prior written permission.
//
//  For licensing inquiries, contact the copyright holder.
//

import XCTest
@testable import FlowRecovery

/// Tests for DFAAnalyzer
/// Validates Detrended Fluctuation Analysis computation
final class DFAAnalysisTests: XCTestCase {

    // MARK: - Test Helpers

    /// Create RR intervals with known statistical properties
    private func createRRIntervals(count: Int, meanMs: Double = 850, variability: Double = 50) -> [Double] {
        var rr = [Double]()
        for i in 0..<count {
            let variation = sin(Double(i) * 0.3) * variability
            rr.append(meanMs + variation)
        }
        return rr
    }

    /// Create random walk RR (should have α1 ≈ 1.5)
    private func createRandomWalkRR(count: Int) -> [Double] {
        var rr = [Double]()
        var current = 850.0
        for _ in 0..<count {
            current += Double.random(in: -20...20)
            current = max(500, min(1200, current)) // Keep in physiological range
            rr.append(current)
        }
        return rr
    }

    /// Create white noise RR (should have α1 ≈ 0.5)
    private func createWhiteNoiseRR(count: Int) -> [Double] {
        return (0..<count).map { _ in 850 + Double.random(in: -50...50) }
    }

    /// Create correlated RR (should have α1 close to 1.0)
    private func createCorrelatedRR(count: Int) -> [Double] {
        var rr = [Double]()
        var current = 850.0
        for i in 0..<count {
            // Pink noise-like: mix of short and long correlations
            let short = sin(Double(i) * 0.5) * 20
            let medium = sin(Double(i) * 0.1) * 30
            let long = sin(Double(i) * 0.02) * 15
            current = 850 + short + medium + long + Double.random(in: -5...5)
            rr.append(current)
        }
        return rr
    }

    // MARK: - Basic Computation Tests

    func testDFARequiresMinimumSamples() {
        let shortRR = createRRIntervals(count: 50) // Less than 64
        let result = DFAAnalyzer.compute(shortRR)
        XCTAssertNil(result, "Should return nil with fewer than 64 samples")
    }

    func testDFAWithMinimumSamples() {
        let rr = createRRIntervals(count: 64)
        let result = DFAAnalyzer.compute(rr)
        XCTAssertNotNil(result, "Should compute with exactly 64 samples")
    }

    func testDFAAlpha1InPhysiologicalRange() {
        let rr = createCorrelatedRR(count: 300)
        let result = DFAAnalyzer.compute(rr)

        XCTAssertNotNil(result)
        // Physiological α1 typically ranges from 0.5 to 1.5
        XCTAssertGreaterThan(result!.alpha1, 0.3, "α1 should be above 0.3")
        XCTAssertLessThan(result!.alpha1, 2.0, "α1 should be below 2.0")
    }

    func testDFAReturnsValidR2() {
        let rr = createCorrelatedRR(count: 200)
        let result = DFAAnalyzer.compute(rr)

        XCTAssertNotNil(result)
        XCTAssertGreaterThanOrEqual(result!.alpha1R2, 0, "R² should be >= 0")
        XCTAssertLessThanOrEqual(result!.alpha1R2, 1, "R² should be <= 1")
    }

    // MARK: - Alpha2 Tests

    func testAlpha2RequiresSufficientData() {
        let shortRR = createRRIntervals(count: 100) // Less than 256
        let result = DFAAnalyzer.compute(shortRR)

        XCTAssertNotNil(result)
        XCTAssertNil(result!.alpha2, "α2 should be nil without sufficient data")
    }

    func testAlpha2WithSufficientData() {
        let rr = createCorrelatedRR(count: 500)
        let result = DFAAnalyzer.compute(rr)

        XCTAssertNotNil(result)
        XCTAssertNotNil(result!.alpha2, "α2 should be computed with 500+ samples")
        XCTAssertNotNil(result!.alpha2R2)
    }

    func testAlpha2InReasonableRange() {
        let rr = createCorrelatedRR(count: 500)
        let result = DFAAnalyzer.compute(rr)

        XCTAssertNotNil(result?.alpha2)
        // α2 typically ranges from 0.5 to 1.5 for physiological signals
        XCTAssertGreaterThan(result!.alpha2!, 0.2)
        XCTAssertLessThan(result!.alpha2!, 2.0)
    }

    // MARK: - Statistical Property Tests

    func testWhiteNoiseProducesLowAlpha() {
        // White noise should have α1 ≈ 0.5
        var alphas: [Double] = []
        for _ in 0..<5 {
            let rr = createWhiteNoiseRR(count: 300)
            if let result = DFAAnalyzer.compute(rr) {
                alphas.append(result.alpha1)
            }
        }

        XCTAssertFalse(alphas.isEmpty)
        let avgAlpha = alphas.reduce(0, +) / Double(alphas.count)
        // Should be closer to 0.5 than 1.0
        XCTAssertLessThan(avgAlpha, 0.9, "White noise should produce α1 closer to 0.5")
    }

    func testCorrelatedSignalProducesModerateAlpha() {
        // Correlated signal should have α1 closer to 1.0
        let rr = createCorrelatedRR(count: 300)
        let result = DFAAnalyzer.compute(rr)

        XCTAssertNotNil(result)
        // Pink noise (healthy HRV) has α1 around 1.0
        XCTAssertGreaterThan(result!.alpha1, 0.6, "Correlated signal should have α1 > 0.6")
        XCTAssertLessThan(result!.alpha1, 1.4, "Correlated signal should have α1 < 1.4")
    }

    // MARK: - Custom Range Tests

    func testCustomAlpha1Range() {
        let rr = createCorrelatedRR(count: 200)

        let defaultResult = DFAAnalyzer.compute(rr)
        let customResult = DFAAnalyzer.compute(rr, alpha1Range: 5...12)

        XCTAssertNotNil(defaultResult)
        XCTAssertNotNil(customResult)
        // Results may differ slightly due to different box sizes
        XCTAssertNotEqual(defaultResult!.alpha1, customResult!.alpha1, accuracy: 0.01)
    }

    // MARK: - Reproducibility Tests

    func testDFAIsReproducible() {
        let rr = createCorrelatedRR(count: 300)

        let result1 = DFAAnalyzer.compute(rr)
        let result2 = DFAAnalyzer.compute(rr)

        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
        XCTAssertEqual(result1!.alpha1, result2!.alpha1, accuracy: 0.0001,
            "Same input should produce identical output")
    }

    // MARK: - Edge Cases

    func testDFAWithConstantRR() {
        let constantRR = [Double](repeating: 850, count: 100)
        let result = DFAAnalyzer.compute(constantRR)

        // Constant signal has zero fluctuation - may produce extreme values
        // The algorithm should still complete without crashing
        if let r = result {
            XCTAssertFalse(r.alpha1.isNaN, "α1 should not be NaN")
            XCTAssertFalse(r.alpha1.isInfinite, "α1 should not be infinite")
        }
    }

    func testDFAWithLargeDataset() {
        // Simulate long recording (2 hours at 60bpm = 7200 beats)
        let rr = createCorrelatedRR(count: 7200)
        let result = DFAAnalyzer.compute(rr)

        XCTAssertNotNil(result)
        XCTAssertNotNil(result!.alpha2, "Should compute α2 with large dataset")
    }

    func testDFAWithHighVariability() {
        // Very high variability (large RR range)
        var rr = [Double]()
        for i in 0..<300 {
            rr.append(600 + sin(Double(i) * 0.2) * 300) // Range 300-900ms
        }

        let result = DFAAnalyzer.compute(rr)
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.alpha1.isNaN)
    }

    // MARK: - R² Quality Tests

    func testGoodFitProducesHighR2() {
        // Well-structured data should produce good R² fit
        let rr = createCorrelatedRR(count: 500)
        let result = DFAAnalyzer.compute(rr)

        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result!.alpha1R2, 0.7,
            "Well-structured data should have R² > 0.7")
    }
}
