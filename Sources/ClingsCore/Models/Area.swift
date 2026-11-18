// Area.swift
// clings - A powerful CLI for Things 3
// Copyright (C) 2024 Dan Hart
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// An area of responsibility in Things 3.
///
/// Areas are top-level organizational containers that group projects and todos.
public struct Area: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public var tags: [Tag]

    public init(id: String, name: String, tags: [Tag] = []) {
        self.id = id
        self.name = name
        self.tags = tags
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case tags
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        tags = try container.decodeIfPresent([Tag].self, forKey: .tags) ?? []
    }
}

public extension Area {
    /// Whether `name` names this area, ignoring case and surrounding spaces.
    /// Things allows stray spaces in names (such as "Chores "), so this lets
    /// people type what they see.
    func hasName(_ name: String) -> Bool {
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return trim(self.name).caseInsensitiveCompare(trim(name)) == .orderedSame
    }

    /// Find the area a user means by an ID or a name.
    static func resolve(_ reference: String, in areas: [Area]) throws -> Area {
        if let byID = areas.first(where: { $0.id == reference }) {
            return byID
        }
        let matches = areas.filter { $0.hasName(reference) }
        guard let match = matches.first else {
            throw ThingsError.notFound("Area '\(reference)'")
        }
        guard matches.count == 1 else {
            let ids = matches.map(\.id).joined(separator: ", ")
            throw ThingsError.invalidState("Several areas match '\(reference)'; pass one of these IDs instead: \(ids)")
        }
        return match
    }
}
