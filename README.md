# Flow Recovery
A professional-grade HRV monitoring and recovery tracking app for iOS, designed for athletes and health-conscious individuals who want deep insights into their physiological state.

**[Join the TestFlight Beta](https://testflight.apple.com/join/G7SN14j9)**

## Overview

Flow Recovery connects to your Polar H10 chest strap to capture raw RR intervals and calculate comprehensive heart rate variability metrics. Combined with HealthKit integration for sleep, training, and vitals data, the app provides a complete picture of your recovery status and readiness to train.

## Key Features

### Recovery Dashboard
- **Daily Recovery Score** — Composite score (0-100) based on HRV, sleep quality, and training load
- **Smart Recommendations** — Contextual training guidance based on your current state
- **Trend Indicators** — Visual comparison to your personal baselines

### Advanced HRV Analysis
- **Time Domain Metrics** — RMSSD, SDNN, pNN50, Mean RR
- **Frequency Domain** — LF/HF power ratio for autonomic balance
- **Nonlinear Analysis** — DFA α1, Poincaré SD1/SD2
- **Artifact Detection** — Automatic identification and handling of ectopic beats

### Training Load Management
- **Acute/Chronic Workload** — ATL, CTL, and TSB calculations
- **Acute:Chronic Ratio** — Training readiness gauge with zone indicators
- **TRIMP Integration** — Training impulse tracking from workouts

### Sleep Integration
- **Sleep Score** — Quality assessment (0-100) from HealthKit data
- **Stage Analysis** — Deep, REM, core, and awake time breakdown
- **Recovery Correlation** — How sleep impacts your HRV trends

### Data Recording
- **Overnight Streaming** — Continuous RR capture during sleep
- **Quick Readings** — 1-5 minute morning measurements
- **Background Collection** — Reliable data capture even when app is backgrounded

### History & Trends
- **Session Archive** — Complete history with search and filtering
- **Tag System** — Organize sessions with custom tags
- **Statistical Analysis** — Period comparisons with min/max/avg/CV metrics
- **Export Options** — Share individual sessions or bulk export

## Requirements

### Required Hardware
- **Polar H10** chest strap — The app captures raw RR intervals via Bluetooth from this device. This is not optional; the app has no HRV functionality without it.
- **Apple Watch** — Required for sleep tracking. The app pulls sleep stages and duration from HealthKit, which requires an Apple Watch to record. Without a Watch, sleep-related insights and the sleep portion of recovery scoring won't work.

### Software
- **iOS 17.0** or later
- **HealthKit** access for sleep, workouts, and vitals

## Technical Highlights

- **SwiftUI** — Modern declarative UI throughout
- **Swift Concurrency** — Async/await and actors for thread safety
- **CoreBluetooth** — Direct Polar H10 communication for raw RR data
- **HealthKit** — Deep integration for comprehensive health data
- **Local Storage** — All data stays on-device with secure archival

## Architecture

```
FlowRecovery/
├── Sources/
│   ├── Views/           # SwiftUI views and screens
│   ├── ViewModels/      # Business logic and state management
│   ├── Models/          # Data models and types
│   ├── Services/        # Bluetooth, HealthKit, storage
│   └── Utilities/       # Helpers and extensions
└── Resources/           # Assets and configuration
```

## Building

1. Clone the repository
2. Open `FlowRecovery.xcodeproj` in Xcode 15+
3. Configure signing with your Apple Developer account
4. Build and run on a physical device (Bluetooth required)

## Privacy

Flow Recovery processes all health data locally on your device. No data is transmitted to external servers. HealthKit data access requires explicit user permission and follows Apple's health data guidelines.

## License

Copyright © 2024-2026 Chris Sharp. All rights reserved.

This source code is provided for reference and verification purposes only. Unauthorized copying, modification, distribution, or use of this code, via any medium, is strictly prohibited without prior written permission.

For licensing inquiries, contact the copyright holder.
