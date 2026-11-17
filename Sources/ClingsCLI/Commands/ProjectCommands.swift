// ProjectCommands.swift
// clings - A powerful CLI for Things 3
// Copyright (C) 2024 Dan Hart
// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import ClingsCore
import Foundation

// MARK: - Project Command (Parent)

struct ProjectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "project",
        abstract: "Manage projects",
        discussion: """
        List, create, and audit projects in Things 3. With no subcommand, lists
        projects. Auditing is read-only; add creates a real project.

        Projects are containers for related todos working toward a specific goal.

        EXAMPLES:
          clings project                    List all projects (same as 'clings projects')
          clings project list               Same as above
          clings project add "Documentation Refresh"  Create a new project
          clings project add "Writing Refresh" --area "Writing" --deadline 2027-01-31

        SEE ALSO:
          projects, add --project, areas
        """,
        subcommands: [
            ProjectListCommand.self,
            ProjectAddCommand.self,
            ProjectAuditCommand.self,
        ],
        defaultSubcommand: ProjectListCommand.self
    )
}

// MARK: - Project List Command

struct ProjectListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all projects",
        discussion: """
        Show visible projects, excluding trashed projects and repeating project
        templates in SQLite reads. --json puts count/items under data.

        EXAMPLES:
          clings project list
          clings project ls --json
        """,
        aliases: ["ls"]
    )

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let client = CommandRuntime.makeClient()
        let projects = try await client.fetchProjects()

        let formatter: OutputFormatter = output.json
            ? JSONOutputFormatter()
            : TextOutputFormatter(useColors: !output.noColor)

        print(CLIResponse.render(formatter.format(projects: projects), output: output))
    }
}

// MARK: - Project Add Command

