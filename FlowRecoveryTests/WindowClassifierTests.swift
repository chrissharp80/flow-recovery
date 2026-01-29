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

/// Tests for WindowClassifier
/// Validates window classification logic for recovery assessment
final class WindowClassifierTests: XCTestCase {

    // MARK: - Classification Tests

    func testOptimalAlpha1ProducesOrganizedRecovery() {
        let metrics = WindowClassifier.WindowMetrics(
            cleanBeatCount: 400,
            dfaAlpha1: 0.85,
            lfHfRatio: 1.2,
            hrCoefficientOfVariation: 0.05
        )

        let result = WindowClassifier.classify(metrics)

        XCTAssertEqual(result.classification, .organizedRecovery)
        XCTAssertTrue(result.isOrganizedRecovery)
    }

    func testFlexibleAlpha1ProducesFlexibleClassification() {
        let metrics = WindowClassifier.WindowMetrics(
            cleanBeatCount: 400,
            dfaAlpha1: 0.65,  // Between 0.6 and 0.75
            lfHfRatio: 1.2,
            hrCoefficientOfVariation: 0.05
        )

        let result = WindowClassifier.classify(metrics)

        XCTAssertEqual(result.classification, .flexibleUnconsolidated)
        XCTAssertFalse(result.isOrganizedRecovery)
    }

    func testHighAlpha1ProducesHighVariability() {
        let metrics = WindowClassifier.WindowMetrics(
            cleanBeatCount: 400,
            dfaAlpha1: 1.3,  // Above 1.15
            lfHfRatio: 1.2,
            hrCoefficientOfVariation: 0.05
        )

        let result = WindowClassifier.classify(metrics)

        XCTAssertEqual(result.classification, .highVariability)
        XCTAssertFalse(result.isOrganizedRecovery)
    }

    func testLowAlpha1ProducesHighVariability() {
        let metrics = WindowClassifier.WindowMetrics(
            cleanBeatCount: 400,
            dfaAlpha1: 0.4,  // Below 0.6
            lfHfRatio: 1.2,
            hrCoefficientOfVariation: 0.05
        )

        let result = WindowClassifier.classify(metrics)

        XCTAssertEqual(result.classification, .highVariability)
        XCTAssertFalse(result.isOrganizedRecovery)
    }

    func testInsufficientBeatsProducesInsufficientClassification() {
        let metrics = WindowClassifier.WindowMetrics(
            cleanBeatCount: 50,  // Below 60
            dfaAlpha1: 0.85,
            lfHfRatio: 1.2,
            hrCoefficientOfVariation: 0.05
        )

        let result = WindowClassifier.classify(metrics)

        XCTAssertEqual(result.classification, .insufficient)
    }

    // MARK: - isOrganizedRecovery Tests

    func testOrganizedRecoveryRequiresOptimalAlpha1() {
        let optimalMetrics = WindowClassifier.WindowMetrics(
            cleanBeatCount: 400,
            dfaAlpha1: 0.85,  // In 0.75-1.0 range
            lfHfRatio: 1.2,
            hrCoefficientOfVariation: 0.05
        )

        let nonOptimalMetrics = WindowClassifier.WindowMetrics(
            cleanBeatCount: 400,
            dfaAlpha1: 1.2,  // Outside optimal range
            lfHfRatio: 1.2,
            hrCoefficientOfVariation: 0.05
        )

        XCTAssertTrue(WindowClassifier.isOrganizedRecovery(optimalMetrics))
        XCTAssertFalse(WindowClassifier.isOrganizedRecovery(nonOptimalMetrics))
    }

    func testOrganizedRecoveryWithHighLfHfButStableHR() {
        // Even with high LF/HF, stable HR can indicate organized recovery
        let metrics = WindowClassifier.WindowMetrics(
            cleanBeatCount: 400,
            dfaAlpha1: 0.85,
            lfHfRatio: 2.0,  // Above 1.5 threshold
            hrCoefficientOfVariation: 0.03  // Very stable HR
        )

        let result = WindowClassifier.isOrganizedRecovery(metrics)

        // Should still be organized if HR is stable
        XCTAssertTrue(result)
    }

