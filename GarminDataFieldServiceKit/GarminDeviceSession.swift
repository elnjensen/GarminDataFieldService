//
//  GarminDeviceSession.swift
//  GarminDataFieldServiceKit
//
//  Wraps the Garmin ConnectIQ mobile SDK: device selection via Garmin Connect
//  Mobile, device/app registration, readiness tracking (SDK 1.8+ requires
//  characteristic discovery before sending), and message delivery with
//  deduplication, debouncing, and a single retry.
//
//  The registration and send discipline (SDK 1.8 readiness gating, dedupe,
//  retry, watch-initiated refresh) is adapted from Trio's GarminManager.swift
//  (MIT License, Copyright (c) Ivan Valkou and Trio contributors).
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import ConnectIQ
import os

/// A Garmin device the user selected, in a form that can be persisted.
public struct GarminDeviceDescriptor: Equatable, Codable {
    public let uuid: UUID
    public let friendlyName: String
    public let modelName: String

    public init(uuid: UUID, friendlyName: String, modelName: String) {
        self.uuid = uuid
        self.friendlyName = friendlyName
        self.modelName = modelName
    }

    init(device: IQDevice) {
        self.uuid = device.uuid
        self.friendlyName = device.friendlyName ?? ""
        self.modelName = device.modelName ?? ""
    }

    var iqDevice: IQDevice {
        IQDevice(id: uuid, modelName: modelName, friendlyName: friendlyName)
    }

    public var rawValue: [String: Any] {
        [
            "uuid": uuid.uuidString,
            "friendlyName": friendlyName,
            "modelName": modelName,
        ]
    }

    public init?(rawValue: [String: Any]) {
        guard let uuidString = rawValue["uuid"] as? String,
              let uuid = UUID(uuidString: uuidString) else {
            return nil
        }
        self.uuid = uuid
        self.friendlyName = rawValue["friendlyName"] as? String ?? ""
        self.modelName = rawValue["modelName"] as? String ?? ""
    }
}

/// Result of a send attempt, reported as a reason code so the UI owns the
/// user-facing wording. Cases carrying a `String` carry a device friendly name
/// or an SDK result description.
public enum GarminSendStatus: Equatable {
    case sending
    case sent(Date)
    case noData
    case noDevice
    case deviceNotReady(String)
    case appNotInstalled(String)
    case unchanged
    case failed(String)
    case timedOut
}

public protocol GarminDeviceSessionDelegate: AnyObject {
    /// The user finished picking devices in Garmin Connect Mobile.
    func session(_ session: GarminDeviceSession, didSelectDevices devices: [GarminDeviceDescriptor])

    /// A registered device's connection status changed (called on main).
    func sessionDeviceStatusDidChange(_ session: GarminDeviceSession)

    /// The watch app asked for a data refresh, or a device just became ready.
    func sessionWantsDataUpdate(_ session: GarminDeviceSession)

    /// Garmin Connect Mobile is not installed on this phone.
    func sessionNeedsGarminConnectMobile(_ session: GarminDeviceSession)

    /// `manualSendStatus` or `lastSuccessfulSend` changed (called on main).
    func sessionDidUpdateSendStatus(_ session: GarminDeviceSession)
}

public final class GarminDeviceSession: NSObject {

    /// Posted by the (patched) Loop app when it receives a URL it does not
    /// handle itself, carrying the URL in `userInfo` under `urlUserInfoKey`.
    /// This is how the Garmin Connect Mobile device-selection response reaches
    /// the plugin.
    public static let didReceiveURLNotification = Notification.Name("org.loopkit.Loop.didReceiveURL")

    /// `userInfo` key carrying the forwarded `URL`.
    public static let urlUserInfoKey = "url"

    /// The host of the device-selection response URL that Garmin Connect Mobile
    /// opens (`IQDeviceSelectionResponse.urlHost` in the ConnectIQ SDK).
    private static let deviceSelectionResponseHost = "device-select-resp"

    /// How long after the user starts a selection we will accept a response.
    private static let deviceSelectionTimeout: TimeInterval = 5 * 60

    public weak var delegate: GarminDeviceSessionDelegate?

    /// Devices we are registered with, keyed by device UUID.
    private var devices: [UUID: IQDevice] = [:]

    /// Latest known status per registered device.
    private var deviceStatuses: [UUID: IQDeviceStatus] = [:]

    /// Devices that completed BLE characteristic discovery (SDK 1.8+: sending
    /// before this may fail even when the status is `.connected`).
    private var readyDevices: Set<UUID> = []

