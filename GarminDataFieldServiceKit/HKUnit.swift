//
//  HKUnit.swift
//  GarminDataFieldServiceKit
//
//  LoopKit's own HKUnit.milligramsPerDeciliter / .millimolesPerLiter are
//  internal, so every LoopKit service plugin (e.g. NightscoutServiceKit)
//  declares its own copy of these constants. Mirrors
//  NightscoutServiceKit/Extensions/HKUnit.swift exactly.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import HealthKit

extension HKUnit {

    static let milligramsPerDeciliter: HKUnit = {
        return HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
    }()

    static let millimolesPerLiter: HKUnit = {
        return HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter())
    }()

}
