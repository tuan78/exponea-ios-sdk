//
//  PushNotificationSwizzlerType.swift
//  ExponeaSDK
//
//  Created by Panaxeo on 11/29/19.
//  Copyright © 2019 Exponea. All rights reserved.
//

import Foundation

protocol PushNotificationSwizzlerType: class {
    func addAutomaticPushTracking()
    func removeAutomaticPushTracking()
}
