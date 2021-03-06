//
//  FetchEventsRequest.swift
//  ExponeaSDK
//
//  Created by Dominik Hádl on 11/04/2018.
//  Copyright © 2018 Exponea. All rights reserved.
//

import Foundation

/// Data type used to receive the customer events parameters
/// to fetch the event types of a selected customer.
struct EventsRequest {

    /// List of event that you want to fetch.
    public var eventTypes: [String]

    /// Order of exported events by timestamp (asc/desc).
    public var sortOrder: String?

    /// Number of items to return.
    public var limit: Int?

    /// Number of items to be skipped from the beginning
    public var skip: Int?

    /// Events request initializer
    ///
    /// - Parameters:
    ///   - evenTypes: List of event that you want to fetch.
    ///   - sortOrder: Order of exported events by timestamp (asc/desc).
    ///   - limit: Number of items to return.
    ///   - skip: Number of items to be skipped from the beginning
    public init(eventTypes: [String],
                sortOrder: String? = nil,
                limit: Int? = nil,
                skip: Int? = nil) {
        self.eventTypes = eventTypes
        self.sortOrder = sortOrder
        self.limit = limit
        self.skip = skip
    }
}