    /// The watch apps (one per device) we send messages to.
    private var watchApps: [IQApp] = []

    private var lastSentHash: Int?
    private var lastStates: [GarminWatchState] = []
    private var pendingSend: DispatchWorkItem?

    /// When the user-initiated device selection stops accepting a response. Any
    /// app on the device can open Loop's URL scheme, so a selection response is
    /// only honored while the user has one outstanding.
    private var deviceSelectionDeadline: Date?

    /// Outcome of the most recent send the user asked for by tapping the resend
    /// button. Automatic sends do not touch this, so it stays meaningful.
    public private(set) var manualSendStatus: GarminSendStatus?

    /// When a payload was last delivered to any device, automatic or manual.
    public private(set) var lastSuccessfulSend: Date?

    /// Distinguishes successive manual sends so a stale watchdog cannot fail a
    /// newer attempt.
    private var manualSendGeneration = 0

    private static let manualSendTimeout: TimeInterval = 30

    private let log = Logger(subsystem: "GarminDataFieldService", category: "GarminDeviceSession")

    private static var didInitializeConnectIQ = false

    public override init() {
        super.init()
        Self.initializeConnectIQIfNeeded()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleURLNotification(_:)),
            name: Self.didReceiveURLNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The ConnectIQ SDK must be initialized exactly once per process, with the
    /// host app's URL scheme so Garmin Connect Mobile can return control to it.
    private static func initializeConnectIQIfNeeded() {
        guard !didInitializeConnectIQ else { return }
        didInitializeConnectIQ = true
        ConnectIQ.sharedInstance().initialize(withUrlScheme: hostURLScheme, uiOverrideDelegate: nil)
    }

