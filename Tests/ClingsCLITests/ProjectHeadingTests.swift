// ProjectHeadingTests.swift
// clings - A powerful CLI for Things 3
// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
@testable import ClingsCLI
import ClingsCore
import Foundation
import Testing

@Suite("Project add with headings", .serialized)
struct ProjectHeadingTests {
    @Test func headingsCreateProjectThroughJSONURLAndReportNewID() async throws {
        let outlineURL = FileManager.default.temporaryDirectory.appendingPathComponent("outline-\(UUID()).md")
        try "## Week 1\n- API Design\n".write(to: outlineURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outlineURL) }

        let client = RecordingThingsClient()
        let opened = URLRecorder()
        // Simulate Things creating the project when the URL is opened.
        let fakeThings: @Sendable (String) throws -> Void = { url in
            opened.urls.append(url)
            client.projects.append(Project(id: "new-project", name: "Plan"))
        }

        let output = try await CommandTestSupport.withRuntime(client: client) {
            try await CommandRuntime.$openURLScheme.withValue(fakeThings) {
                var command = try ProjectAddCommand.parse(["Plan", "--outline", outlineURL.path, "--heading", "Week 2", "--json"])
                return try await CommandTestSupport.captureStandardOutput { try await command.run() }.1
            }
        }

        #expect(client.createdProjects.isEmpty)
        let url = try #require(opened.urls.first)
        let json = try #require(String(url.dropFirst("things:///json?data=".count)).removingPercentEncoding)
        #expect(json.contains("\"Week 1\"") && json.contains("\"Week 2\"") && json.contains("\"API Design\""))
        #expect(output.contains("\"id\" : \"new-project\""))
        #expect(output.contains("2 heading(s), 1 to-do(s)"))
    }

    @Test func rejectsBlankHeading() async throws {
        let client = RecordingThingsClient()
        let opened = URLRecorder()
        await #expect(throws: ThingsError.self) {
            try await CommandTestSupport.withRuntime(client: client, openedURLs: opened) {
                var command = try ProjectAddCommand.parse(["Plan", "--heading", "  "])
                try await command.run()
            }
        }
        #expect(opened.urls.isEmpty)
    }
}
