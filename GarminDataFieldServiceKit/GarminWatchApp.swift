//
//  GarminWatchApp.swift
//  GarminDataFieldServiceKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

/// The Connect IQ app (on a Garmin watch or bike computer) the service sends data to.
///
/// The Trio and SwissAlpine datafields and watch faces are published in the
/// Connect IQ store and all consume the same `GarminWatchState` message format -
/// the phone-side send path is identical, only the target UUID differs. `custom`
/// lets a user target their own (e.g. self-built) Connect IQ app speaking the
/// same format.
///
/// Datafields only run while an activity is recording; watch faces run whenever
/// they are displayed, so they need no activity. The watch face options are
/// carried over from Trio's published UUIDs and are UNTESTED here.
public enum GarminWatchAppChoice: String, CaseIterable, Codable {
    case trioDatafield
    case swissAlpineDatafield
    case loopGraphDatafield
    case trioWatchface
    case swissAlpineWatchface
    case custom

    /// The Connect IQ application UUID (as declared in the watch app's manifest),
    /// or nil for `custom` (supplied separately by the user).
    public var appUUID: UUID? {
        switch self {
        case .trioDatafield:
            return UUID(uuidString: "3d9b6528-8c84-459a-bbab-989b5f001ebd")
        case .swissAlpineDatafield:
            return UUID(uuidString: "dec5292a-74b0-41bc-8e45-cd93f1d5e137")
        case .loopGraphDatafield:
            // Self-built graph datafield (see the LoopGraphDatafield project);
            // sideloaded, not in the Connect IQ store.
            return UUID(uuidString: "2e18aaa2-2b57-47d3-8ace-f9cd27c0d765")
        case .trioWatchface:
            return UUID(uuidString: "7a121867-140e-41ba-9982-2e82e2aa6579")
        case .swissAlpineWatchface:
            return UUID(uuidString: "4cea4efd-4aaf-4db4-8891-ef36dde14303")
        case .custom:
            return nil
        }
    }

    public var localizedTitle: String {
        switch self {
        case .trioDatafield:
            return LocalizedString("Trio Datafield", comment: "Title of the Trio datafield Connect IQ app choice")
        case .swissAlpineDatafield:
            return LocalizedString("SwissAlpine Datafield", comment: "Title of the SwissAlpine datafield Connect IQ app choice")
        case .loopGraphDatafield:
            return LocalizedString("Loop Graph Datafield", comment: "Title of the Loop Graph datafield Connect IQ app choice")
        case .trioWatchface:
            return LocalizedString("Trio Watch Face", comment: "Title of the Trio watch face Connect IQ app choice")
        case .swissAlpineWatchface:
            return LocalizedString("SwissAlpine Watch Face", comment: "Title of the SwissAlpine watch face Connect IQ app choice")
        case .custom:
            return LocalizedString("Custom App UUID", comment: "Title of the custom Connect IQ app choice")
        }
    }
}

/// Which value the Connect IQ app shows in its primary configurable slot.
/// Raw values are the wire strings expected by the Trio/SwissAlpine watch apps.
public enum GarminPrimaryAttribute: String, CaseIterable, Codable {
    case cob
    case isf

    public var localizedTitle: String {
        switch self {
        case .cob:
            return LocalizedString("Carbs on Board", comment: "Title of the COB primary display attribute")
        case .isf:
            return LocalizedString("Insulin Sensitivity", comment: "Title of the ISF primary display attribute")
        }
    }
}

/// Which value the Connect IQ app shows in its secondary configurable slot.
/// Raw values are the wire strings expected by the Trio/SwissAlpine watch apps.
public enum GarminSecondaryAttribute: String, CaseIterable, Codable {
    case tbr
    case eventualBG

    public var localizedTitle: String {
        switch self {
        case .tbr:
            return LocalizedString("Basal Rate", comment: "Title of the basal rate secondary display attribute")
        case .eventualBG:
            return LocalizedString("Eventual Glucose", comment: "Title of the eventual glucose secondary display attribute")
        }
    }
}