    /// The host app's primary URL scheme, read from its Info.plist so renamed
    /// Loop builds (e.g. side-by-side installs) keep working.
    private static var hostURLScheme: String {
        if let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] {
            for urlType in urlTypes {
                if let schemes = urlType["CFBundleURLSchemes"] as? [String], let scheme = schemes.first {
                    return scheme
                }
            }
        }
        return "Loop"
    }

    // MARK: - Device selection

    /// Opens Garmin Connect Mobile so the user can pick devices. The response
    /// arrives via `didReceiveURLNotification` from the patched host app.
    public func showDeviceSelection() {
        deviceSelectionDeadline = Date().addingTimeInterval(Self.deviceSelectionTimeout)
        ConnectIQ.sharedInstance().showDeviceSelection()
    }

    @objc private func handleURLNotification(_ notification: Notification) {
        // Tolerate hosts that pass the URL as the notification object rather
        // than in userInfo.
        let url = notification.userInfo?[Self.urlUserInfoKey] as? URL ?? notification.object as? URL
        guard let url else { return }

        guard url.host == Self.deviceSelectionResponseHost else { return }

        // The ConnectIQ SDK only checks a source-bundle string carried in the
        // URL's own query, which any sender can set, so it cannot tell a real
        // response from a forged one. Require that the user actually asked.
        guard let deadline = deviceSelectionDeadline, deadline > Date() else {
            log.error("Ignoring unsolicited Garmin device-selection response")
            return
        }
        deviceSelectionDeadline = nil

        guard let parsed = ConnectIQ.sharedInstance().parseDeviceSelectionResponse(from: url) as? [IQDevice] else {
            return
        }
        log.info("Garmin Connect returned \(parsed.count) device(s)")
        let descriptors = parsed.map { GarminDeviceDescriptor(device: $0) }
        DispatchQueue.main.async {
            self.delegate?.session(self, didSelectDevices: descriptors)
        }
    }

    // MARK: - Registration

    /// Registers the given devices for status events and registers the watch
    /// app on each of them for messages. Replaces any prior registration.
    public func configure(devices descriptors: [GarminDeviceDescriptor], appUUID: UUID?) {
        dispatchPrecondition(condition: .onQueue(.main))

        ConnectIQ.sharedInstance().unregister(forAllAppMessages: self)
        for device in devices.values {
            ConnectIQ.sharedInstance().unregister(forDeviceEvents: device, delegate: self)
        }
        devices.removeAll()
        deviceStatuses.removeAll()
        watchApps.removeAll()

        // Force the next send through so freshly registered apps get data even
        // if the payload is unchanged.
        lastSentHash = nil

        // Note: readyDevices is intentionally preserved; readiness reflects the
        // BLE connection, which re-registration does not affect.

        for descriptor in descriptors {
            let device = descriptor.iqDevice
            devices[descriptor.uuid] = device
            ConnectIQ.sharedInstance().register(forDeviceEvents: device, delegate: self)

            if let appUUID = appUUID, let app = IQApp(uuid: appUUID, store: UUID(), device: device) {
                watchApps.append(app)
                ConnectIQ.sharedInstance().register(forAppMessages: app, delegate: self)
            }
        }

        // `deviceStatusChanged` only fires on a *change*, so without seeding
        // there is no status at all until the SDK happens to report one - which
        // showed in the UI as "Unknown" for the first seconds after pairing, and
        // indefinitely for a device that was already connected at registration.
        refreshDeviceStatuses()
    }

    /// Pulls the current status of every registered device. Cheap and one-shot:
    /// call it after registering and when the settings screen appears, rather
    /// than polling.
    public func refreshDeviceStatuses() {
        dispatchPrecondition(condition: .onQueue(.main))

        var changed = false
        for (uuid, device) in devices {
            let status = ConnectIQ.sharedInstance().getDeviceStatus(device)

            // A freshly registered device can briefly report invalidDevice;
            // showing that would be worse than showing nothing, and a genuinely
            // invalid device still arrives via `deviceStatusChanged`.
            guard status != .invalidDevice else { continue }

            if deviceStatuses[uuid] != status {
                deviceStatuses[uuid] = status
                changed = true
            }
        }

        if changed {
            delegate?.sessionDeviceStatusDidChange(self)
        }
    }

    public func status(for deviceUUID: UUID) -> IQDeviceStatus? {
        deviceStatuses[deviceUUID]
    }

    public func isReady(_ deviceUUID: UUID) -> Bool {
        readyDevices.contains(deviceUUID)
    }

    // MARK: - Sending

    /// Queues the states for delivery to all registered watch apps, skipping
    /// sends whose payload hasn't changed.
    ///
    /// Automatic sends are debounced by two seconds, because Loop calls several
    /// upload methods in quick succession each cycle and each one lands here;
    /// without the delay one logical update would produce several Bluetooth
    /// messages, most of them immediately superseded. A `manual` send has
    /// nothing to coalesce with, so it goes out at once and reports its outcome
    /// through `manualSendStatus`.
    public func send(states: [GarminWatchState], manual: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))

        guard !states.isEmpty else {
            if manual { setManualStatus(.noData) }
            return
        }
        guard !watchApps.isEmpty else {
            if manual { setManualStatus(.noDevice) }
            return
        }

        lastStates = states

        pendingSend?.cancel()

        guard !manual else {
            manualSendGeneration += 1
            let generation = manualSendGeneration
            setManualStatus(.sending)

            // ConnectIQ's callbacks are not guaranteed to arrive - a dropped BLE
            // link mid-transfer can strand us - so never leave the UI showing
            // "Sending…" (and the button disabled) indefinitely.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.manualSendTimeout) { [weak self] in
                guard let self = self, self.manualSendGeneration == generation,
                      self.manualSendStatus == .sending else { return }
                self.log.error("Manual send timed out")
                self.setManualStatus(.timedOut)
            }

            broadcast(manual: true)
            return
        }

        let work = DispatchWorkItem { [weak self] in
            self?.broadcast(manual: false)
        }
        pendingSend = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Safe to call from any queue: ConnectIQ's completion blocks are not
    /// guaranteed to run on main, and both stored properties are read by the UI.
    private func setManualStatus(_ status: GarminSendStatus?) {
        onMain {
            self.manualSendStatus = status
            self.delegate?.sessionDidUpdateSendStatus(self)
        }
    }

    private func noteSuccessfulSend(at date: Date) {
        onMain {
            self.lastSuccessfulSend = date
            self.delegate?.sessionDidUpdateSendStatus(self)
        }
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    /// Forgets the last-sent payload so the next send goes through even when
    /// the data is unchanged (used by the manual resend button).
    public func invalidateLastSentPayload() {
        dispatchPrecondition(condition: .onQueue(.main))
        lastSentHash = nil
    }

    /// Re-sends the last payload even if unchanged (used when a device becomes
    /// ready or the watch app explicitly asks for data).
    public func resendLastStates() {
        dispatchPrecondition(condition: .onQueue(.main))
        lastSentHash = nil
        send(states: lastStates)
    }

    /// When `manual`, the outcome is reported through `manualSendStatus`. With
    /// several devices registered the last one to report wins; the log carries
    /// the per-device detail.
    private func broadcast(manual: Bool) {
        guard !lastStates.isEmpty else {
            if manual { setManualStatus(.noData) }
            return
        }

        let messageObject: Any
        do {
            messageObject = try lastStates.connectIQMessageObject()
        } catch {
            log.error("Failed to encode watch states: \(error.localizedDescription, privacy: .public)")
            if manual { setManualStatus(.failed(error.localizedDescription)) }
            return
        }

        let currentHash = lastStates.hashValue
        if currentHash == lastSentHash {
            log.info("Skipping send - payload unchanged")
            if manual { setManualStatus(.unchanged) }
            return
        }

        var attempted = false
        for app in watchApps {
            guard let device = app.device else { continue }
            let name = device.friendlyName ?? ""
            guard readyDevices.contains(device.uuid) else {
                log.info("Skipping \(device.friendlyName ?? "device", privacy: .public) - device not ready")
                if manual { setManualStatus(.deviceNotReady(name)) }
                continue
            }
            attempted = true
            ConnectIQ.sharedInstance().getAppStatus(app) { [weak self] status in
                guard status?.isInstalled == true else {
                    self?.log.info("Watch app not installed on \(device.friendlyName ?? "device", privacy: .public)")
                    if manual { self?.setManualStatus(.appNotInstalled(name)) }
                    return
                }
                self?.sendMessage(messageObject, to: app, manual: manual)
            }
        }

        // Nothing was attempted and no per-device reason was recorded (e.g. an
        // app with no device), so nothing will ever report back.
        if manual && !attempted && manualSendStatus == .sending {
            setManualStatus(.noDevice)
        }

        lastSentHash = currentHash
    }

    private func sendMessage(_ message: Any, to app: IQApp, manual: Bool, isRetry: Bool = false) {
        ConnectIQ.sharedInstance().sendMessage(message, to: app, progress: nil) { [weak self] result in
            guard let self = self else { return }
            if result == .success {
                self.log.info("Sent watch state to \(app.device?.friendlyName ?? "device", privacy: .public)")
                let now = Date()
                self.noteSuccessfulSend(at: now)
                if manual { self.setManualStatus(.sent(now)) }
            } else if isRetry {
                self.log.error("Send failed after retry: \(NSStringFromSendMessageResult(result), privacy: .public)")
                if manual { self.setManualStatus(.failed(NSStringFromSendMessageResult(result))) }
            } else {
                self.log.error("Send failed (\(NSStringFromSendMessageResult(result), privacy: .public)) - retrying in 2s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.sendMessage(message, to: app, manual: manual, isRetry: true)
                }
            }
        }
    }
}

