import Foundation

enum WeightUnit: String, Codable, CaseIterable, Identifiable {
    case kg
    case lb

    var id: String { rawValue }

    var label: String { rawValue }
}

enum WeightMath {
    static let lbPerKg = 2.2046226218

    static func convertKgToUnit(_ valueKg: Double, unit: WeightUnit) -> Double {
        unit == .lb ? valueKg * lbPerKg : valueKg
    }

    static func convertUnitToKg(_ value: Double, unit: WeightUnit) -> Double {
        unit == .lb ? value / lbPerKg : value
    }

    static func snapHalf(_ value: Double) -> Double {
        (value * 2).rounded() / 2
    }

    static func displayWeightFromKg(_ valueKg: Double, unit: WeightUnit, digits: Int = 1) -> String {
        let converted = convertKgToUnit(valueKg, unit: unit)
        let snapped = snapHalf(converted)
        return String(format: "%0.*f", max(1, digits), snapped)
    }
}
