//
//  GarminDataFieldServiceSettingsView.swift
//  GarminDataFieldServiceKitUI
//
//  Settings UI: pair Garmin devices via Garmin Connect Mobile, choose the
//  Connect IQ app to drive, and pick what its configurable slots display.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import ConnectIQ
import LoopKitUI
import GarminDataFieldServiceKit

class GarminDataFieldServiceViewModel: ObservableObject {
    let service: GarminDataFieldService
    let isCreating: Bool

    @Published var isEnabled: Bool
    @Published var watchAppChoice: GarminWatchAppChoice
    @Published var customAppUUIDText: String
    @Published var primaryAttribute: GarminPrimaryAttribute
    @Published var secondaryAttribute: GarminSecondaryAttribute
    @Published var devices: [GarminDeviceDescriptor]
    @Published var showingGarminConnectAlert = false
    @Published var sendStatus: GarminSendStatus?
    @Published var lastSuccessfulSend: Date?

    var onCompletion: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    init(service: GarminDataFieldService, isCreating: Bool) {
        self.service = service
        self.isCreating = isCreating
        self.isEnabled = service.isEnabled
        self.watchAppChoice = service.watchAppChoice
        self.customAppUUIDText = service.customAppUUID?.uuidString ?? ""
        self.primaryAttribute = service.primaryAttribute
        self.secondaryAttribute = service.secondaryAttribute
        self.devices = service.devices
        self.sendStatus = service.session.manualSendStatus
        self.lastSuccessfulSend = service.session.lastSuccessfulSend

        observers.append(NotificationCenter.default.addObserver(
            forName: GarminDataFieldService.sendStatusDidChangeNotification,
            object: service,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.sendStatus = self.service.session.manualSendStatus
            self.lastSuccessfulSend = self.service.session.lastSuccessfulSend
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: GarminDataFieldService.devicesDidChangeNotification,
            object: service,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.devices = self.service.devices
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: GarminDataFieldService.needsGarminConnectMobileNotification,
            object: service,
            queue: .main
        ) { [weak self] _ in
            self?.showingGarminConnectAlert = true
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    var customAppUUID: UUID? {
        UUID(uuidString: customAppUUIDText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var isConfigurationValid: Bool {
        if watchAppChoice == .custom {
            return customAppUUID != nil
        }
        return true
    }

    func statusDescription(for device: GarminDeviceDescriptor) -> String {
        if service.session.isReady(device.uuid) {
            return LocalizedString("Connected", comment: "Status of a ready Garmin device")
        }
        switch service.session.status(for: device.uuid) {
        case .connected?:
            return LocalizedString("Connecting…", comment: "Status of a Garmin device that is connected but not yet ready")
        case .notConnected?:
            return LocalizedString("Not Connected", comment: "Status of a disconnected Garmin device")
        case .notFound?:
            return LocalizedString("Not Found", comment: "Status of a Garmin device that cannot be found")
        case .bluetoothNotReady?:
            return LocalizedString("Bluetooth Off", comment: "Status of a Garmin device when Bluetooth is unavailable")
        case .invalidDevice?:
            return LocalizedString("Invalid Device", comment: "Status of an invalid Garmin device")
        default:
            return LocalizedString("Unknown", comment: "Status of a Garmin device before any status update")
        }
    }

    func isConnected(_ device: GarminDeviceDescriptor) -> Bool {
        service.session.isReady(device.uuid)
    }

    func connectDevices() {
        service.session.showDeviceSelection()
    }

    /// Applies immediately (rather than waiting for Done): this is the
    /// before-and-after-a-ride switch, so it should take effect on the spot.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        service.isEnabled = enabled
        service.completeUpdate()
    }

    func removeDevices(at offsets: IndexSet) {
        for index in offsets {
            service.removeDevice(withUUID: devices[index].uuid)
        }
        devices = service.devices
        service.completeUpdate()
    }

    func resendData() {
        service.forceSendWatchState()
    }

    func saveAndComplete() {
        service.watchAppChoice = watchAppChoice
        service.customAppUUID = watchAppChoice == .custom ? customAppUUID : nil
        service.primaryAttribute = primaryAttribute
        service.secondaryAttribute = secondaryAttribute
        if isCreating {
            service.completeCreate()
        }
        service.completeUpdate()
        onCompletion?()
    }

    func deleteService() {
        service.completeDelete()
        onCompletion?()
    }
}

struct GarminDataFieldServiceSettingsView: View {
    @ObservedObject var viewModel: GarminDataFieldServiceViewModel

    @State private var showingDeleteConfirmation = false

    var body: some View {
        List {
            enabledSection
            devicesSection
            watchAppSection
            displaySection
            // Loop does not register the service - and so never delivers any
            // data to it - until creation completes, so there is nothing to
            // resend while still setting up.
            if !viewModel.isCreating {
                testSection
                deleteSection
            }
        }
        .insetGroupedListStyle()
        .navigationBarTitle(Text("Garmin Datafield"), displayMode: .large)
        .navigationBarItems(trailing: doneButton)
        .alert(isPresented: $viewModel.showingGarminConnectAlert) {
            Alert(
                title: Text("Garmin Connect Required", comment: "Alert title when Garmin Connect Mobile is not installed"),
                message: Text("Install the Garmin Connect app from the App Store and pair your device with it first.", comment: "Alert message when Garmin Connect Mobile is not installed"),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var enabledSection: some View {
        Section(
            footer: Text("Turn off to stop sending data to your Garmin device, for example between rides. Loop keeps collecting data, so turning it back on updates the device right away.", comment: "Section footer for the enabled toggle")
        ) {
            Toggle(isOn: Binding(
                get: { viewModel.isEnabled },
                set: { viewModel.setEnabled($0) }
            )) {
                Text("Send Data to Garmin", comment: "Label for the enabled toggle")
            }
        }
    }

    private var devicesSection: some View {
        Section(
            header: Text("Devices", comment: "Section header for the Garmin device list"),
            footer: Text("Devices are managed through the Garmin Connect app. Tapping the button opens Garmin Connect, where you confirm which devices to share with Loop.", comment: "Section footer for the Garmin device list")
        ) {
            ForEach(viewModel.devices, id: \.uuid) { device in
                HStack {
                    VStack(alignment: .leading) {
                        Text(device.friendlyName.isEmpty ? device.modelName : device.friendlyName)
                        if !device.modelName.isEmpty && !device.friendlyName.isEmpty {
                            Text(device.modelName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Text(viewModel.statusDescription(for: device))
                        .font(.caption)
                        .foregroundColor(viewModel.isConnected(device) ? .green : .secondary)
                }
            }
            .onDelete { offsets in
                viewModel.removeDevices(at: offsets)
            }

            Button(action: { viewModel.connectDevices() }) {
                Text("Connect Garmin Devices…", comment: "Button title to select devices in Garmin Connect")
            }
        }
    }

    private var watchAppSection: some View {
        Section(
            header: Text("Connect IQ App", comment: "Section header for the Connect IQ app selection"),
            footer: Text("Install the selected datafield on your Garmin device from the Connect IQ store, then add it to a data screen. The Trio Datafield shows glucose with a trend arrow, insulin on board, and a configurable value.", comment: "Section footer for the Connect IQ app selection")
        ) {
            Picker(selection: $viewModel.watchAppChoice, label: Text("Datafield", comment: "Label for the Connect IQ app picker")) {
                ForEach(GarminWatchAppChoice.allCases, id: \.self) { choice in
                    Text(choice.localizedTitle).tag(choice)
                }
            }

            if viewModel.watchAppChoice == .custom {
                TextField(LocalizedString("Connect IQ App UUID", comment: "Placeholder for the custom app UUID field"), text: $viewModel.customAppUUIDText)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .font(.system(.caption, design: .monospaced))
            }
        }
    }

    private var displaySection: some View {
        Section(
            header: Text("Display", comment: "Section header for the display attribute choices"),
            footer: Text("Which values the datafield shows in its configurable slots.", comment: "Section footer for the display attribute choices")
        ) {
            Picker(selection: $viewModel.primaryAttribute, label: Text("Value 1", comment: "Label for the primary attribute picker")) {
                ForEach(GarminPrimaryAttribute.allCases, id: \.self) { choice in
                    Text(choice.localizedTitle).tag(choice)
                }
            }

            Picker(selection: $viewModel.secondaryAttribute, label: Text("Value 2", comment: "Label for the secondary attribute picker")) {
                ForEach(GarminSecondaryAttribute.allCases, id: \.self) { choice in
                    Text(choice.localizedTitle).tag(choice)
                }
            }
        }
    }

    private var testSection: some View {
        Section(footer: Text("Sends the most recent data to the Garmin device again. Data flows automatically with every loop cycle (about every 5 minutes).", comment: "Section footer for the resend button")) {
            Button(action: { viewModel.resendData() }) {
                HStack {
                    Text("Resend Latest Data", comment: "Button title to resend the latest data to the Garmin device")
                    if viewModel.sendStatus == .sending {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(!viewModel.isEnabled || viewModel.sendStatus == .sending)

            if let message = sendStatusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(sendStatusIsError ? .red : .secondary)
            }
        }
    }

    /// Describes the last resend attempt, falling back to when data last
    /// reached the device so the row is informative before the button is used.
    private var sendStatusMessage: String? {
        switch viewModel.sendStatus {
        case .sending:
            return LocalizedString("Sending…", comment: "Send status while a resend is in flight")
        case .sent(let date):
            return String(
                format: LocalizedString("Sent at %@", comment: "Send status after a successful resend (1: time)"),
                Self.timeFormatter.string(from: date)
            )
        case .noData:
            return LocalizedString("No data to send yet. Loop supplies data on its next cycle.", comment: "Send status when no loop data has arrived")
        case .noDevice:
            return LocalizedString("No Garmin device selected.", comment: "Send status when no device is paired")
        case .deviceNotReady(let name):
            return String(
                format: LocalizedString("%@ is not connected yet. Open Garmin Connect and check Bluetooth.", comment: "Send status when the device is not ready (1: device name)"),
                name.isEmpty ? LocalizedString("The device", comment: "Fallback device name") : name
            )
        case .appNotInstalled(let name):
            return String(
                format: LocalizedString("The datafield is not installed on %@.", comment: "Send status when the Connect IQ app is missing (1: device name)"),
                name.isEmpty ? LocalizedString("the device", comment: "Fallback device name, mid-sentence") : name
            )
        case .unchanged:
            return LocalizedString("Data unchanged since the last send.", comment: "Send status when the payload was identical")
        case .failed(let reason):
            return String(
                format: LocalizedString("Send failed: %@", comment: "Send status after a failed send (1: reason)"),
                reason
            )
        case .timedOut:
            return LocalizedString("The device did not respond. Check that it is connected in Garmin Connect.", comment: "Send status when the send timed out")
        case nil:
            guard let last = viewModel.lastSuccessfulSend else { return nil }
            return String(
                format: LocalizedString("Last sent at %@", comment: "Send status showing the last automatic send (1: time)"),
                Self.timeFormatter.string(from: last)
            )
        }
    }

    private var sendStatusIsError: Bool {
        switch viewModel.sendStatus {
        case .failed, .deviceNotReady, .appNotInstalled, .noDevice, .timedOut:
            return true
        default:
            return false
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private var deleteSection: some View {
        Section {
            Button(action: { showingDeleteConfirmation = true }) {
                HStack {
                    Spacer()
                    Text("Delete Service", comment: "Button title to delete the service")
                        .foregroundColor(.red)
                    Spacer()
                }
            }
            .actionSheet(isPresented: $showingDeleteConfirmation) {
                ActionSheet(
                    title: Text("Are you sure you want to delete this service?", comment: "Confirmation message for deleting the service"),
                    buttons: [
                        .destructive(Text("Delete Service", comment: "Button title to delete the service")) {
                            viewModel.deleteService()
                        },
                        .cancel(),
                    ]
                )
            }
        }
    }

    private var doneButton: some View {
        Button(action: { viewModel.saveAndComplete() }) {
            Text(viewModel.isCreating
                 ? LocalizedString("Add Service", comment: "Button title to finish adding the service")
                 : LocalizedString("Done", comment: "Button title to finish editing the service"))
                .bold()
        }
        .disabled(!viewModel.isConfigurationValid)
    }
}
