//
//  GarminDataFieldServiceKitPlugin.swift
//  GarminDataFieldServiceKitPlugin
//
//  Principal class of the .loopplugin bundle; Loop discovers the service
//  through this ServiceUIPlugin conformance.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import os
import LoopKitUI
import GarminDataFieldServiceKit
import GarminDataFieldServiceKitUI

class GarminDataFieldServiceKitPlugin: NSObject, ServiceUIPlugin {
    private let log = Logger(subsystem: "GarminDataFieldService", category: "GarminDataFieldServiceKitPlugin")

    public var serviceType: ServiceUI.Type? {
        return GarminDataFieldService.self
    }

    override init() {
        super.init()
        log.info("Instantiated")
    }
}
