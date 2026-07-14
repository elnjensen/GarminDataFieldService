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

public protocol GarminDeviceSessionDelegate: AnyObject {
    /// The user finished picking devices in Garmin Connect Mobile.
    func session(_ session: GarminDeviceSession, didSelectDevices devices: [GarminDeviceDescriptor])

    /// A registered device's connection status changed (called on main).
    func sessionDeviceStatusDidChange(_ session: GarminDeviceSession)

    /// The watch app asked for a data refresh, or a device just became ready.
    func sessionWantsDataUpdate(_ session: GarminDeviceSession)

    /// Garmin Connect Mobile is not installed on this phone.
    func sessionNeedsGarminConnectMobile(_ session: GarminDeviceSession)
}

public final class GarminDeviceSession: NSObject {

    /// Posted by the (patched) Loop app when it receives a URL it does not
    /// handle itself, carrying the URL as the notification object. This is how
    /// the Garmin Connect Mobile device-selection response reaches the plugin.
    public static let didReceiveURLNotification = Notification.Name("org.loopkit.Loop.didReceiveURL")

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
        ConnectIQ.sharedInstance().showDeviceSelection()
    }

    @objc private func handleURLNotification(_ notification: Notification) {
        guard let url = notification.object as? URL else { return }
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
    }

    public func status(for deviceUUID: UUID) -> IQDeviceStatus? {
        deviceStatuses[deviceUUID]
    }

    public func isReady(_ deviceUUID: UUID) -> Bool {
        readyDevices.contains(deviceUUID)
    }

    // MARK: - Sending

    /// Queues the states for delivery to all registered watch apps, debounced
    /// by two seconds and skipped when the payload hasn't changed.
    public func send(states: [GarminWatchState]) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !states.isEmpty, !watchApps.isEmpty else { return }

        lastStates = states

        pendingSend?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.broadcast()
        }
        pendingSend = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
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

    private func broadcast() {
        guard !lastStates.isEmpty else { return }

        let messageObject: Any
        do {
            messageObject = try lastStates.connectIQMessageObject()
        } catch {
            log.error("Failed to encode watch states: \(error.localizedDescription, privacy: .public)")
            return
        }

        let currentHash = lastStates.hashValue
        if currentHash == lastSentHash {
            log.info("Skipping send - payload unchanged")
            return
        }

        for app in watchApps {
            guard let device = app.device else { continue }
            guard readyDevices.contains(device.uuid) else {
                log.info("Skipping \(device.friendlyName ?? "device", privacy: .public) - device not ready")
                continue
            }
            ConnectIQ.sharedInstance().getAppStatus(app) { [weak self] status in
                guard status?.isInstalled == true else {
                    self?.log.info("Watch app not installed on \(device.friendlyName ?? "device", privacy: .public)")
                    return
                }
                self?.sendMessage(messageObject, to: app)
            }
        }

        lastSentHash = currentHash
    }

    private func sendMessage(_ message: Any, to app: IQApp, isRetry: Bool = false) {
        ConnectIQ.sharedInstance().sendMessage(message, to: app, progress: nil) { [weak self] result in
            guard let self = self else { return }
            if result == .success {
                self.log.info("Sent watch state to \(app.device?.friendlyName ?? "device", privacy: .public)")
            } else if isRetry {
                self.log.error("Send failed after retry: \(NSStringFromSendMessageResult(result), privacy: .public)")
            } else {
                self.log.error("Send failed (\(NSStringFromSendMessageResult(result), privacy: .public)) - retrying in 2s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.sendMessage(message, to: app, isRetry: true)
                }
            }
        }
    }
}

// MARK: - IQDeviceEventDelegate

extension GarminDeviceSession: IQDeviceEventDelegate {
    public func deviceStatusChanged(_ device: IQDevice, status: IQDeviceStatus) {
        deviceStatuses[device.uuid] = status
        if status != .connected {
            readyDevices.remove(device.uuid)
        }
        log.info("Device \(device.friendlyName ?? "?", privacy: .public) status: \(status.rawValue)")
        DispatchQueue.main.async {
            self.delegate?.sessionDeviceStatusDidChange(self)
        }
    }

    /// SDK 1.8+: the device is only usable once characteristics are discovered.
    public func deviceCharacteristicsDiscovered(_ device: IQDevice) {
        log.info("Device \(device.friendlyName ?? "?", privacy: .public) ready for communication")
        readyDevices.insert(device.uuid)
        DispatchQueue.main.async {
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
