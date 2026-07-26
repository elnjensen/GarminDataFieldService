//
//  GarminDataFieldService.swift
//  GarminDataFieldServiceKit
//
//  A Loop service that forwards glucose, IOB, COB, and related loop data over
//  Bluetooth to a Garmin Connect IQ datafield (the published Trio/SwissAlpine
//  apps, or a custom app speaking the same format).
//
//  The primary data source is `uploadDosingDecisionData`, which Loop calls on
//  every loop cycle regardless of the CGM "Upload Readings" setting and whose
//  payload carries glucose history, IOB, COB, and predicted glucose in one
//  object. `uploadGlucoseData` (only delivered when "Upload Readings" is on)
//  is used opportunistically for snappier glucose updates and CGM trend
//  arrows, but is never required.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit
import os

public final class GarminDataFieldService: Service {

    public static let pluginIdentifier = "GarminDataFieldService"

    public static let localizedTitle = LocalizedString("Garmin Datafield", comment: "The title of the Garmin datafield service")

    public weak var serviceDelegate: ServiceDelegate?

    public weak var stateDelegate: StatefulPluggableDelegate?

    public var isOnboarded: Bool

    public let session = GarminDeviceSession()

    // MARK: - User configuration (persisted)

    /// Master switch: when off, the session is unregistered from ConnectIQ and
    /// nothing is sent. Loop data still refreshes the in-memory caches, so
    /// re-enabling pushes current data promptly instead of waiting for the
    /// next loop cycle. Unlike 24/7 uploaders (Nightscout etc.), this service
    /// is typically wanted only during an activity.
    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            configureSessionIfNeeded()
            if isEnabled {
                sendWatchStateFromCaches()
            }
        }
    }

    public var watchAppChoice: GarminWatchAppChoice {
        didSet { configureSessionIfNeeded() }
    }

    /// Used when `watchAppChoice == .custom`.
    public var customAppUUID: UUID? {
        didSet { configureSessionIfNeeded() }
    }

    public var primaryAttribute: GarminPrimaryAttribute

    public var secondaryAttribute: GarminSecondaryAttribute

    public private(set) var devices: [GarminDeviceDescriptor] {
        didSet { configureSessionIfNeeded() }
    }

    // MARK: - Cached therapy state (persisted; settings uploads are infrequent)

    private var unitsHint: String

    private var basalRateSchedule: BasalRateSchedule?

    private var insulinSensitivitySchedule: InsulinSensitivitySchedule?

    // MARK: - Cached loop state (transient; refreshed within minutes)

    private var glucoseReadings: [GarminGlucoseReading] = []

    private var cgmDirection: (direction: String, asOf: Date)?

    private var loopDate: Date?

    private var insulinOnBoard: Double?

    private var carbsOnBoardGrams: Double?

    private var eventualBGMilligramsPerDeciliter: Double?

    /// Downsampled predicted glucose from the latest dosing decision,
    /// ascending, future-dated relative to the decision.
    private var predictedReadings: [GarminGlucoseReading] = []

    /// The most recent temp basal seen in dose data, used while it is active.
    private var activeTempBasal: (rate: Double, endDate: Date)?

    /// Serializes access to the caches above (upload callbacks arrive on
    /// arbitrary queues).
    private let stateQueue = DispatchQueue(label: "GarminDataFieldService.state")

    private let log = Logger(subsystem: "GarminDataFieldService", category: "GarminDataFieldService")

    /// Loop status (dosing decisions, temp basals) older than this is ignored
    /// entirely (protects against the historical backfill Loop performs when
    /// a service is first added).
    private static let maximumDataAge: TimeInterval = 30 * 60

    /// Glucose readings are kept much longer than loop status: they feed the
    /// graph datafield's history window.
    private static let maximumGlucoseAge: TimeInterval = 4 * 60 * 60

    /// 48 five-minute readings ≈ 4 hours — enough to fill the graph
    /// datafield's 3-hour window; extra entries are harmless to the
    /// text-only datafields, which read only the first array element.
    private static let glucoseHistoryLimit = 48

    public init() {
        self.isOnboarded = true
        self.isEnabled = true
        self.watchAppChoice = .trioDatafield
        self.customAppUUID = nil
        self.primaryAttribute = .cob
        self.secondaryAttribute = .eventualBG
        self.devices = []
        self.unitsHint = "mgdl"
        session.delegate = self
    }

    public required init?(rawState: RawStateValue) {
        self.isOnboarded = rawState["isOnboarded"] as? Bool ?? true
        self.isEnabled = rawState["isEnabled"] as? Bool ?? true
        self.watchAppChoice = (rawState["watchAppChoice"] as? String).flatMap(GarminWatchAppChoice.init(rawValue:)) ?? .trioDatafield
        self.customAppUUID = (rawState["customAppUUID"] as? String).flatMap(UUID.init(uuidString:))
        self.primaryAttribute = (rawState["primaryAttribute"] as? String).flatMap(GarminPrimaryAttribute.init(rawValue:)) ?? .cob
        self.secondaryAttribute = (rawState["secondaryAttribute"] as? String).flatMap(GarminSecondaryAttribute.init(rawValue:)) ?? .eventualBG
        self.devices = (rawState["devices"] as? [[String: Any]])?.compactMap(GarminDeviceDescriptor.init(rawValue:)) ?? []
        self.unitsHint = rawState["unitsHint"] as? String ?? "mgdl"
        self.basalRateSchedule = (rawState["basalRateSchedule"] as? BasalRateSchedule.RawValue).flatMap(BasalRateSchedule.init(rawValue:))
        self.insulinSensitivitySchedule = (rawState["insulinSensitivitySchedule"] as? InsulinSensitivitySchedule.RawValue).flatMap(InsulinSensitivitySchedule.init(rawValue:))
        session.delegate = self
        DispatchQueue.main.async {
            self.configureSessionIfNeeded()
        }
    }

    public var rawState: RawStateValue {
        var rawState: RawStateValue = [
            "isOnboarded": isOnboarded,
            "isEnabled": isEnabled,
            "watchAppChoice": watchAppChoice.rawValue,
            "primaryAttribute": primaryAttribute.rawValue,
            "secondaryAttribute": secondaryAttribute.rawValue,
            "devices": devices.map { $0.rawValue },
            "unitsHint": unitsHint,
        ]
        rawState["customAppUUID"] = customAppUUID?.uuidString
        rawState["basalRateSchedule"] = basalRateSchedule?.rawValue
        rawState["insulinSensitivitySchedule"] = insulinSensitivitySchedule?.rawValue
        return rawState
    }

    public func completeCreate() {
        log.info("completeCreate")
    }

    public func completeUpdate() {
        log.info("completeUpdate")
        stateDelegate?.pluginDidUpdateState(self)
        sendWatchStateFromCaches()
    }

    public func completeDelete() {
        log.info("completeDelete")
        stateDelegate?.pluginWantsDeletion(self)
    }

    // MARK: - Device management (called from the settings UI)

    public var effectiveAppUUID: UUID? {
        watchAppChoice == .custom ? customAppUUID : watchAppChoice.appUUID
    }

    public func replaceDevices(with descriptors: [GarminDeviceDescriptor]) {
        devices = descriptors
    }

    public func removeDevice(withUUID uuid: UUID) {
        devices.removeAll { $0.uuid == uuid }
    }

    private func configureSessionIfNeeded() {
        let descriptors = isEnabled ? devices : []
        let appUUID = effectiveAppUUID
        DispatchQueue.main.async {
            self.session.configure(devices: descriptors, appUUID: appUUID)
        }
    }

    // MARK: - Building & sending

    /// Rebuilds and sends the watch state even if the payload is unchanged
    /// since the last send (the automatic paths skip identical payloads).
    /// Used by the settings UI's "Resend Latest Data" button.
    public func forceSendWatchState() {
        DispatchQueue.main.async {
            self.session.invalidateLastSentPayload()
        }
        sendWatchStateFromCaches(manual: true)
    }

    /// Assembles the current watch state from the caches and hands it to the
    /// session. Safe to call from any queue. No-op while the service is
    /// switched off.
    ///
    /// A `manual` send skips the debounce and reports its outcome through the
    /// session's `manualSendStatus`, including the empty-payload case - hence no
    /// early return here on empty states.
    public func sendWatchStateFromCaches(manual: Bool = false) {
        guard isEnabled else { return }
        stateQueue.async {
            let inputs = self.makeInputsLocked()
            DispatchQueue.main.async {
                let states = makeGarminWatchStates(from: inputs)
                self.session.send(states: states, manual: manual)
            }
        }
    }

    /// Must be called on `stateQueue`.
    private func makeInputsLocked() -> GarminWatchStateInputs {
        let now = Date()
        var inputs = GarminWatchStateInputs()
        inputs.glucose = glucoseReadings.filter { now.timeIntervalSince($0.date) <= Self.maximumGlucoseAge }
        inputs.cgmDirection = cgmDirection
        inputs.loopDate = loopDate
        inputs.predicted = predictedReadings.filter { $0.date > now }
        inputs.insulinOnBoard = insulinOnBoard
        inputs.carbsOnBoardGrams = carbsOnBoardGrams
        inputs.eventualBGMilligramsPerDeciliter = eventualBGMilligramsPerDeciliter
        inputs.basalRateUnitsPerHour = currentBasalRateLocked(at: now)
        inputs.insulinSensitivityMgdlPerUnit = currentISFLocked(at: now)
        inputs.unitsHint = unitsHint
        inputs.primaryAttribute = primaryAttribute
        inputs.secondaryAttribute = secondaryAttribute
        inputs.historyLimit = Self.glucoseHistoryLimit
        return inputs
    }

    private func currentBasalRateLocked(at date: Date) -> Double? {
        if let tempBasal = activeTempBasal, tempBasal.endDate > date {
            return tempBasal.rate
        }
        return basalRateSchedule?.value(at: date)
    }

    private func currentISFLocked(at date: Date) -> Double? {
        guard let schedule = insulinSensitivitySchedule else {
            return nil
        }
        let quantity = HKQuantity(unit: schedule.unit, doubleValue: schedule.value(at: date))
        return quantity.doubleValue(for: .milligramsPerDeciliter)
    }

    /// Reduces Loop's ~5-minute prediction curve to ~10-minute steps over the
    /// next 75 minutes — plenty for a one-hour graph pane while keeping the
    /// BLE payload small. The watch uses the timestamps, so the interval is
    /// not a contract.
    private static func downsamplePrediction(_ predicted: [PredictedGlucoseValue]?, after anchor: Date) -> [GarminGlucoseReading] {
        guard let predicted = predicted else {
            return []
        }
        let horizon = anchor.addingTimeInterval(75 * 60)
        var out: [GarminGlucoseReading] = []
        var lastKept: Date?
        for value in predicted {
            guard value.startDate > anchor else { continue }
            guard value.startDate <= horizon else { break }
            if lastKept == nil || value.startDate.timeIntervalSince(lastKept!) >= 9.5 * 60 {
                out.append(GarminGlucoseReading(
                    date: value.startDate,
                    milligramsPerDeciliter: value.quantity.doubleValue(for: .milligramsPerDeciliter)
                ))
                lastKept = value.startDate
            }
        }
        return out
    }

    /// Merges readings into the cache, newest first, deduplicating by date.
    /// Must be called on `stateQueue`.
    private func mergeGlucoseLocked(_ readings: [GarminGlucoseReading]) {
        let now = Date()
        var merged = glucoseReadings
        for reading in readings {
            guard now.timeIntervalSince(reading.date) <= Self.maximumGlucoseAge else { continue }
            if !merged.contains(where: { abs($0.date.timeIntervalSince(reading.date)) < 30 }) {
                merged.append(reading)
            }
        }
        merged.sort { $0.date > $1.date }
        glucoseReadings = Array(merged.prefix(Self.glucoseHistoryLimit))
    }
}

