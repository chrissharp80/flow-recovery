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

@main
struct FlowRecoveryApp: App {
    @StateObject private var collector = RRCollector()
    @State private var isLoading = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                if isLoading {
                    LaunchScreenView()
                        .transition(.opacity)
                } else {
                    MainTabView()
                        .environmentObject(collector)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: isLoading)
            .onChange(of: scenePhase) { oldPhase, newPhase in
                if newPhase == .background && collector.needsAcceptance {
                    // Auto-archive pending session when app goes to background
                    // This prevents data loss if the user forgets to accept
                    Task {
                        do {
                            try await collector.acceptSession()
                            debugLog("[App] Auto-archived pending session on background")
                        } catch {
                            debugLog("[App] Failed to auto-archive on background: \(error)")
                        }
                    }
                }
            }
            .task {
                // Brief pause to let launch screen render
                try? await Task.sleep(nanoseconds: 100_000_000)

                // Load sessions (triggers baseline calculation)
                _ = collector.archivedSessions

                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }

    init() {
        // Install crash handler first - before anything else can crash
        CrashLogManager.shared.install()

        // Register for memory warnings to clean up DFT cache
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            FrequencyDomainAnalyzer.teardownDFTCache()
        }
    }
}

// MARK: - Launch Screen

private struct LaunchScreenView: View {
    @State private var pulseAnimation = false

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.96, blue: 0.94),
                    Color(red: 0.92, green: 0.94, blue: 0.91)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                // App icon / heart animation
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.4, green: 0.5, blue: 0.45),
                                    Color(red: 0.3, green: 0.4, blue: 0.35)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 100, height: 100)
                        .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)

                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 44, weight: .medium))
                        .foregroundColor(.white)
                        .scaleEffect(pulseAnimation ? 1.1 : 1.0)
                        .animation(
                            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                            value: pulseAnimation
                        )
                }

                VStack(spacing: 8) {
                    Text("Flow Recovery")
                        .font(.title.bold())
                        .foregroundColor(Color(red: 0.2, green: 0.25, blue: 0.22))

                    Text("Loading your data...")
                        .font(.subheadline)
                        .foregroundColor(Color(red: 0.4, green: 0.45, blue: 0.42))
                }

                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: Color(red: 0.4, green: 0.5, blue: 0.45)))
                    .scaleEffect(1.2)
                    .padding(.top, 8)
            }
        }
        .onAppear {
            pulseAnimation = true
        }
    }
}