// MARK: - IQDeviceEventDelegate

extension GarminDeviceSession: IQDeviceEventDelegate {
    public func deviceStatusChanged(_ device: IQDevice, status: IQDeviceStatus) {
        log.info("Device \(device.friendlyName ?? "?", privacy: .public) status: \(status.rawValue)")
        // The SDK delivers this off the main thread, but `deviceStatuses` and
        // `readyDevices` are read on main (`status(for:)`, `isReady(_:)`, and
        // the send loop). Mutate them there too rather than racing the readers.
        DispatchQueue.main.async {
            self.deviceStatuses[device.uuid] = status
            if status != .connected {
                self.readyDevices.remove(device.uuid)
            }
            self.delegate?.sessionDeviceStatusDidChange(self)
        }
    }

    /// SDK 1.8+: the device is only usable once characteristics are discovered.
    public func deviceCharacteristicsDiscovered(_ device: IQDevice) {
        log.info("Device \(device.friendlyName ?? "?", privacy: .public) ready for communication")
        // Mutate on main alongside the readers; see `deviceStatusChanged`.
        DispatchQueue.main.async {
            self.readyDevices.insert(device.uuid)
            self.delegate?.sessionDeviceStatusDidChange(self)
            self.delegate?.sessionWantsDataUpdate(self)
        }
    }
}

// MARK: - IQAppMessageDelegate

extension GarminDeviceSession: IQAppMessageDelegate {
    public func receivedMessage(_ message: Any, from app: IQApp) {
        // The Trio/SwissAlpine watch apps send "status" to request fresh data
        // (e.g. after the datafield starts mid-activity).
        guard let request = message as? String, request == "status" else {
            return
        }
        log.info("Watch app requested a data update")
        DispatchQueue.main.async {
            self.lastSentHash = nil
            self.delegate?.sessionWantsDataUpdate(self)
        }
    }
}