// MARK: - RemoteDataService

extension GarminDataFieldService: RemoteDataService {

    public func remoteNotificationWasReceived(_ notification: [String: AnyObject]) async throws {
        // Not supported.
    }

    /// Primary data path: called on every loop cycle, not gated by any setting.
    public func uploadDosingDecisionData(_ stored: [StoredDosingDecision], completion: @escaping (Result<Bool, Error>) -> Void) {
        defer { completion(.success(true)) }

        guard let decision = stored.max(by: { $0.date < $1.date }),
              Date().timeIntervalSince(decision.date) <= Self.maximumDataAge else {
            return
        }

        stateQueue.async {
            self.loopDate = decision.date
            self.insulinOnBoard = decision.insulinOnBoard?.value
            self.carbsOnBoardGrams = decision.carbsOnBoard?.quantity.doubleValue(for: .gram())
            self.eventualBGMilligramsPerDeciliter = decision.predictedGlucose?.last?.quantity.doubleValue(for: .milligramsPerDeciliter)
            self.predictedReadings = Self.downsamplePrediction(decision.predictedGlucose, after: decision.date)

            if let historicalGlucose = decision.historicalGlucose {
                let readings = historicalGlucose.map {
                    GarminGlucoseReading(date: $0.startDate, milligramsPerDeciliter: $0.quantity.doubleValue(for: .milligramsPerDeciliter))
                }
                self.mergeGlucoseLocked(readings)
            }
            if let manualSample = decision.manualGlucoseSample {
                self.mergeGlucoseLocked([
                    GarminGlucoseReading(date: manualSample.startDate, milligramsPerDeciliter: manualSample.quantity.doubleValue(for: .milligramsPerDeciliter))
                ])
            }
        }

        sendWatchStateFromCaches()
    }

