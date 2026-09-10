import Foundation
import HealthKit

/// Bridges the wire vocabulary to HealthKit's. Shared by both targets so the
/// phone and the Watch can never disagree about what a "heartRate" is.
extension VitalsMetric {

    var quantityTypeIdentifier: HKQuantityTypeIdentifier {
        switch self {
        case .heartRate:               return .heartRate
        case .restingHeartRate:        return .restingHeartRate
        case .heartRateVariability:    return .heartRateVariabilitySDNN
        case .respiratoryRate:         return .respiratoryRate
        case .oxygenSaturation:        return .oxygenSaturation
        case .wristTemperature:        return .appleSleepingWristTemperature
        case .walkingHeartRateAverage: return .walkingHeartRateAverage
        case .vo2Max:                  return .vo2Max
        case .steps:                   return .stepCount
        case .activeEnergy:            return .activeEnergyBurned
        case .distance:                return .distanceWalkingRunning
        }
    }

    var quantityType: HKQuantityType? {
        HKQuantityType.quantityType(forIdentifier: quantityTypeIdentifier)
    }

    var hkUnit: HKUnit {
        switch self {
        case .heartRate, .restingHeartRate, .walkingHeartRateAverage, .respiratoryRate:
            return HKUnit.count().unitDivided(by: .minute())
        case .heartRateVariability:
            return HKUnit.secondUnit(with: .milli)
        case .oxygenSaturation:
            return HKUnit.percent()
        case .wristTemperature:
            return HKUnit.degreeCelsius()
        case .vo2Max:
            return HKUnit.literUnit(with: .milli)
                .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        case .steps:
            return HKUnit.count()
        case .activeEnergy:
            return HKUnit.kilocalorie()
        case .distance:
            return HKUnit.meter()
        }
    }

    /// HealthKit reports oxygen saturation as a fraction (0.0–1.0); every
    /// human-facing surface wants a percentage. Applied on the way out so the
    /// wire always matches `unitLabel`.
    var wireScale: Double {
        self == .oxygenSaturation ? 100.0 : 1.0
    }

    func wireValue(from quantity: HKQuantity) -> Double {
        quantity.doubleValue(for: hkUnit) * wireScale
    }

    /// Point-in-time readings. Streamed individually as they land.
    static let discrete: [VitalsMetric] = [
        .heartRate, .restingHeartRate, .heartRateVariability, .respiratoryRate,
        .oxygenSaturation, .wristTemperature, .walkingHeartRateAverage, .vo2Max,
    ]

    /// Running daily totals. Re-queried as a sum rather than streamed, because
    /// the individual samples are meaningless on their own.
    static let cumulative: [VitalsMetric] = [.steps, .activeEnergy, .distance]

    /// Everything the app asks permission to read.
    ///
    /// The `as HKObjectType?` is load-bearing: Set is invariant, so a
    /// Set<HKQuantityType> will not implicitly become the Set<HKObjectType>
    /// that requestAuthorization wants.
    static var readTypes: Set<HKObjectType> {
        Set(allCases.compactMap { $0.quantityType as HKObjectType? })
    }
}
