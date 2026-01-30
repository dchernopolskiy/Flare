//
//  MicrosoftModel.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//

import Foundation

struct MSResponse: Codable {
    let status: Int
    let error: MSError?
    let data: MSData
    let metadata: MSMetadata?
}

struct MSError: Codable {
    let message: String
    let body: String
}

struct MSData: Codable {
    let positions: [MSPosition]
    let count: Int
    let sortBy: String?
    let filterDef: MSFilterDef?
    let appliedFilters: [String: [String]]?
}

struct MSPosition: Codable {
    let id: Int
    let displayJobId: String
    let name: String
    let locations: [String]
    let standardizedLocations: [String]?
    let postedTs: Int
    let solrScore: Double?
    let stars: Int?
    let department: String?
    let creationTs: Int?
    let isHot: Int?
    let workLocationOption: String?
    let locationFlexibility: String?
    let atsJobId: String?
    let positionUrl: String
    
    // Computed properties to handle "bumped" jobs
    var originalPostingDate: Date {
        // creationTs is the original posting date
        if let creation = creationTs {
            return Date(timeIntervalSince1970: TimeInterval(creation))
        }
        // Fallback to postedTs if creationTs not available
        return Date(timeIntervalSince1970: TimeInterval(postedTs))
    }
    
    var lastRefreshDate: Date {
        // postedTs represents when the job was last "bumped" or refreshed
        return Date(timeIntervalSince1970: TimeInterval(postedTs))
    }
    
    var wasBumped: Bool {
        guard let creation = creationTs else { return false }
        let timeDiff = postedTs - creation
        // 48 hours threshold - jobs refreshed within 2 days of creation are normal
        return timeDiff > (48 * 3600)
    }
}

struct MSFilterDef: Codable {
    let facets: MSFacets?
    let smartFilters: [MSFilter]?
    let allFilters: [MSFilter]?
}

struct MSFacets: Codable {
    let locations: [[MSFacetValue]]?
}

enum MSFacetValue: Codable {
    case string(String)
    case int(Int)
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid facet value")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        }
    }
}

struct MSFilter: Codable {
    let type: String
    let filterName: String
    let title: String
    let options: [MSFilterOption]?
    let tooltip: String?
    let displayCount: Int?
    let translateOptions: Bool?
    let allowFreeText: Bool?
}

struct MSFilterOption: Codable {
    let label: String
    let value: String
}

struct MSMetadata: Codable {
}

// MARK: - Position Details API Models

struct MSPositionDetailsResponse: Codable {
    let status: Int
    let error: MSError?
    let data: MSPositionDetails?
}

struct MSPositionDetails: Codable {
    let jobDescription: String?
    let positionId: String?
    let displayJobId: String?
    let title: String?
    let locations: [String]?
    let department: String?
    let workLocationOption: String?
}