    /// Bonus path: only delivered when the CGM "Upload Readings" setting is on.
    /// Provides fresher glucose and the CGM's own trend arrow.
    public func uploadGlucoseData(_ stored: [StoredGlucoseSample], completion: @escaping (Result<Bool, Error>) -> Void) {
        defer { completion(.success(true)) }

        let now = Date()
        let fresh = stored.filter { now.timeIntervalSince($0.startDate) <= Self.maximumGlucoseAge }
        guard !fresh.isEmpty else {
            return
        }

        stateQueue.async {
            let readings = fresh.map {
                GarminGlucoseReading(date: $0.startDate, milligramsPerDeciliter: $0.quantity.doubleValue(for: .milligramsPerDeciliter))
            }
            self.mergeGlucoseLocked(readings)

            if let newest = fresh.max(by: { $0.startDate < $1.startDate }),
               let trend = newest.trend {
                self.cgmDirection = (direction: trend.nightscoutDirection, asOf: newest.startDate)
            }
        }

        sendWatchStateFromCaches()
    }

    /// Settings change rarely; cache the pieces needed for basal/ISF fallback
    /// and the user's preferred glucose unit, and persist them across restarts.
    public func uploadSettingsData(_ stored: [StoredSettings], completion: @escaping (Result<Bool, Error>) -> Void) {
        defer { completion(.success(true)) }

        guard let settings = stored.max(by: { $0.date < $1.date }) else {
            return
        }

        stateQueue.async {
            if let unit = settings.bloodGlucoseUnit {
                self.unitsHint = unit == .millimolesPerLiter ? "mmol" : "mgdl"
            }
            if let basalRateSchedule = settings.basalRateSchedule {
                self.basalRateSchedule = basalRateSchedule
            }
            if let insulinSensitivitySchedule = settings.insulinSensitivitySchedule {
                self.insulinSensitivitySchedule = insulinSensitivitySchedule
            }
            DispatchQueue.main.async {
                self.stateDelegate?.pluginDidUpdateState(self)
            }
        }

        sendWatchStateFromCaches()
    }

