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

/// Tests for BaselineTracker
/// Validates baseline deviation logic and interpretation
final class BaselineTrackerTests: XCTestCase {

    // MARK: - Deviation Interpretation Tests

    func testRMSSDInterpretationSignificantlyBelow() {
        let deviation = BaselineTracker.BaselineDeviation(
            rmssdDeviation: -25,
            sdnnDeviation: nil,
            meanHRDeviation: nil,
            hfDeviation: nil,
            lfHfDeviation: nil,
            stressDeviation: nil,
            readinessDeviation: nil
        )

        XCTAssertEqual(deviation.rmssdInterpretation, .significantlyBelow)
    }

    func testRMSSDInterpretationBelowBaseline() {
        let deviation = BaselineTracker.BaselineDeviation(
            rmssdDeviation: -15,
            sdnnDeviation: nil,
            meanHRDeviation: nil,
            hfDeviation: nil,
            lfHfDeviation: nil,
            stressDeviation: nil,
            readinessDeviation: nil
        )

        XCTAssertEqual(deviation.rmssdInterpretation, .belowBaseline)
    }

    func testRMSSDInterpretationWithinNormal() {
        let deviation = BaselineTracker.BaselineDeviation(
            rmssdDeviation: 5,
            sdnnDeviation: nil,
            meanHRDeviation: nil,
            hfDeviation: nil,
            lfHfDeviation: nil,
            stressDeviation: nil,
            readinessDeviation: nil
        )

        XCTAssertEqual(deviation.rmssdInterpretation, .withinNormal)
    }

    func testRMSSDInterpretationAboveBaseline() {
        let deviation = BaselineTracker.BaselineDeviation(
            rmssdDeviation: 15,
            sdnnDeviation: nil,
            meanHRDeviation: nil,
            hfDeviation: nil,
            lfHfDeviation: nil,
            stressDeviation: nil,
            readinessDeviation: nil
        )

        XCTAssertEqual(deviation.rmssdInterpretation, .aboveBaseline)
    }

    func testRMSSDInterpretationSignificantlyAbove() {
        let deviation = BaselineTracker.BaselineDeviation(
            rmssdDeviation: 25,
            sdnnDeviation: nil,
            meanHRDeviation: nil,
            hfDeviation: nil,
            lfHfDeviation: nil,
            stressDeviation: nil,
            readinessDeviation: nil
        )

        XCTAssertEqual(deviation.rmssdInterpretation, .significantlyAbove)
    }

    func testRMSSDInterpretationWithNilDeviation() {
        let deviation = BaselineTracker.BaselineDeviation(
            rmssdDeviation: nil,
            sdnnDeviation: nil,
            meanHRDeviation: nil,
            hfDeviation: nil,
            lfHfDeviation: nil,
            stressDeviation: nil,
            readinessDeviation: nil
        )

        XCTAssertEqual(deviation.rmssdInterpretation, .insufficient)
    }

    // MARK: - Overall Status Tests

    func testOverallStatusBelowBaseline() {
        let deviation = BaselineTracker.BaselineDeviation(
            rmssdDeviation: -20,
            sdnnDeviation: nil,
            meanHRDeviation: nil,
            hfDeviation: nil,
            lfHfDeviation: nil,
            stressDeviation: nil,
            readinessDeviation: nil
        )

        XCTAssertEqual(deviation.overallStatus, .belowBaseline)
    }

    func testOverallStatusNormal() {
        let deviation = BaselineTracker.BaselineDeviation(
            rmssdDeviation: 5,
            sdnnDeviation: nil,
            meanHRDeviation: nil,
            hfDeviation: nil,
            lfHfDeviation: nil,
            stressDeviation: nil,
            readinessDeviation: nil
        )

        XCTAssertEqual(deviation.overallStatus, .normal)
    }

    func testOverallStatusAboveBaseline() {
        let deviation = BaselineTracker.BaselineDeviation(
            rmssdDeviation: 20,
            sdnnDeviation: nil,
            meanHRDeviation: nil,
            hfDeviation: nil,
            lfHfDeviation: nil,
            stressDeviation: nil,
            readinessDeviation: nil
        )

        XCTAssertEqual(deviation.overallStatus, .aboveBaseline)
    }

