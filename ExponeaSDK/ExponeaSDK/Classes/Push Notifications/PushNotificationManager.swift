//
//  PushNotificationManager.swift
//  ExponeaSDK
//
//  Created by Dominik Hadl on 25/05/2018.
//  Copyright © 2018 Exponea. All rights reserved.
//

import Foundation
import UserNotifications

protocol PushNotificationManagerType: class {
    var delegate: PushNotificationManagerDelegate? { get set }
    func applicationDidBecomeActive()
}

public protocol PushNotificationManagerDelegate: class {
    func pushNotificationOpened(with action: ExponeaNotificationActionType,
                                value: String?, extraData: [AnyHashable: Any]?)
}

class PushNotificationManager: NSObject, PushNotificationManagerType {
    /// The tracking manager used to track push events
    internal weak var trackingManager: TrackingManagerType?

    private let appGroup: String? // used for sharing data across extensions, fx. for push delivered tracking

    private let tokenTrackFrequency: TokenTrackFrequency
    private var currentPushToken: String?
    private var lastTokenTrackDate: Date

    internal weak var delegate: PushNotificationManagerDelegate?

    let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init(trackingManager: TrackingManagerType,
         appGroup: String?,
         tokenTrackFrequency: TokenTrackFrequency,
         currentPushToken: String?,
         lastTokenTrackDate: Date?) {
        self.appGroup = appGroup
        self.trackingManager = trackingManager
        self.tokenTrackFrequency = tokenTrackFrequency
        self.currentPushToken = currentPushToken
        self.lastTokenTrackDate = lastTokenTrackDate ?? .distantPast
        super.init()

        addAutomaticPushTracking()
        checkForDeliveredPushMessages()
        checkForPushTokenFrequency()
    }

    deinit {
        removeAutomaticPushTracking()
    }

    // MARK: - Actions -

    func handlePushOpened(userInfoObject: AnyObject?, actionIdentifier: String?) {
        Exponea.shared.executeSafely {
            handlePushOpenedUnsafe(userInfoObject: userInfoObject, actionIdentifier: actionIdentifier)
        }
    }

    func handlePushOpenedUnsafe(userInfoObject: AnyObject?, actionIdentifier: String?) {
        guard let pushOpenedData = PushNotificationParser.parsePushOpened(
            userInfoObject: userInfoObject,
            actionIdentifier: actionIdentifier
        ) else {
            return
        }

        var postAction: (() -> Void)?

        switch pushOpenedData.actionType {
        case .none, .openApp:
            // No need to do anything, app was opened automatically
            break

        case .browser, .deeplink:
            // Open the deeplink, iOS will handle if deeplink to safari/other apps
            if let value = pushOpenedData.actionValue, let url = URL(string: value) {
                // Create an action to be executed after tracking
                postAction = {
                    let application = UIApplication.shared

                    let fallbackAction = {
                        if #available(iOS 10.0, *) {
                            application.open(url, options: [:], completionHandler: { success in
                                // If no success opening url using shared app,
                                // try opening using current app
                                if !success {
                                    _ = application.delegate?.application?(
                                        application,
                                        open: url,
                                        options: [:])
                                }
                            })
                        } else {
                            if !application.canOpenURL(url) || !application.openURL(url) {
                                // If no success opening url using shared app,
                                // try opening using current app
                                _ = application.delegate?.application?(
                                    application,
                                    open: url,
                                    options: [:])
                            }
                        }
                    }

                    // Validate this is a valid URL, prevents NSUserActivity crash with invalid URL
                    // eg. MYDEEPLINK::HOME:SCREEN:1
                    guard url.absoluteString.isValidURL else {
                        fallbackAction()
                        return
                    }

                    // Simulate universal link user activity
                    let userActivity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
                    userActivity.webpageURL = url

                    // Try and open the link as universal link first
                    let success = application.delegate?.application?(application,
                                                                     continue: userActivity,
                                                                     restorationHandler: { _ in }) ?? false

                    // If universal links failed to open, let application handle the URL open
                    if !success {
                        fallbackAction()
                    }
                }
            }
        }

        // Track the event
        do {
            try trackingManager?.track(pushOpenedData.eventType, with: pushOpenedData.eventData)
        } catch {
            Exponea.logger.log(.error, message: "Error tracking push opened: \(error.localizedDescription)")
        }

        // Notify the delegate
        delegate?.pushNotificationOpened(
            with: pushOpenedData.actionType,
            value: pushOpenedData.actionValue,
            extraData: pushOpenedData.extraData
        )

