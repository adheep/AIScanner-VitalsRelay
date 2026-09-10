import SwiftUI

/// One screen: where to send, whether it is sending, and what it last sent.
///
/// The stats grid is not the product — the socket is — but seeing the numbers
/// move on the phone is the only way to tell "the Watch has not synced yet"
/// apart from "the relay is broken", which is the question you will actually
/// be asking when something is wrong.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                destinationSection
                statusSection
                if !model.orderedLatest.isEmpty {
                    readingsSection
                }
                if !model.warnings.isEmpty {
                    warningsSection
                }
            }
            .navigationTitle("Vitals Relay")
            .safeAreaInset(edge: .bottom) {
                startStopButton
                    .padding()
                    .background(.bar)
            }
        }
    }

    // MARK: - Destination

    private var destinationSection: some View {
        Section {
            TextField("192.168.1.42:8000", text: $model.endpointText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .disabled(model.isRelaying)

            Toggle("Accept self-signed certificate", isOn: $model.allowSelfSigned)
                .disabled(model.isRelaying)

            Toggle("Keep screen awake while relaying", isOn: $model.keepScreenAwake)
        } header: {
            Text("WebApp address")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.endpoint.resolvedDescription)
                    .font(.footnote.monospaced())
                    .foregroundStyle(model.endpoint.isValid ? .secondary : Color.red)
                Text("Host and port are enough — the scheme and /ws/vitals path are filled in. Use the self-signed option when the WebApp runs with --https.")
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Socket") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(socketColor)
                        .frame(width: 8, height: 8)
                    Text(model.socket.state.label)
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("Apple Watch", value: model.watch.statusLabel)

            LabeledContent("Sent") {
                Text("\(model.socket.sentSamples) samples · \(model.socket.sentFrames) frames")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if let lastSentAt = model.socket.lastSentAt {
                LabeledContent("Last send") {
                    Text(lastSentAt, style: .relative)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if let reason = model.socket.lastFailureReason, !model.socket.state.isLive {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var socketColor: Color {
        switch model.socket.state {
        case .open:                   return .green
        case .connecting, .waiting:   return .orange
        case .failed:                 return .red
        case .idle:                   return .secondary
        }
    }

    // MARK: - Readings

    private var readingsSection: some View {
        Section("Latest readings") {
            ForEach(model.orderedLatest) { sample in
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(format(sample))
                            .monospacedDigit()
                        Text(subtitle(for: sample))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(sample.metric.displayName)
                        if sample.source == .watchLive {
                            Image(systemName: "bolt.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
        }
    }

    private func format(_ sample: VitalsSample) -> String {
        let decimals: Int
        switch sample.metric {
        case .steps, .distance, .activeEnergy: decimals = 0
        case .heartRate, .restingHeartRate, .walkingHeartRateAverage: decimals = 0
        default: decimals = 1
        }
        return String(format: "%.\(decimals)f %@", sample.value, sample.unit)
    }

    private func subtitle(for sample: VitalsSample) -> String {
        let age = Int(Date().timeIntervalSince(sample.end))
        let freshness = age < 5 ? "just now" : "\(age)s ago"
        if sample.metric.isDailyTotal { return "today" }
        return sample.source == .watchLive ? "live · " + freshness : freshness
    }

    // MARK: - Warnings

    private var warningsSection: some View {
        Section {
            ForEach(model.warnings, id: \.self) { warning in
                Text(warning)
                    .font(.footnote)
            }
            Button("Clear", role: .cancel) { model.clearWarnings() }
        } header: {
            Text("Notes")
        }
    }

    // MARK: - Start / stop

    private var startStopButton: some View {
        Button {
            if model.isRelaying {
                model.stop()
            } else {
                Task { await model.start() }
            }
        } label: {
            Text(model.isRelaying ? "Stop" : "Start relaying")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isRelaying ? .red : .accentColor)
        .disabled(!model.isRelaying && !model.endpoint.isValid)
    }
}
