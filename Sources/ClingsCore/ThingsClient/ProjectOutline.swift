// ProjectOutline.swift
// clings - A powerful CLI for Things 3
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The headings and to-dos to create inside a new project.
///
/// Things only lets headings be created together with their project (via the
/// `things:///json` URL command); neither JXA nor the URL scheme can add a
/// heading to an existing project.
public struct ProjectOutline: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        public var heading: String
        public var todos: [String]

        public init(heading: String, todos: [String] = []) {
            self.heading = heading
            self.todos = todos
        }
    }

    /// To-dos that appear before the first heading.
    public var todos: [String]
    public var sections: [Section]

    public init(todos: [String] = [], sections: [Section] = []) {
        self.todos = todos
        self.sections = sections
    }

    public var isEmpty: Bool { todos.isEmpty && sections.isEmpty }

    /// Parse a Markdown outline: `#` lines (any level) become headings and
    /// `-`, `*`, or `- [ ]` list items become to-dos. Blank lines are ignored;
    /// anything else is rejected so typos don't silently disappear.
    public static func parse(markdown: String) throws -> ProjectOutline {
        var outline = ProjectOutline()
        for (index, rawLine) in markdown.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#") {
                let heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                guard !heading.isEmpty else {
                    throw ThingsError.invalidState("Outline line \(index + 1): heading is empty")
                }
                outline.sections.append(Section(heading: heading))
                continue
            }

            guard let todo = listItemTitle(line) else {
                throw ThingsError.invalidState("Outline line \(index + 1): expected '# Heading' or '- To-do', got: \(line)")
            }
            if outline.sections.isEmpty {
                outline.todos.append(todo)
            } else {
                outline.sections[outline.sections.count - 1].todos.append(todo)
            }
        }
        return outline
    }

    private static func listItemTitle(_ line: String) -> String? {
        guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
        var title = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        if title.hasPrefix("[ ] ") {
            title = String(title.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }
        return title.isEmpty ? nil : title
    }
}

/// Builds `things:///json` URLs, which can create a project together with its
/// headings and to-dos in one atomic call without an auth token.
public enum ThingsJSONURL {
    public static func createProject(
        title: String,
        notes: String? = nil,
        area: String? = nil,
        when: String? = nil,
        deadline: String? = nil,
        tags: [String] = [],
        outline: ProjectOutline
    ) throws -> String {
        var attributes: [String: Any] = ["title": title]
        if let notes { attributes["notes"] = notes }
        if let area { attributes["area"] = area }
        if let when { attributes["when"] = when }
        if let deadline { attributes["deadline"] = deadline }
        if !tags.isEmpty { attributes["tags"] = tags }

        var items: [[String: Any]] = outline.todos.map(todoItem)
        for section in outline.sections {
            items.append(["type": "heading", "attributes": ["title": section.heading]])
            items.append(contentsOf: section.todos.map(todoItem))
        }
        if !items.isEmpty { attributes["items"] = items }

        let payload: [[String: Any]] = [["type": "project", "attributes": attributes]]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        return "things:///json?data=\(percentEncode(json))"
    }

    private static func todoItem(_ title: String) -> [String: Any] {
        ["type": "to-do", "attributes": ["title": title]]
    }

    /// Strict RFC 3986 encoding; `URLComponents` leaves `+`, `&`, and `=`
    /// ambiguous inside a query value.
    static func percentEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