        // If we have post process action, execute it
        postAction?()
    }

    func handlePushTokenRegistered(dataObject: AnyObject?) {
        Exponea.shared.executeSafely {
            handlePushTokenRegisteredUnsafe(dataObject: dataObject)
        }
    }

    func handlePushTokenRegisteredUnsafe(dataObject: AnyObject?) {
        guard let tokenData = dataObject as? Data else {
            return
        }

        // Update current push token
        currentPushToken = tokenData.tokenString

        do {
            let data = [DataType.pushNotificationToken(currentPushToken)]
            try trackingManager?.track(.registerPushToken, with: data)
        } catch {
            Exponea.logger.log(.error, message: "Error logging push token. \(error.localizedDescription)")
        }
    }

    internal func checkForDeliveredPushMessages() {
        guard let appGroup = appGroup else {
            Exponea.logger.log(.verbose, message: "No app group was setup, push delivered tracking is disabled.")
            return
        }

        let userDefaults = UserDefaults(suiteName: appGroup)
        guard let array = userDefaults?.array(forKey: Constants.General.deliveredPushUserDefaultsKey) else {
            Exponea.logger.log(.verbose, message: "No delivered push to track present in shared app group.")
            return
        }

        guard let dataArray = array as? [Data] else {
            Exponea.logger.log(.warning, message: "Delivered push data present in shared group but incorrect type.")
            return
        }

        // Process notifications
        for data in dataArray {
            guard let notification = NotificationData.deserialize(from: data) else {
                Exponea.logger.log(.warning, message: "Cannot deserialize stored delivered push data.")
                continue
            }

            // Create payload
            var properties: [String: JSONValue] = notification.properties
            properties["status"] = .string("delivered")

            // Track the event
            do {
                if let customEventType = notification.eventType,
                   !customEventType.isEmpty,
                   customEventType != Constants.EventTypes.pushDelivered {
                    try trackingManager?.track(
                        .customEvent,
                        with: [.eventType(customEventType), .properties(properties), .timestamp(notification.timestamp.timeIntervalSince1970)]
                    )
                } else {
                    try trackingManager?.track(
                        .pushDelivered,
                        with: [.properties(properties), .timestamp(notification.timestamp.timeIntervalSince1970)]
                    )
                }
            } catch {
                Exponea.logger.log(.error, message: "Error tracking push opened: \(error.localizedDescription)")
            }
        }

        // Clear after all is processed
        userDefaults?.removeObject(forKey: Constants.General.deliveredPushUserDefaultsKey)
    }

    func checkForPushTokenFrequency() {
        func trackPushToken() {
            do {
                let data = [DataType.pushNotificationToken(currentPushToken)]
                try trackingManager?.track(.registerPushToken, with: data)
            } catch {
                Exponea.logger.log(.error, message: "Error logging push token. \(error.localizedDescription)")
            }
        }

        switch tokenTrackFrequency {
        case .everyLaunch:
            // Track push token
            lastTokenTrackDate = .init()
            trackPushToken()

        case .daily:
            // Compare last track dates, if equal or more than a day, track
            let now = Date()
            if lastTokenTrackDate.timeIntervalSince(now) >= 86400 {
                lastTokenTrackDate = now
                trackPushToken()
            }

        case .onTokenChange:
            // nothing to do
            break
        }
    }
}

extension PushNotificationManager {
    func applicationDidBecomeActive() {
        checkForDeliveredPushMessages()
        checkForPushTokenFrequency()
    }
}

// MARK: - Swizzling -

extension PushNotificationManager {

    private func addAutomaticPushTracking() {
        swizzleTokenRegistrationTracking()
        swizzleNotificationReceived()
    }

    @objc fileprivate func removeAutomaticPushTracking() {
        // TODO: Fix it. It is just for temporary solution.
    }

    /// This functions swizzles the token registration method to intercept the token and submit it to Exponea.
    private func swizzleTokenRegistrationTracking() {
        guard let appDelegate = UIApplication.shared.delegate else {
            return
        }

        // Monitor push registration
        Swizzler.swizzleSelector(PushSelectorMapping.registration.original,
                                 with: PushSelectorMapping.registration.swizzled,
                                 for: type(of: appDelegate),
                                 name: "PushTokenRegistration",
                                 block: { [weak self] (_, dataObject, _) in
                                    self?.handlePushTokenRegistered(dataObject: dataObject) },
                                 addingMethodIfNecessary: true)
    }

    @objc fileprivate func swizzleNotificationReceived() {
        // TODO: Fix it. It is just for temporary solution.
    }

    /// Removes all swizzles related to notification opened,
    /// useful when `UNUserNotificationCenter` delegate has changed.
    fileprivate func unswizzleAllNotificationReceived() {
        for swizzle in Swizzler.swizzles where swizzle.value.name == "NotificationOpened" {
            Exponea.logger.log(.verbose, message: "Removing swizzle: \(swizzle.value)")
            Swizzler.unswizzle(swizzle.value)
        }
    }

    fileprivate func swizzleUserNotificationsDidReceive(on delegateClass: AnyClass) {
        var swizzleMapping: PushSelectorMapping.Mapping
        // Swizzle the notification delegate notification received function
        if #available(iOS 10.0, *) {
            swizzleMapping = PushSelectorMapping.newReceive

        } else {
            swizzleMapping = PushSelectorMapping.deprecatedReceive
        }

        Swizzler.swizzleSelector(swizzleMapping.original,
                                 with: swizzleMapping.swizzled,
                                 for: delegateClass,
                                 name: "NotificationOpened",
                                 block: { [weak self] (_, userInfoObject, actionIdentifier) in
                                    self?.handlePushOpened(userInfoObject: userInfoObject,
                                                           actionIdentifier: actionIdentifier as? String)
            },
                                 addingMethodIfNecessary: true)
    }
}

