//
//  WatchStateBuilder.swift
//  GarminDataFieldServiceKit
//
//  Pure assembly of `[GarminWatchState]` from cached Loop data. Mirrors the
//  behavior of Trio's `setupGarminWatchState()` so the payload drives the
//  published Trio/SwissAlpine watch apps identically. The IOB formatting and
//  stale-loop sentinel are ported from Trio's GarminManager.swift (MIT
//  License, Copyright (c) Ivan Valkou and Trio contributors).
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

/// A single glucose reading, in mg/dL.
public struct GarminGlucoseReading: Equatable {
    public let date: Date
    public let milligramsPerDeciliter: Double

    public init(date: Date, milligramsPerDeciliter: Double) {
        self.date = date
        self.milligramsPerDeciliter = milligramsPerDeciliter
    }
}

/// Everything the builder needs, already reduced to plain values.
public struct GarminWatchStateInputs {
    /// Glucose readings sorted newest-first.
    public var glucose: [GarminGlucoseReading] = []

    /// Nightscout-style direction string from the CGM, with the reading date it
    /// belongs to. Used only when it matches the newest glucose reading;
    /// otherwise the direction is derived from the slope of the readings.
    public var cgmDirection: (direction: String, asOf: Date)?

    /// When the loop last ran (date of the newest dosing decision).
    public var loopDate: Date?

    /// Predicted glucose readings (future-dated), ascending in time. Sampling
    /// interval is whatever the sender chose; consumers use the timestamps.
    public var predicted: [GarminGlucoseReading] = []

    public var insulinOnBoard: Double?
    public var carbsOnBoardGrams: Double?
    public var eventualBGMilligramsPerDeciliter: Double?
    public var basalRateUnitsPerHour: Double?
    public var insulinSensitivityMgdlPerUnit: Double?

    /// "mgdl" or "mmol"
    public var unitsHint: String = "mgdl"

    public var primaryAttribute: GarminPrimaryAttribute = .cob
    public var secondaryAttribute: GarminSecondaryAttribute = .eventualBG

    /// Number of glucose entries to include (first full entry + history).
    /// The SwissAlpine apps graph up to 24 readings; extras are harmless for
    /// the Trio datafield.
    public var historyLimit: Int = 24

    public init() {}
}

/// Sentinel age (in seconds) reported as the loop timestamp when no recent loop
/// run is known, so the watch app renders "stale loop" rather than "no data".
/// Matches Trio (watch apps treat 31+ minutes as stale).
private let staleLoopSentinelAge: TimeInterval = 31 * 60

public func makeGarminWatchStates(from inputs: GarminWatchStateInputs, now: Date = Date()) -> [GarminWatchState] {
    guard !inputs.glucose.isEmpty else {
        return []
    }

    let loopDate = inputs.loopDate ?? now.addingTimeInterval(-staleLoopSentinelAge)
    let readings = Array(inputs.glucose.prefix(max(inputs.historyLimit, 1)))

    var states: [GarminWatchState] = []

    for (index, reading) in readings.enumerated() {
        var state = GarminWatchState()
        state.sgv = clampedInt16(reading.milligramsPerDeciliter)

        if index == 0 {
            state.date = milliseconds(reading: loopDate)
            state.glucoseDate = milliseconds(reading: reading.date)
            state.direction = direction(for: readings, cgmDirection: inputs.cgmDirection)

            if readings.count > 1 {
                state.delta = clampedInt16(readings[0].milligramsPerDeciliter - readings[1].milligramsPerDeciliter)
            } else {
                state.delta = 0
            }

            state.units_hint = inputs.unitsHint
            state.iob = inputs.insulinOnBoard.map(formattedIOB)
            state.cob = inputs.carbsOnBoardGrams
            state.tbr = inputs.basalRateUnitsPerHour
            state.eventualBG = inputs.eventualBGMilligramsPerDeciliter.map(clampedInt16)
            state.isf = inputs.insulinSensitivityMgdlPerUnit.map(clampedInt16)
            state.displayPrimaryAttributeChoice = inputs.primaryAttribute.rawValue
            state.displaySecondaryAttributeChoice = inputs.secondaryAttribute.rawValue
            if !inputs.predicted.isEmpty {
                state.predicted = inputs.predicted.map { reading in
                    [milliseconds(reading: reading.date), UInt64(reading.milligramsPerDeciliter.rounded().clamped(to: 0...1000))]
                }
            }
        } else {
            state.date = milliseconds(reading: reading.date)
        }

        states.append(state)
    }

    return states
}

private func milliseconds(reading date: Date) -> UInt64 {
    UInt64(max(date.timeIntervalSince1970, 0) * 1000)
}

private func clampedInt16(_ value: Double) -> Int16 {
    Int16(value.rounded().clamped(to: Double(Int16.min)...Double(Int16.max)))
}

/// IOB formatted the way Trio sends it: one decimal place, with a minimum
/// magnitude of 0.1 so small non-zero values don't display as zero.
private func formattedIOB(_ value: Double) -> Double {
    if value.magnitude < 0.1, value != 0 {
        return value > 0 ? 0.1 : -0.1
    }
    return (value * 10).rounded() / 10
}

/// Prefers the CGM-reported direction when it belongs to the newest reading;
/// otherwise derives a Nightscout-style direction from the recent slope.
private func direction(for readings: [GarminGlucoseReading], cgmDirection: (direction: String, asOf: Date)?) -> String {
    if let cgmDirection = cgmDirection,
       let newest = readings.first,
       abs(cgmDirection.asOf.timeIntervalSince(newest.date)) < 60 {
        return cgmDirection.direction
    }
    return slopeDirection(for: readings)
}

private func slopeDirection(for readings: [GarminGlucoseReading]) -> String {
    guard readings.count >= 2 else {
        return "--"
    }
    let newest = readings[0]
    let previous = readings[1]
    let minutes = newest.date.timeIntervalSince(previous.date) / 60
    guard minutes > 0.5, minutes < 20 else {
        return "--"
    }
    let mgdlPerMinute = (newest.milligramsPerDeciliter - previous.milligramsPerDeciliter) / minutes

    switch mgdlPerMinute {
    case ..<(-3): return "DoubleDown"
    case ..<(-2): return "SingleDown"
    case ..<(-1): return "FortyFiveDown"
    case ...1: return "Flat"
    case ...2: return "FortyFiveUp"
    case ...3: return "SingleUp"
    default: return "DoubleUp"
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