    func testOrganizedRecoveryWithNilAlpha1UsesHRStability() {
        let stableMetrics = WindowClassifier.WindowMetrics(
            cleanBeatCount: 400,
            dfaAlpha1: nil,
            lfHfRatio: 1.2,
            hrCoefficientOfVariation: 0.05  // Below 0.08 threshold
        )

        let unstableMetrics = WindowClassifier.WindowMetrics(
            cleanBeatCount: 400,
            dfaAlpha1: nil,
            lfHfRatio: 1.2,
            hrCoefficientOfVariation: 0.12  // Above 0.08 threshold
        )

        XCTAssertTrue(WindowClassifier.isOrganizedRecovery(stableMetrics))
        XCTAssertFalse(WindowClassifier.isOrganizedRecovery(unstableMetrics))
    }

    // MARK: - Consolidation Tests

    func testConsolidationRequiresOrganizedAndStableHR() {
        let consolidatedMetrics = WindowClassifier.WindowMetrics(
            cleanBeatCount: 400,
            dfaAlpha1: 0.85,
            lfHfRatio: 1.2,
            hrCoefficientOfVariation: 0.05  // Stable
        )

        let unconsolidatedMetrics = WindowClassifier.WindowMetrics(
            cleanBeatCount: 400,
            dfaAlpha1: 0.85,
            lfHfRatio: 1.2,
            hrCoefficientOfVariation: 0.12  // Unstable
        )

        let consolidatedResult = WindowClassifier.classify(consolidatedMetrics)
        let unconsolidatedResult = WindowClassifier.classify(unconsolidatedMetrics)

        XCTAssertTrue(consolidatedResult.isConsolidated)
        XCTAssertFalse(unconsolidatedResult.isConsolidated)
    }

    // MARK: - Explanation Tests

    func testOrganizedConsolidatedExplanationMentionsLoadBearing() {
        let metrics = WindowClassifier.WindowMetrics(
            cleanBeatCount: 400,
            dfaAlpha1: 0.85,
            lfHfRatio: 1.2,
            hrCoefficientOfVariation: 0.05
        )

        let result = WindowClassifier.classify(metrics)

        XCTAssertTrue(result.explanation.contains("load-bearing"), "Explanation should mention load-bearing")
    }

    func testFlexibleExplanationMentionsCapacity() {
        let metrics = WindowClassifier.WindowMetrics(
            cleanBeatCount: 400,
            dfaAlpha1: 0.65,
            lfHfRatio: 1.2,
            hrCoefficientOfVariation: 0.05
        )

        let result = WindowClassifier.classify(metrics)

        XCTAssertTrue(result.explanation.contains("capacity"), "Flexible explanation should mention capacity")
    }

    func testHighVariabilityExplanationMentionsDisorganized() {
        let metrics = WindowClassifier.WindowMetrics(
            cleanBeatCount: 400,
            dfaAlpha1: 1.3,
            lfHfRatio: 1.2,
            hrCoefficientOfVariation: 0.05
        )

        let result = WindowClassifier.classify(metrics)

        XCTAssertTrue(
            result.explanation.lowercased().contains("disorganized") ||
            result.explanation.lowercased().contains("variability"),
            "High variability explanation should mention disorganized pattern"
        )
    }

    // MARK: - Stability Assessment Tests

    func testStabilityAssessmentWithAllGoodMetrics() {
        let assessment = WindowClassifier.assessStability(
            windowCV: 0.05,
            dfaAlpha1: 0.85,
            lfHfRatio: 1.2,
            isConsolidated: true,
            isShortSleep: false
        )

        XCTAssertTrue(assessment.isStable)
        XCTAssertFalse(assessment.hasUnstableWindow)
        XCTAssertFalse(assessment.hasFatigueSignal)
        XCTAssertFalse(assessment.hasSympatheticDominance)
        XCTAssertFalse(assessment.shouldNotPush)
        XCTAssertNil(assessment.reason)
    }

    func testStabilityAssessmentWithUnstableWindow() {
        let assessment = WindowClassifier.assessStability(
            windowCV: 0.12,  // Above 0.08 threshold
            dfaAlpha1: 0.85,
            lfHfRatio: 1.2,
            isConsolidated: true,
            isShortSleep: false
        )

        XCTAssertFalse(assessment.isStable)
        XCTAssertTrue(assessment.hasUnstableWindow)
        XCTAssertTrue(assessment.shouldNotPush)
        XCTAssertNotNil(assessment.reason)
    }

    func testStabilityAssessmentWithFatigueSignal() {
        let assessment = WindowClassifier.assessStability(
            windowCV: 0.05,
            dfaAlpha1: 1.3,  // Above 1.2 fatigue threshold
            lfHfRatio: 1.2,
            isConsolidated: true,
            isShortSleep: false
        )

        XCTAssertTrue(assessment.hasFatigueSignal)
        XCTAssertTrue(assessment.shouldNotPush)
        XCTAssertNotNil(assessment.reason)
    }