    /// Tracks the currently running temp basal so the watch's TBR slot is
    /// accurate between dosing decisions.
    public func uploadDoseData(created: [DoseEntry], deleted: [DoseEntry], completion: @escaping (Result<Bool, Error>) -> Void) {
        defer { completion(.success(true)) }

        let now = Date()
        let tempBasals = created.filter { $0.type == .tempBasal && now.timeIntervalSince($0.startDate) <= Self.maximumDataAge }
        guard let latest = tempBasals.max(by: { $0.startDate < $1.startDate }) else {
            return
        }

        stateQueue.async {
            self.activeTempBasal = (rate: latest.unitsPerHour, endDate: latest.endDate)
        }
    }

    // MARK: Unused upload methods

    public func uploadAlertData(_ stored: [SyncAlertObject], completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(true))
    }

    public func uploadCarbData(created: [SyncCarbObject], updated: [SyncCarbObject], deleted: [SyncCarbObject], completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(true))
    }

    public func uploadTemporaryOverrideData(updated: [TemporaryScheduleOverride], deleted: [TemporaryScheduleOverride], completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(true))
    }

    public func uploadPumpEventData(_ stored: [PersistedPumpEvent], completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(true))
    }

    public func uploadCgmEventData(_ stored: [PersistedCgmEvent], completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(true))
    }

    public var glucoseDataLimit: Int? { 100 }

    public var dosingDecisionDataLimit: Int? { 50 }
}

