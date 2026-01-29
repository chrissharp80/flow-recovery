//
//  Copyright © 2024-2026 Chris Sharp. All rights reserved.
//
//  This source code is provided for reference and verification purposes only.
//  Unauthorized copying, modification, distribution, or use of this code,
//  via any medium, is strictly prohibited without prior written permission.
//
//  For licensing inquiries, contact the copyright holder.
//

import AVFoundation
import UIKit

/// Manages silent audio playback to keep the app alive in background
/// Uses the audio background mode to prevent iOS from suspending the app during overnight HRV recording
final class BackgroundAudioManager: ObservableObject {
    static let shared = BackgroundAudioManager()

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var silentBuffer: AVAudioPCMBuffer?
    private var audioFormat: AVAudioFormat?
    @Published private(set) var isRunning = false
    @Published private(set) var wasInterrupted = false  // Track if we recovered from interruption

    private init() {
        setupInterruptionObserver()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Audio Session Interruption Handling

    private func setupInterruptionObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            debugLog("BackgroundAudioManager: Invalid interruption notification")
            return
        }

        switch type {
        case .began:
            debugLog("BackgroundAudioManager: Audio session interrupted (phone call, alarm, etc.)")
            // Audio is automatically paused by the system
            // We don't stop our state - we'll try to resume when interruption ends

        case .ended:
            debugLog("BackgroundAudioManager: Audio session interruption ended")

            // Check if we should resume
            guard isRunning else {
                debugLog("BackgroundAudioManager: Not running, won't resume after interruption")
                return
            }

            // Check if we can resume
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    debugLog("BackgroundAudioManager: System says we should resume - restarting audio")
                    resumeAfterInterruption()
                } else {
                    debugLog("BackgroundAudioManager: System says we should NOT resume, but trying anyway")
                    resumeAfterInterruption()
                }
            } else {
                // No options provided - try to resume anyway
                debugLog("BackgroundAudioManager: No resume options, attempting to restart")
                resumeAfterInterruption()
            }

        @unknown default:
            debugLog("BackgroundAudioManager: Unknown interruption type: \(typeValue)")
        }
    }

    private func resumeAfterInterruption() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRunning else { return }

            do {
                // Reactivate audio session
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setActive(true)

                // Restart engine if needed
                if let engine = self.audioEngine, !engine.isRunning {
                    try engine.start()
                    debugLog("BackgroundAudioManager: Restarted audio engine after interruption")
                }

                // Resume player if needed
                if let player = self.playerNode, !player.isPlaying {
                    if let buffer = self.silentBuffer {
                        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
                    }
                    player.play()
                    debugLog("BackgroundAudioManager: Resumed player after interruption")
                }

                self.wasInterrupted = true  // Flag that we recovered
                debugLog("BackgroundAudioManager: Successfully resumed after interruption")

            } catch {
                debugLog("BackgroundAudioManager: Failed to resume after interruption - \(error.localizedDescription)")
                // Try a full restart as last resort
                self.restartAudioCompletely()
            }
        }
    }

    private func restartAudioCompletely() {
        debugLog("BackgroundAudioManager: Attempting full restart after interruption failure")

        // Stop everything
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil

        // Small delay before restart
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.isRunning else { return }

            // Restart (isRunning is still true so startBackgroundAudio will skip guard)
            self.isRunning = false
            self.startBackgroundAudio()
        }
    }

    /// Start silent audio playback to keep app alive in background
    func startBackgroundAudio() {
        guard !isRunning else {
            debugLog("BackgroundAudioManager: Already running")
            return
        }

        debugLog("BackgroundAudioManager: Starting background audio")

        do {
            // Configure audio session for background playback
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)

            // Create audio engine and player node
            audioEngine = AVAudioEngine()
            playerNode = AVAudioPlayerNode()

            guard let engine = audioEngine, let player = playerNode else {
                debugLog("BackgroundAudioManager: Failed to create audio engine")
                return
            }

            engine.attach(player)

            // Create a silent audio buffer
            let sampleRate = 44100.0
            let duration = 1.0 // 1 second buffer
            let frameCount = AVAudioFrameCount(sampleRate * duration)

            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                debugLog("BackgroundAudioManager: Failed to create audio format/buffer")
                return
            }

            // Fill buffer with silence (zeros)
            buffer.frameLength = frameCount
            if let channelData = buffer.floatChannelData?[0] {
                for i in 0..<Int(frameCount) {
                    channelData[i] = 0.0
                }
            }

            // Save buffer and format for interruption recovery
            self.silentBuffer = buffer
            self.audioFormat = format

            // Connect player to main mixer
            let mainMixer = engine.mainMixerNode
            engine.connect(player, to: mainMixer, format: format)

            // Set volume very low (just in case)
            mainMixer.outputVolume = 0.01

            // Start engine
            try engine.start()

            // Schedule buffer to loop indefinitely
            player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            player.play()

            isRunning = true
            // No logging - start/stop already logged in RRCollector

            // Also disable idle timer to keep screen from dimming
            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = true
            }

        } catch {
            debugLog("BackgroundAudioManager: Error starting audio - \(error.localizedDescription)")
        }
    }

    /// Stop background audio playback
    func stopBackgroundAudio() {
        guard isRunning else {
            debugLog("BackgroundAudioManager: Not running, nothing to stop")
            return
        }

        debugLog("BackgroundAudioManager: Stopping background audio")

        playerNode?.stop()
        audioEngine?.stop()

        playerNode = nil
        audioEngine = nil
        silentBuffer = nil
        audioFormat = nil

        // Deactivate audio session
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            debugLog("BackgroundAudioManager: Error deactivating audio session - \(error.localizedDescription)")
        }

        isRunning = false
        wasInterrupted = false

        // Re-enable idle timer
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }

        // No logging - start/stop already logged in RRCollector
    }
}