@available(iOS 10.0, *)
class ModernPushNotificationManager: PushNotificationManager {

    private let center = UNUserNotificationCenter.current()

    private var receiver: PushNotificationReceiver?
    private var observer: PushNotificationDelegateObserver?

    override func removeAutomaticPushTracking() {
        observer = nil

        for swizzle in Swizzler.swizzles {
            Swizzler.unswizzle(swizzle.value)
        }
    }

    /// Swizzles the appropriate 'notification received' method to interecept received notifications and then calls
    /// the `handlePushOpened` function with the payload so that the event can be tracked to Exponea.
    ///
    /// This method works in the following way:
    ///
    /// 1. It **always** observes changes to `UNUserNotificationCenter`'s `delegate` property and on changes
    /// it calls `notificationsDelegateChanged(_:)`.
    /// 2. Checks if we there is already an existing `UNUserNotificationCenter` delegate,
    /// if so, calls `swizzleUserNotificationsDidReceive(on:)` and exits.
    /// 3. If step 2. fails, it continues to check if the host AppDelegate implements either one of the supported
    /// didReceiveNotification methods. If so, swizzles the one that's implemented while preferring the variant
    /// with fetch handler as that is what Apple recommends.
    /// 4. If step 3 fails, it creates a dummy object `PushNotificationReceiver` that implements the
    /// `UNUserNotificationCenterDelegate` protocol, sets it as the delegate for `UNUserNotificationCenter` and lastly
    /// swizzles the implementation with the custom one.
    override func swizzleNotificationReceived() {
        guard let appDelegate = UIApplication.shared.delegate else {
            Exponea.logger.log(.error, message: "Critical error, no app delegate class available.")
            return
        }

        let appDelegateClass: AnyClass = type(of: appDelegate)
        var swizzleMapping: PushSelectorMapping.Mapping?

        // Add observer
        observer = PushNotificationDelegateObserver(center: center, callback: notificationsDelegateChanged)

        // Check for UNUserNotification's delegate did receive remote notification, if it is setup
        // prefer using that over the UIAppDelegate functions.
        if let delegate = center.delegate {
            swizzleUserNotificationsDidReceive(on: type(of: delegate))
            return
        }

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
            Swizzler.swizzleSelector(mapping.original,
                                     with: mapping.swizzled,
                                     for: appDelegateClass,
                                     name: "NotificationOpened",
                                     block: { [weak self] (_, userInfoObject, _) in
                                        self?.handlePushOpened(userInfoObject: userInfoObject, actionIdentifier: nil) },
                                     addingMethodIfNecessary: true)
        } else {
            // The user is not overriding any UIAppDelegate receive functions nor is using UNUserNotificationCenter.
            // Because we don't have a delegate for UNUserNotifications, let's make a dummy one and set it
            // as the delegate, until the user creates their own delegate (handled by observing .
            receiver = PushNotificationReceiver()
            center.delegate = receiver
        }
    }

    /// Monitor changes in the `UNUserNotificationCenter` delegate.
    ///
    /// - Parameter change: The KVO change object containing the old and new values.
    private func notificationsDelegateChanged(_ change: NSKeyValueObservedChange<UNUserNotificationCenterDelegate?>) {
        // Make sure we unswizzle all notficiation receive methods, before making changes
        unswizzleAllNotificationReceived()

        switch (change.oldValue, change.newValue) {
        case (let old??, let new??) where old is PushNotificationReceiver && !(new is PushNotificationReceiver):
            // User reassigned the dummy receiver to a new delegate, so swizzle it
            self.receiver = nil
            swizzleUserNotificationsDidReceive(on: type(of: new))

        case (let old??, let new) where !(old is PushNotificationReceiver) && new == nil:
            // Reassigning from custom delegate to nil, so create our dummy receiver instead
            self.receiver = PushNotificationReceiver()
            center.delegate = self.receiver

        case (let old, let new??) where old == nil:
            // We were subscribed to app delegate functions before, but now we have a delegate, so swizzle it.
            // Also handles our custom PushNotificationReceiver and swizzles that.
            swizzleUserNotificationsDidReceive(on: type(of: new))

        default:
            Exponea.logger.log(.error, message: """
            Unhandled UNUserNotificationCenterDelegate change, automatic push notification tracking disabled.
            """)
        }
    }
}

class DeprecatedPushNotificationManager: PushNotificationManager {

    override func removeAutomaticPushTracking() {
        for swizzle in Swizzler.swizzles {
            Swizzler.unswizzle(swizzle.value)
        }
    }

    override func swizzleNotificationReceived() {
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
            Swizzler.swizzleSelector(mapping.original,
                                     with: mapping.swizzled,
                                     for: appDelegateClass,
                                     name: "NotificationOpened",
                                     block: { [weak self] (_, userInfoObject, _) in
                                        self?.handlePushOpened(userInfoObject: userInfoObject, actionIdentifier: nil) },
                                     addingMethodIfNecessary: true)
        }
    }
}