// MARK: - GarminDeviceSessionDelegate

extension GarminDataFieldService: GarminDeviceSessionDelegate {

    public func session(_ session: GarminDeviceSession, didSelectDevices devices: [GarminDeviceDescriptor]) {
        replaceDevices(with: devices)
        stateDelegate?.pluginDidUpdateState(self)
        NotificationCenter.default.post(name: Self.devicesDidChangeNotification, object: self)
    }

    public func sessionDeviceStatusDidChange(_ session: GarminDeviceSession) {
        NotificationCenter.default.post(name: Self.devicesDidChangeNotification, object: self)
    }

    public func sessionWantsDataUpdate(_ session: GarminDeviceSession) {
        sendWatchStateFromCaches()
    }

    public func sessionNeedsGarminConnectMobile(_ session: GarminDeviceSession) {
        NotificationCenter.default.post(name: Self.needsGarminConnectMobileNotification, object: self)
    }

    public func sessionDidUpdateSendStatus(_ session: GarminDeviceSession) {
        NotificationCenter.default.post(name: Self.sendStatusDidChangeNotification, object: self)
    }

    /// Posted (object: the service) when the device list or a device status changes.
    public static let devicesDidChangeNotification = Notification.Name("GarminDataFieldService.devicesDidChange")

    /// Posted (object: the service) when Garmin Connect Mobile is missing.
    public static let needsGarminConnectMobileNotification = Notification.Name("GarminDataFieldService.needsGarminConnectMobile")

    /// Posted (object: the service) when a send starts, finishes, or fails.
    public static let sendStatusDidChangeNotification = Notification.Name("GarminDataFieldService.sendStatusDidChange")
}

// MARK: - Trend mapping

extension GlucoseTrend {
    /// The Nightscout-style direction string used by the watch apps.
    var nightscoutDirection: String {
        switch self {
        case .upUpUp: return "DoubleUp"
        case .upUp: return "SingleUp"
        case .up: return "FortyFiveUp"
        case .flat: return "Flat"
        case .down: return "FortyFiveDown"
        case .downDown: return "SingleDown"
        case .downDownDown: return "DoubleDown"
        }
    }
}
