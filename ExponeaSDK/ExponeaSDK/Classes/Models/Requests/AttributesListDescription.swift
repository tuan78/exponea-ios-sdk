//
//  CustomerExportAttributesModel.swift
//  ExponeaSDK
//
//  Created by Dominik Hádl on 11/04/2018.
//  Copyright © 2018 Exponea. All rights reserved.
//

import Foundation

/// <#Description#>
struct AttributesListDescription: Codable {

    /// <#Description#>
    public var type: String

    /// <#Description#>
    public var list: [AttributesDescription]
}