    func testStabilityAssessmentWithSympatheticDominance() {
        let assessment = WindowClassifier.assessStability(
            windowCV: 0.05,
            dfaAlpha1: 0.85,
            lfHfRatio: 4.0,  // Above 3.0 threshold
            isConsolidated: true,
            isShortSleep: false
        )

        XCTAssertTrue(assessment.hasSympatheticDominance)
        XCTAssertTrue(assessment.shouldNotPush)
        XCTAssertNotNil(assessment.reason)
    }

    func testStabilityAssessmentWithShortSleep() {
        let assessment = WindowClassifier.assessStability(
            windowCV: 0.05,
            dfaAlpha1: 0.85,
            lfHfRatio: 1.2,
            isConsolidated: true,
            isShortSleep: true
        )

        XCTAssertTrue(assessment.shouldNotPush)
        XCTAssertNotNil(assessment.reason)
        XCTAssertTrue(assessment.reason?.contains("sleep") ?? false)
    }

    func testStabilityAssessmentWithUnconsolidated() {
        let assessment = WindowClassifier.assessStability(
            windowCV: 0.05,
            dfaAlpha1: 0.85,
            lfHfRatio: 1.2,
            isConsolidated: false,
            isShortSleep: false
        )

        XCTAssertTrue(assessment.shouldNotPush)
        XCTAssertNotNil(assessment.reason)
    }

    // MARK: - Boundary Tests

    func testAlpha1AtExactOptimalBoundaries() {
        let lowerBoundary = WindowClassifier.WindowMetrics(
            cleanBeatCount: 400,
            dfaAlpha1: 0.75,  // Exact lower bound
            lfHfRatio: 1.2,
            hrCoefficientOfVariation: 0.05
        )

        let upperBoundary = WindowClassifier.WindowMetrics(
            cleanBeatCount: 400,
            dfaAlpha1: 1.0,  // Exact upper bound
            lfHfRatio: 1.2,
            hrCoefficientOfVariation: 0.05
        )

        XCTAssertEqual(WindowClassifier.classify(lowerBoundary).classification, .organizedRecovery)
        XCTAssertEqual(WindowClassifier.classify(upperBoundary).classification, .organizedRecovery)
    }

    func testCVAtExactThreshold() {
        let atThreshold = WindowClassifier.WindowMetrics(
            cleanBeatCount: 400,
            dfaAlpha1: 0.85,
            lfHfRatio: 1.2,
            hrCoefficientOfVariation: 0.08  // Exact threshold
        )

        let result = WindowClassifier.classify(atThreshold)

        // At exactly 0.08, should still be consolidated (not > 0.08)
        XCTAssertFalse(result.isConsolidated) // 0.08 is not < 0.08
    }

    func testBeatsAtMinimumThreshold() {
        let atMinimum = WindowClassifier.WindowMetrics(
            cleanBeatCount: 60,  // Exact minimum
            dfaAlpha1: 0.85,
            lfHfRatio: 1.2,
            hrCoefficientOfVariation: 0.05
        )

        let belowMinimum = WindowClassifier.WindowMetrics(
            cleanBeatCount: 59,  // Below minimum
            dfaAlpha1: 0.85,
            lfHfRatio: 1.2,
            hrCoefficientOfVariation: 0.05
        )

        XCTAssertNotEqual(WindowClassifier.classify(atMinimum).classification, .insufficient)
        XCTAssertEqual(WindowClassifier.classify(belowMinimum).classification, .insufficient)
    }

    // MARK: - Edge Cases

    func testNilLfHfRatioDoesNotBlockOrganizedRecovery() {
        let metrics = WindowClassifier.WindowMetrics(
            cleanBeatCount: 400,
            dfaAlpha1: 0.85,
            lfHfRatio: nil,
            hrCoefficientOfVariation: 0.05
        )

        let result = WindowClassifier.classify(metrics)

        XCTAssertEqual(result.classification, .organizedRecovery)
    }

    func testZeroBeatCountHandled() {
        let metrics = WindowClassifier.WindowMetrics(
            cleanBeatCount: 0,
            dfaAlpha1: 0.85,
            lfHfRatio: 1.2,
            hrCoefficientOfVariation: 0.05
        )

        let result = WindowClassifier.classify(metrics)

        XCTAssertEqual(result.classification, .insufficient)
    }
}
