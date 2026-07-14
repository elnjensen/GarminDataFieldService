//
//  GarminWatchState.swift
//  GarminDataFieldServiceKit
//
//  Payload sent to Garmin Connect IQ watch apps. This structure and its JSON
//  encoding are wire-compatible with Trio's `GarminWatchState` (the format
//  consumed by the "Trio Datafield" and "SwissAlpine" apps in the Connect IQ
//  store): a JSON array where the first entry carries all extended fields and
//  any further entries are historical glucose readings.
//
//  Ported from Trio's GarminWatchState.swift (MIT License,
//  Copyright (c) Ivan Valkou and Trio contributors).
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

public struct GarminWatchState: Hashable, Equatable, Encodable {
    /// Timestamp of the loop run (enacted dosing decision) in ms since Unix epoch.
    /// The watch app treats 31+ minutes old as a stale loop.
    public var date: UInt64?

    /// Timestamp of the glucose reading in ms since Unix epoch.
    public var glucoseDate: UInt64?

    /// Sensor glucose value in raw mg/dL (the watch app converts per `units_hint`).
    public var sgv: Int16?

    /// Change in glucose since the previous reading, in mg/dL.
    public var delta: Int16?

    /// Nightscout-style trend direction ("Flat", "FortyFiveUp", "SingleUp", ...).
    public var direction: String?

    /// Signal noise level (unused by Loop; kept for wire compatibility).
    public var noise: Double?

    /// Unit hint for the watch app: "mgdl" or "mmol".
    public var units_hint: String?

    /// Insulin on board in units (first array entry only).
    public var iob: Double?

    /// Current basal rate in U/hr (first array entry only).
    public var tbr: Double?

    /// Carbs on board in grams (first array entry only).
    public var cob: Double?

    /// Predicted eventual blood glucose in mg/dL.
    public var eventualBG: Int16?

    /// Insulin sensitivity factor in mg/dL per unit (first array entry only).
    public var isf: Int16?

    /// AutoISF sensitivity ratio (not available in Loop; always omitted).
    public var sensRatio: Double?

    /// Which primary attribute the watch app should display: "cob", "isf", or "sensRatio".
    public var displayPrimaryAttributeChoice: String?

    /// Which secondary attribute the watch app should display: "tbr" or "eventualBG".
    public var displaySecondaryAttributeChoice: String?

    /// Predicted glucose as [milliseconds-since-epoch, mg/dL] pairs, ascending
    /// in time (first array entry only). This is an extension to the Trio
    /// format; consumers that don't know the key ignore it. The sampling
    /// interval is not guaranteed — consumers must use the timestamps.
    public var predicted: [[UInt64]]?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case date
        case glucoseDate
        case sgv
        case delta
        case direction
        case noise
        case units_hint
        case iob
        case tbr
        case cob
        case eventualBG
        case isf
        case sensRatio
        case displayPrimaryAttributeChoice
        case displaySecondaryAttributeChoice
        case predicted
    }

    /// Sparse encoding: nil values are omitted, and Doubles are rounded to two
    /// decimal places to avoid floating-point artifacts on the watch.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(date, forKey: .date)
        try container.encodeIfPresent(glucoseDate, forKey: .glucoseDate)
        try container.encodeIfPresent(sgv, forKey: .sgv)
        try container.encodeIfPresent(delta, forKey: .delta)
        try container.encodeIfPresent(direction, forKey: .direction)
        try container.encodeIfPresent(noise, forKey: .noise)
        try container.encodeIfPresent(units_hint, forKey: .units_hint)
        try container.encodeIfPresent(iob?.roundedForWire, forKey: .iob)
        try container.encodeIfPresent(tbr?.roundedForWire, forKey: .tbr)
        try container.encodeIfPresent(cob, forKey: .cob)
        try container.encodeIfPresent(eventualBG, forKey: .eventualBG)
        try container.encodeIfPresent(isf, forKey: .isf)
        try container.encodeIfPresent(sensRatio?.roundedForWire, forKey: .sensRatio)
        try container.encodeIfPresent(displayPrimaryAttributeChoice, forKey: .displayPrimaryAttributeChoice)
        try container.encodeIfPresent(displaySecondaryAttributeChoice, forKey: .displaySecondaryAttributeChoice)
        try container.encodeIfPresent(predicted, forKey: .predicted)
    }
}

extension Array where Element == GarminWatchState {
    /// The Foundation object graph (array of dictionaries) that the ConnectIQ SDK
    /// serializes onto the wire, produced via a JSON round trip so the value types
    /// match what the watch apps were built against.
    public func connectIQMessageObject() throws -> Any {
        let data = try JSONEncoder().encode(self)
        return try JSONSerialization.jsonObject(with: data, options: [])
    }
}

private extension Double {
    var roundedForWire: Double {
        (self * 100).rounded() / 100
    }
}
