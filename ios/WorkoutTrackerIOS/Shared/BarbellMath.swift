import Foundation

// Kept in sync with web/src/lib/barbell.ts.

struct WarmupSet: Hashable {
    let weight: Double
    let reps: Int
}

enum BarbellMath {
    private static let plates: [WeightUnit: [Double]] = [
        .lb: [45, 35, 25, 10, 5, 2.5],
        .kg: [25, 20, 15, 10, 5, 2.5, 1.25]
    ]
    private static let warmupRamp: [(percent: Double, reps: Int)] = [(0.4, 5), (0.6, 3), (0.8, 2)]

    static func barWeight(_ unit: WeightUnit) -> Double { unit == .lb ? 45 : 20 }
    private static func loadIncrement(_ unit: WeightUnit) -> Double { unit == .lb ? 5 : 2.5 }

    /// Catalog-linked exercises use their equipment; unlinked T1/T2 lifts are assumed barbell.
    static func usesBarbell(equipment: String?, tier: String?) -> Bool {
        if let equipment { return equipment == "BARBELL" }
        return tier == "T1" || tier == "T2"
    }

    /// Plates per side, largest first, plus any amount that can't be loaded. Nil if below the bar.
    static func platesPerSide(total: Double, unit: WeightUnit) -> (plates: [Double], remainder: Double)? {
        let bar = barWeight(unit)
        guard total >= bar - 0.01 else { return nil }
        var remaining = Int(((total - bar) / 2 * 100).rounded())
        var out: [Double] = []
        for plate in plates[unit] ?? [] {
            let p = Int((plate * 100).rounded())
            while remaining >= p {
                out.append(plate)
                remaining -= p
            }
        }
        return (out, Double(remaining) / 100)
    }

    static func formatPlates(total: Double, unit: WeightUnit) -> String {
        guard let breakdown = platesPerSide(total: total, unit: unit) else { return "Below bar weight" }
        if breakdown.plates.isEmpty { return "Empty bar" }
        let text = breakdown.plates.map(format).joined(separator: " + ")
        return breakdown.remainder > 0 ? "\(text) /side (+\(format(breakdown.remainder)) short)" : "\(text) /side"
    }

    static func warmupSets(working: Double, unit: WeightUnit) -> [WarmupSet] {
        let bar = barWeight(unit)
        let inc = loadIncrement(unit)
        guard working > bar + inc else { return [] }
        var sets = [WarmupSet(weight: bar, reps: 10)]
        for step in warmupRamp {
            let weight = (working * step.percent / inc).rounded() * inc
            guard let last = sets.last, weight > last.weight, weight < working else { continue }
            sets.append(WarmupSet(weight: weight, reps: step.reps))
        }
        return sets
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%g", value)
    }
}
