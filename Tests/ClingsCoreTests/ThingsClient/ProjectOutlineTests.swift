// ProjectOutlineTests.swift
// clings - A powerful CLI for Things 3
// SPDX-License-Identifier: GPL-3.0-or-later

@testable import ClingsCore
import Foundation
import Testing

@Suite("ProjectOutline")
struct ProjectOutlineTests {
    @Test func parsesHeadingsAndTodos() throws {
        let outline = try ProjectOutline.parse(markdown: """
        - Loose task

        ## Week 1
        - [ ] Caching
        * Sharding
        # Week 2
        """)
        #expect(outline.todos == ["Loose task"])
        #expect(outline.sections == [
            .init(heading: "Week 1", todos: ["Caching", "Sharding"]),
            .init(heading: "Week 2"),
        ])
    }

    @Test func rejectsUnrecognizedLines() {
        #expect(throws: ThingsError.self) { try ProjectOutline.parse(markdown: "## Week 1\nCaching") }
        #expect(throws: ThingsError.self) { try ProjectOutline.parse(markdown: "##") }
    }

    @Test func buildsJSONURLThatThingsCanDecode() throws {
        let url = try ThingsJSONURL.createProject(
            title: "Study & Plan+",
            area: "Job Search",
            deadline: "2026-12-19",
            tags: ["🤖 Codex"],
            outline: ProjectOutline(sections: [.init(heading: "Week 1", todos: ["API Design"])])
        )
        #expect(url.hasPrefix("things:///json?data="))
        let encoded = String(url.dropFirst("things:///json?data=".count))
        #expect(!encoded.contains("+") && !encoded.contains("&"))

        let json = try #require(encoded.removingPercentEncoding)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        let attributes = try #require(payload.first?["attributes"] as? [String: Any])
        #expect(payload.first?["type"] as? String == "project")
        #expect(attributes["title"] as? String == "Study & Plan+")
        #expect(attributes["area"] as? String == "Job Search")
        #expect(attributes["deadline"] as? String == "2026-12-19")
        #expect(attributes["tags"] as? [String] == ["🤖 Codex"])

        let items = try #require(attributes["items"] as? [[String: Any]])
        #expect(items.map { $0["type"] as? String } == ["heading", "to-do"])
        #expect(items.map { ($0["attributes"] as? [String: Any])?["title"] as? String } == ["Week 1", "API Design"])
    }
}