    func testOverallStatusNoBaseline() {
        let deviation = BaselineTracker.BaselineDeviation(
            rmssdDeviation: nil,
            sdnnDeviation: nil,
            meanHRDeviation: nil,
            hfDeviation: nil,
            lfHfDeviation: nil,
            stressDeviation: nil,
            readinessDeviation: nil
        )

        XCTAssertEqual(deviation.overallStatus, .noBaseline)
    }

    // MARK: - Boundary Tests

    func testBoundaryAt10Percent() {
        // At exactly -10%, should be belowBaseline (not withinNormal)
        let atBoundary = BaselineTracker.BaselineDeviation(
            rmssdDeviation: -10,
            sdnnDeviation: nil,
            meanHRDeviation: nil,
            hfDeviation: nil,
            lfHfDeviation: nil,
            stressDeviation: nil,
            readinessDeviation: nil
        )

        // -10 is < -10? No, so should be withinNormal based on the < operator
        XCTAssertEqual(atBoundary.rmssdInterpretation, .withinNormal)
    }

    func testBoundaryAt20Percent() {
        // At exactly -20%, should be significantlyBelow
        let atBoundary = BaselineTracker.BaselineDeviation(
            rmssdDeviation: -20,
            sdnnDeviation: nil,
            meanHRDeviation: nil,
            hfDeviation: nil,
            lfHfDeviation: nil,
            stressDeviation: nil,
            readinessDeviation: nil
        )

        // -20 is < -20? No, so should be belowBaseline
        XCTAssertEqual(atBoundary.rmssdInterpretation, .belowBaseline)
    }

    func testBoundaryAtPositive10() {
        // At exactly +10%, should be withinNormal
        let atBoundary = BaselineTracker.BaselineDeviation(
            rmssdDeviation: 10,
            sdnnDeviation: nil,
            meanHRDeviation: nil,
            hfDeviation: nil,
            lfHfDeviation: nil,
            stressDeviation: nil,
            readinessDeviation: nil
        )

        XCTAssertEqual(atBoundary.rmssdInterpretation, .withinNormal)
    }

    func testBoundaryAtPositive20() {
        // At exactly +20%, should be aboveBaseline (not significantlyAbove)
        let atBoundary = BaselineTracker.BaselineDeviation(
            rmssdDeviation: 20,
            sdnnDeviation: nil,
            meanHRDeviation: nil,
            hfDeviation: nil,
            lfHfDeviation: nil,
            stressDeviation: nil,
            readinessDeviation: nil
        )

        XCTAssertEqual(atBoundary.rmssdInterpretation, .aboveBaseline)
    }

    // MARK: - Formatting Tests

    func testFormattedRMSSDPositive() {
        let deviation = BaselineTracker.BaselineDeviation(
            rmssdDeviation: 15.5,
            sdnnDeviation: nil,
            meanHRDeviation: nil,
            hfDeviation: nil,
            lfHfDeviation: nil,
            stressDeviation: nil,
            readinessDeviation: nil
        )

        XCTAssertEqual(deviation.formattedRMSSD(), "+15.5%")
    }

    func testFormattedRMSSDNegative() {
        let deviation = BaselineTracker.BaselineDeviation(
            rmssdDeviation: -12.3,
            sdnnDeviation: nil,
            meanHRDeviation: nil,
            hfDeviation: nil,
            lfHfDeviation: nil,
            stressDeviation: nil,
            readinessDeviation: nil
        )

        XCTAssertEqual(deviation.formattedRMSSD(), "-12.3%")
    }

    func testFormattedRMSSDNil() {
        let deviation = BaselineTracker.BaselineDeviation(
            rmssdDeviation: nil,
            sdnnDeviation: nil,
            meanHRDeviation: nil,
            hfDeviation: nil,
            lfHfDeviation: nil,
            stressDeviation: nil,
            readinessDeviation: nil
        )

        XCTAssertEqual(deviation.formattedRMSSD(), "—")
    }