struct ProjectAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Create a new project",
        discussion: """
        Creates a new project in Things 3.

        --when and --deadline accept today, tomorrow, or YYYY-MM-DD. --tags takes
        one comma-separated string (unlike add --tags). Project creation is not
        recorded by clings undo.

        HEADINGS: Things can only create headings together with a new project.
        --heading (repeatable) adds empty headings; --outline reads a Markdown
        file ('-' for stdin) where '# Title' lines become headings and '- Item'
        lines become to-dos under the heading above them. Either option creates
        the project through the things:///json URL command (no auth token).

        EXAMPLES:
          clings project add "Documentation Refresh"
          clings project add "Reading List" --notes "Collect and organize reference material"
          clings project add "Writing Sprint" --area "Writing" --when today
          clings project add "Reference Review" --deadline 2027-06-01 --tags "planning,research"
          clings project add "Launch" --heading "Prep" --heading "Ship"
          clings project add "Study Plan" --area "Learning" --outline plan.md
        """
    )

    @Argument(help: "Title of the project")
    var title: String

    @Option(name: .long, help: "Project notes/description")
    var notes: String?

    @Option(name: .long, help: "Area to assign project to")
    var area: String?

    @Option(name: .long, help: "When to start (today, tomorrow, YYYY-MM-DD)")
    var when: String?

    @Option(name: .long, help: "Deadline date (YYYY-MM-DD)")
    var deadline: String?

    @Option(name: .long, help: "Tags (comma-separated)")
    var tags: String?

    @Option(name: .long, help: "Add an empty heading (repeatable; appended after --outline headings)")
    var heading: [String] = []

    @Option(name: .long, help: "Markdown outline file ('-' for stdin): '# Heading' and '- To-do' lines")
    var outline: String?

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw ThingsError.invalidState("Project title cannot be empty")
        }

        let client = CommandRuntime.makeClient()
        let parsedWhen = try when.map { try parseWhenDate($0) }
        let parsedDeadline = try deadline.map { try parseWhenDate($0) }
        let tagList = tags?
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? []

        if !heading.isEmpty || outline != nil {
            try await createWithOutline(
                title: trimmedTitle, client: client, when: parsedWhen, deadline: parsedDeadline, tags: tagList
            )
            return
        }

        let id = try await client.createProject(
            name: trimmedTitle,
            notes: notes,
            when: parsedWhen,
            deadline: parsedDeadline,
            tags: tagList,
            area: area
        )

        try printOutcome(MutationOutcome(id: id, applied: true, undoRecorded: false, unsupportedUndo: ["project creation"], appliedFields: ["create"], message: "Created project: \(trimmedTitle)"), output: output)
    }

    private func createWithOutline(
        title: String,
        client: any ThingsClientProtocol,
        when: Date?,
        deadline: Date?,
        tags: [String]
    ) async throws {
        var projectOutline = try outline.map { try ProjectOutline.parse(markdown: readOutline($0)) } ?? ProjectOutline()
        for name in heading {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline) else {
                throw ThingsError.invalidState("--heading must be a non-empty single line")
            }
            projectOutline.sections.append(.init(heading: trimmed))
        }

        let url = try ThingsJSONURL.createProject(
            title: title,
            notes: notes,
            area: area,
            when: when.map(Self.dayString),
            deadline: deadline.map(Self.dayString),
            tags: tags,
            outline: projectOutline
        )
        let existingIDs = Set(try await client.fetchProjects().map(\.id))
        try CommandRuntime.openURLScheme(url)

        let todoCount = projectOutline.todos.count + projectOutline.sections.reduce(0) { $0 + $1.todos.count }
        let summary = "\(projectOutline.sections.count) heading(s), \(todoCount) to-do(s)"
        // The URL scheme doesn't return an ID; look for the new project in the database.
        let id = await findNewProject(named: title, excluding: existingIDs, client: client)
        let message = id == nil
            ? "Sent project to Things: \(title) (\(summary)); verify in Things"
            : "Created project: \(title) (\(summary))"
        try printOutcome(MutationOutcome(id: id, applied: true, undoRecorded: false, unsupportedUndo: ["project creation"], appliedFields: ["create", "headings"], message: message), output: output)
    }

    private func readOutline(_ path: String) throws -> String {
        if path == "-" {
            return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
        do {
            return try String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)
        } catch {
            throw ThingsError.invalidState("Cannot read outline file \(path): \(error.localizedDescription)")
        }
    }

    private func findNewProject(named title: String, excluding existing: Set<String>, client: any ThingsClientProtocol) async -> String? {
        for _ in 0..<10 {
            if let match = try? await client.fetchProjects().first(where: { $0.name == title && !existing.contains($0.id) }) {
                return match.id
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return nil
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func parseWhenDate(_ str: String) throws -> Date {
        let lower = str.lowercased()
        let isAbsolute = str.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        if lower == "today" || lower == "tomorrow" || isAbsolute {
            if let date = try resolveDate(str) {
                return date
            }
        }
        throw ThingsError.invalidState("Invalid date format: \(str). Use YYYY-MM-DD, 'today', or 'tomorrow'.")
    }
}

struct ProjectAuditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit",
        abstract: "Audit project health and missing next actions",
        discussion: """
        Inspect open projects and flag missing next actions, overdue work, and
        other stalled-project signals.

        Generates a report without changing projects or todos. Use --json for
        structured findings; project names and todo IDs can guide follow-up work.

        EXAMPLES:
          clings project audit
          clings project audit --json
        """
    )

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let client = CommandRuntime.makeClient()
        let report = try await ProjectAudit().audit(
            projects: client.fetchProjects(),
            todos: fetchOpenTodos(client: client)
        )

        if output.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            print(CLIResponse.success(String(decoding: data, as: UTF8.self)))
            return
        }

        if report.items.isEmpty {
            print("No open projects to audit")
            return
        }

        for item in report.items {
            let findings = item.findings.isEmpty ? "Healthy" : item.findings.joined(separator: ", ")
            print("\(item.project.name): \(findings)")
        }
    }
}
