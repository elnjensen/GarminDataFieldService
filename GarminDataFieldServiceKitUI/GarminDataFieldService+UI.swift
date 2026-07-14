//
//  GarminDataFieldService+UI.swift
//  GarminDataFieldServiceKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import UIKit
import LoopKit
import LoopKitUI
import GarminDataFieldServiceKit

extension GarminDataFieldService: ServiceUI {

    public static var image: UIImage? {
        UIImage(named: "garmin_icon", in: Bundle(for: GarminDataFieldServiceNavigationController.self), compatibleWith: nil)
    }

    public static func setupViewController(colorPalette: LoopUIColorPalette, pluginHost: PluginHost) -> SetupUIResult<ServiceViewController, ServiceUI> {
        return .userInteractionRequired(GarminDataFieldServiceNavigationController(service: GarminDataFieldService(), isCreating: true))
    }

    public func settingsViewController(colorPalette: LoopUIColorPalette) -> ServiceViewController {
        return GarminDataFieldServiceNavigationController(service: self, isCreating: false)
    }

    public func supportMenuItem(supportInfoProvider: SupportInfoProvider, urlHandler: @escaping (URL) -> Void) -> AnyView? {
        return nil
    }
}

/// Hosts the SwiftUI settings view and reports creation/completion back to Loop.
class GarminDataFieldServiceNavigationController: ServiceNavigationController {

    init(service: GarminDataFieldService, isCreating: Bool) {
        let viewModel = GarminDataFieldServiceViewModel(service: service, isCreating: isCreating)
        let hostingController = UIHostingController(rootView: GarminDataFieldServiceSettingsView(viewModel: viewModel))
        super.init(rootViewController: hostingController)

        viewModel.onCompletion = { [weak self] in
            guard let self = self else { return }
            if isCreating {
                self.notifyServiceCreatedAndOnboarded(service)
            }
            self.notifyComplete()
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
