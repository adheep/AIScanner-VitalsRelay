import Foundation

/// Metric names as they appear on the wire.
///
/// These strings are the contract with the WebApp — they are not display text
/// and must not be renamed casually. `displayName` is what the UI shows.
enum VitalsMetric: String, Codable, CaseIterable, Hashable {
    case heartRate
    case restingHeartRate
    case heartRateVariability
    case respiratoryRate
    case oxygenSaturation
    case wristTemperature
    case walkingHeartRateAverage
    case vo2Max
    case steps
    case activeEnergy
    case distance

    var displayName: String {
        switch self {
        case .heartRate:              return "Heart Rate"
        case .restingHeartRate:       return "Resting HR"
        case .heartRateVariability:   return "HRV"
        case .respiratoryRate:        return "Respiration"
        case .oxygenSaturation:       return "Blood Oxygen"
        case .wristTemperature:       return "Wrist Temp"
        case .walkingHeartRateAverage: return "Walking HR"
        case .vo2Max:                 return "VO₂ Max"
        case .steps:                  return "Steps"
        case .activeEnergy:           return "Active Energy"
        case .distance:               return "Distance"
        }
    }

    /// Unit string sent alongside every value, so the WebApp never has to
    /// hardcode a lookup table of its own.
    var unitLabel: String {
        switch self {
        case .heartRate, .restingHeartRate, .walkingHeartRateAverage: return "bpm"
        case .heartRateVariability:  return "ms"
        case .respiratoryRate:       return "br/min"
        case .oxygenSaturation:      return "%"
        case .wristTemperature:      return "°C"
        case .vo2Max:                return "ml/kg/min"
        case .steps:                 return "steps"
        case .activeEnergy:          return "kcal"
        case .distance:              return "m"
        }
    }

    /// True for metrics that are a running total for the day rather than a
    /// point reading. The WebApp should replace these, never accumulate them.
    var isDailyTotal: Bool {
        switch self {
        case .steps, .activeEnergy, .distance: return true
        default: return false
        }
    }
}

/// One reading.
///
/// `source` is the important field for anyone consuming this: `watchLive`
/// samples are seconds old, `healthKit` samples are however stale the Watch's
/// last sync to the phone was — which can be minutes.
struct VitalsSample: Codable, Identifiable, Hashable {
    enum Source: String, Codable, Hashable {
        /// Streamed off an HKWorkoutSession on the Watch. Sub-second latency.
        case watchLive = "watch-live"
        /// Read out of HealthKit on the phone. Latency = Watch sync interval.
        case healthKit = "healthkit"
    }

    var metric: VitalsMetric
    var value: Double
    var unit: String
    var start: Date
    var end: Date
    var source: Source

    var id: String { "\(metric.rawValue)|\(end.timeIntervalSince1970)|\(value)" }

    init(metric: VitalsMetric, value: Double, start: Date, end: Date, source: Source) {
        self.metric = metric
        self.value = value
        self.unit = metric.unitLabel
        self.start = start
        self.end = end
        self.source = source
    }
}

/// What actually goes down the socket.
///
/// Batched rather than one-message-per-sample: a workout session emits heart
/// rate about once a second and the phone may hand over several metrics in the
/// same tick, and one framed message per tick is cheaper on both ends.
struct VitalsEnvelope: Codable {
    var type: String = "vitals"
    var deviceId: String
    var deviceName: String
    var sentAt: Date
    var samples: [VitalsSample]
}

/// Sent once immediately after the socket opens, so the server knows who
/// connected before any data arrives.
struct HelloEnvelope: Codable {
    var type: String = "hello"
    var deviceId: String
    var deviceName: String
    var appVersion: String
    var sentAt: Date
    /// Metrics this client is authorised to read and will attempt to send.
    var metrics: [String]
}

enum VitalsCoding {
    /// Epoch milliseconds both ways. Python reads that with
    /// `datetime.fromtimestamp(ms / 1000)` and JS with `new Date(ms)`;
    /// ISO-8601 with fractional seconds is a parsing chore in both.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
