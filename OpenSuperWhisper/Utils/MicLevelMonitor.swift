import AVFoundation
import Foundation
import SwiftUI

/// Lightweight live input-level monitor used by Settings to let the user
/// test their microphone and see whether the level is high enough for
/// reliable transcription. Uses an `AVAudioEngine` input tap (no file I/O).
final class MicLevelMonitor: ObservableObject {
    /// Normalized level in 0...1 (mapped from `Self.floorDb`...0 dBFS).
    @Published var level: Float = 0
    /// Most recent peak power in dBFS (~ -160...0).
    @Published var peakDb: Float = MicLevelMonitor.floorDb

    /// Bottom of the displayed range, in dBFS.
    static let floorDb: Float = -60

    private let engine = AVAudioEngine()
    private var isRunning = false

    var isTooQuiet: Bool { peakDb < AudioRecorder.lowAudioPeakThreshold }

    /// Position (0...1) of the low-audio threshold within the meter range.
    static var thresholdFraction: CGFloat {
        CGFloat((AudioRecorder.lowAudioPeakThreshold - floorDb) / (0 - floorDb))
    }

    func start() {
        guard !isRunning else { return }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        // A 0 sample-rate format means no usable input device; bail out.
        guard format.sampleRate > 0 else { return }

        // Defensively remove any stale tap before installing a new one
        // (only one tap per bus is allowed).
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            var peak: Float = 0
            for i in 0..<frames {
                peak = max(peak, abs(channel[i]))
            }
            let floor = MicLevelMonitor.floorDb
            let db = peak > 0 ? 20 * log10(peak) : floor
            let clamped = max(floor, min(0, db))
            let normalized = (clamped - floor) / (0 - floor)
            DispatchQueue.main.async { [weak self] in
                self?.peakDb = clamped
                self?.level = normalized
            }
        }

        do {
            try engine.start()
            isRunning = true
        } catch {
            print("MicLevelMonitor failed to start: \(error)")
            // Don't leave an orphaned tap behind if the engine won't start.
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        // Always tear down the tap/engine, even if a previous start() failed
        // after installing the tap (so isRunning was never set).
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        isRunning = false
        level = 0
        peakDb = Self.floorDb
    }
}

/// A horizontal meter that shows the live mic level with a marker at the
/// low-audio threshold. Green above the threshold, orange below it.
struct MicLevelMeter: View {
    @ObservedObject var monitor: MicLevelMonitor

    private var barColor: Color {
        monitor.isTooQuiet ? .orange : .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.controlBackgroundColor))

                    RoundedRectangle(cornerRadius: 4)
                        .fill(barColor)
                        .frame(width: max(2, geo.size.width * CGFloat(monitor.level)))
                        .animation(.linear(duration: 0.05), value: monitor.level)

                    // Threshold marker
                    Rectangle()
                        .fill(Color.secondary)
                        .frame(width: 1.5)
                        .offset(x: geo.size.width * MicLevelMonitor.thresholdFraction)
                }
            }
            .frame(height: 10)

            Text(monitor.isTooQuiet
                 ? "Too quiet — raise your input volume below or in Sound settings."
                 : "Level looks good.")
                .font(.caption)
                .foregroundColor(monitor.isTooQuiet ? .orange : .secondary)
        }
    }
}
