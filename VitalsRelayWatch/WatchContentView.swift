import SwiftUI

/// A heart rate, a state, and one button. Nothing here needs to be looked at
/// while it works — it exists so you can tell whether it is working.
struct WatchContentView: View {
    @EnvironmentObject private var model: WatchModel

    var body: some View {
        VStack(spacing: 10) {
            heartRate

            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await model.toggle() }
            } label: {
                Text(model.workout.isRunning ? "Stop" : "Start")
                    .frame(maxWidth: .infinity)
            }
            .tint(model.workout.isRunning ? .red : .green)

            if let error = model.workout.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 4)
    }

    private var heartRate: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "heart.fill")
                .foregroundStyle(.red)
                .font(.title3)
            Text(model.workout.heartRate.map { String(format: "%.0f", $0) } ?? "––")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("bpm")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        guard model.workout.isRunning else { return "Idle" }
        return model.link.isReachable
            ? "Streaming to iPhone"
            : "iPhone unreachable · queuing"
    }
}
