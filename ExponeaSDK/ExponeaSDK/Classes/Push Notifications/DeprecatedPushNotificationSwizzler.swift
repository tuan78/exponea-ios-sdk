//
//  DeprecatedPushNotificationSwizzler.swift
//  ExponeaSDK
//
//  Created by Panaxeo on 11/29/19.
//  Copyright © 2019 Exponea. All rights reserved.
//

import Foundation

/**
In order to unit test swizzling of methods related to receiving push notification,
we have to solve issue of missing UNUserNotificationCenter and inability to set UIApplication.delegate.
Instead of using UIApplication and UNUserNotificationCenter directly, we'll work with protocols that have delegates we need.
In unit tests we can pass different object that conform to those protocols.
*/
@available(iOS, deprecated: 10.0, message:"Use PushNotificationSwizzler")
final class DeprecatedPushNotificationSwizzler: PushNotificationSwizzlerType {
    private let uiApplicationDelegating: UIApplicationDelegating

    private weak var pushNotificationManager: PushNotificationManagerType?

    /*
     We should always swizzle notification delegate to make sure it gets called if developer/sdk changes it.
     But if the developer/sdk swizzles/changes the delegate and calls the original method we would get called multiple times.
     Let's keep a unique token that we change with every swizzle
     */
    private var pushOpenedSwizzleToken: String = UUID().uuidString

    public init(
        _ manager: PushNotificationManagerType,
        uiApplicationDelegating: UIApplicationDelegating? = nil
    ) {
        self.pushNotificationManager = manager
        self.uiApplicationDelegating = uiApplicationDelegating ?? UIApplication.shared
    }

    func addAutomaticPushTracking() {
        swizzleTokenRegistrationTracking()
        swizzleNotificationReceived()
    }

    func removeAutomaticPushTracking() {
        for swizzle in Swizzler.swizzles {
            Swizzler.unswizzle(swizzle.value)
        }
    }

    /// This functions swizzles the token registration method to intercept the token and submit it to Exponea.
    private func swizzleTokenRegistrationTracking() {
        guard let appDelegate = uiApplicationDelegating.delegate else {
            return
        }

        // Monitor push registration
        Swizzler.swizzleSelector(PushSelectorMapping.registration.original,
                                 with: PushSelectorMapping.registration.swizzled,
                                 for: type(of: appDelegate),
                                 name: "PushTokenRegistration",
                                 block: { [weak self] (_, dataObject, _) in
                                    self?.pushNotificationManager?.handlePushTokenRegistered(dataObject: dataObject) },
                                 addingMethodIfNecessary: true)
    }

    func swizzleNotificationReceived() {
        guard let appDelegate = UIApplication.shared.delegate else {
            Exponea.logger.log(.error, message: "Critical error, no app delegate class available.")
            return
        }

        let appDelegateClass: AnyClass = type(of: appDelegate)
        var swizzleMapping: PushSelectorMapping.Mapping?

        // Check if UIAppDelegate notification receive functions are implemented
        if class_getInstanceMethod(appDelegateClass, PushSelectorMapping.handlerReceive.original) != nil {
            // Check for UIAppDelegate's did receive remote notification with fetch completion handler (preferred)
            swizzleMapping = PushSelectorMapping.handlerReceive
        } else if class_getInstanceMethod(appDelegateClass, PushSelectorMapping.deprecatedReceive.original) != nil {
            // Check for UIAppDelegate's deprecated receive remote notification
            swizzleMapping = PushSelectorMapping.deprecatedReceive
        }

        // If user is overriding either of UIAppDelegete receive functions, swizzle it
        if let mapping = swizzleMapping {
            // Do the swizzling
            let token = UUID().uuidString
            pushOpenedSwizzleToken = token
            Swizzler.swizzleSelector(mapping.original,
                                     with: mapping.swizzled,
                                     for: appDelegateClass,
                                     name: "NotificationOpened",
                                     block: { [weak self] (_, userInfoObject, _) in
                                        guard self?.pushOpenedSwizzleToken == token else {
                                            return
                                        }
                                        self?.pushNotificationManager?.handlePushOpened(userInfoObject: userInfoObject, actionIdentifier: nil) },
                                     addingMethodIfNecessary: true)
        }
    }
}