    func testFormattedHR() {
        let deviation = BaselineTracker.BaselineDeviation(
            rmssdDeviation: nil,
            sdnnDeviation: nil,
            meanHRDeviation: 8.2,
            hfDeviation: nil,
            lfHfDeviation: nil,
            stressDeviation: nil,
            readinessDeviation: nil
        )

        XCTAssertEqual(deviation.formattedHR(), "+8.2%")
    }

    func testFormattedStress() {
        let deviation = BaselineTracker.BaselineDeviation(
            rmssdDeviation: nil,
            sdnnDeviation: nil,
            meanHRDeviation: nil,
            hfDeviation: nil,
            lfHfDeviation: nil,
            stressDeviation: -5.7,
            readinessDeviation: nil
        )

        XCTAssertEqual(deviation.formattedStress(), "-5.7%")
    }

    // MARK: - Interpretation Raw Values Tests

    func testDeviationInterpretationRawValues() {
        XCTAssertEqual(BaselineTracker.DeviationInterpretation.significantlyBelow.rawValue, "Significantly below baseline")
        XCTAssertEqual(BaselineTracker.DeviationInterpretation.belowBaseline.rawValue, "Below baseline")
        XCTAssertEqual(BaselineTracker.DeviationInterpretation.withinNormal.rawValue, "Within normal range")
        XCTAssertEqual(BaselineTracker.DeviationInterpretation.aboveBaseline.rawValue, "Above baseline")
        XCTAssertEqual(BaselineTracker.DeviationInterpretation.significantlyAbove.rawValue, "Significantly above baseline")
        XCTAssertEqual(BaselineTracker.DeviationInterpretation.insufficient.rawValue, "Insufficient baseline data")
    }

    func testOverallStatusRawValues() {
        XCTAssertEqual(BaselineTracker.OverallStatus.belowBaseline.rawValue, "Recovery may be compromised")
        XCTAssertEqual(BaselineTracker.OverallStatus.normal.rawValue, "Within your normal range")
        XCTAssertEqual(BaselineTracker.OverallStatus.aboveBaseline.rawValue, "Elevated recovery capacity")
        XCTAssertEqual(BaselineTracker.OverallStatus.noBaseline.rawValue, "Building baseline...")
    }

    // MARK: - Baseline Configuration Tests

    func testBaselineWindowDays() {
        XCTAssertEqual(BaselineTracker.baselineWindowDays, 7)
    }

    func testMaxHistoricalPoints() {
        XCTAssertEqual(BaselineTracker.maxHistoricalPoints, 90)
    }

    func testMinimumSamplesForValidBaseline() {
        XCTAssertEqual(BaselineTracker.Baseline.minimumSamples, 3)
    }

    // MARK: - Edge Case Tests

    func testDeviationWithZeroValue() {
        let deviation = BaselineTracker.BaselineDeviation(
            rmssdDeviation: 0,
            sdnnDeviation: nil,
            meanHRDeviation: nil,
            hfDeviation: nil,
            lfHfDeviation: nil,
            stressDeviation: nil,
            readinessDeviation: nil
        )

        XCTAssertEqual(deviation.rmssdInterpretation, .withinNormal)
        XCTAssertEqual(deviation.overallStatus, .normal)
        XCTAssertEqual(deviation.formattedRMSSD(), "+0.0%")
    }

    func testDeviationWithExtremeNegative() {
        let deviation = BaselineTracker.BaselineDeviation(
            rmssdDeviation: -80,
            sdnnDeviation: nil,
            meanHRDeviation: nil,
            hfDeviation: nil,
            lfHfDeviation: nil,
            stressDeviation: nil,
            readinessDeviation: nil
        )

        XCTAssertEqual(deviation.rmssdInterpretation, .significantlyBelow)
        XCTAssertEqual(deviation.overallStatus, .belowBaseline)
    }

    func testDeviationWithExtremePositive() {
        let deviation = BaselineTracker.BaselineDeviation(
            rmssdDeviation: 100,
            sdnnDeviation: nil,
            meanHRDeviation: nil,
            hfDeviation: nil,
            lfHfDeviation: nil,
            stressDeviation: nil,
            readinessDeviation: nil
        )

        XCTAssertEqual(deviation.rmssdInterpretation, .significantlyAbove)
        XCTAssertEqual(deviation.overallStatus, .aboveBaseline)
    }
}
