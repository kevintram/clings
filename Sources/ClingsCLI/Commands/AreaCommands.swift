// AreaCommands.swift
// clings - A powerful CLI for Things 3
// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import ClingsCore

// MARK: - Areas Command (Parent)

struct AreasCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "areas",
        abstract: "Manage areas",
        discussion: """
        List, create, rename, and delete areas in Things 3.

        With no subcommand, lists areas. Areas represent ongoing spheres of
        responsibility (e.g., "Work", "Personal", "Health"); projects and
        todos can be assigned to them.

        Refer to an area by its ID or its name. Name matching ignores case
        and surrounding spaces. Area management is not recorded by undo.

        EXAMPLES:
          clings areas                        List all areas
          clings areas --json                 Output as JSON
          clings areas add "Health"           Create an area
          clings areas rename "Misc" "Inbox"  Rename an area
          clings areas delete "Misc"          Delete an area

        SEE ALSO:
          projects, add --area, filter "area = 'Writing'"
        """,
        subcommands: [
            AreasListCommand.self,
            AreasAddCommand.self,
            AreasRenameCommand.self,
            AreasDeleteCommand.self,
        ],
        defaultSubcommand: AreasListCommand.self
    )
}

// MARK: - Areas List Command

struct AreasListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all areas",
        discussion: """
        Show every area in Things.

        --json puts count/items under data. Use the displayed names or IDs
        with add --area, areas rename, or areas delete.

        EXAMPLES:
          clings areas list
          clings areas ls --json
        """,
        aliases: ["ls"]
    )

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let client = CommandRuntime.makeClient()
        let areas = try await client.fetchAreas()
        print(CLIResponse.render(makeFormatter(output).format(areas: areas), output: output))
    }
}

// MARK: - Areas Add Command

struct AreasAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Create a new area",
        discussion: """
        Creates a new, empty area in Things 3.

        Fails if an area with the same name already exists. This operation
        is not recorded by undo.

        EXAMPLES:
          clings areas add "Health"
          clings areas add "🏡 Home" --json
        """
    )

    @Argument(help: "Name of the area to create")
    var name: String

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let trimmedName = try nonEmpty(name, label: "Area name")
        let client = CommandRuntime.makeClient()

        if let existing = try await client.fetchAreas().first(where: { $0.hasName(trimmedName) }) {
            throw ThingsError.invalidState("An area named '\(existing.name)' already exists (\(existing.id))")
        }

        let area = try await client.createArea(name: trimmedName)
        let formatter = makeFormatter(output)
        if output.json {
            print(CLIResponse.success(formatter.format(areas: [area])))
        } else {
            print(formatter.format(message: "Created area: \(area.name)"))
        }
    }
}

// MARK: - Areas Rename Command

struct AreasRenameCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename an area",
        discussion: """
        Renames an existing area in Things 3. Its projects and todos stay in it.

        The alias is areas mv. This is not recorded by clings undo.

        EXAMPLES:
          clings areas rename "Pratical" "Practical"
          clings areas rename 4TBM7zGNPPLxAPZBH3TWe3 "Life"
        """,
        aliases: ["mv"]
    )

    @Argument(help: "Current name or ID of the area")
    var area: String

    @Argument(help: "New name for the area")
    var newName: String

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let trimmedNew = try nonEmpty(newName, label: "New area name")
        let client = CommandRuntime.makeClient()
        let target = try Area.resolve(area, in: await client.fetchAreas())

        guard target.name != trimmedNew else {
            throw ThingsError.invalidState("Old and new names are the same")
        }

        try await client.renameArea(id: target.id, newName: trimmedNew)
        print(CLIResponse.render(
            makeFormatter(output).format(message: "Renamed area: \(target.name) -> \(trimmedNew)"),
            output: output
        ))
    }
}

// MARK: - Areas Delete Command

struct AreasDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete an area",
        discussion: """
        Deletes an area from Things 3.

        WARNING: Things moves everything in the area to the Trash: its
        projects (with their todos) and the todos filed directly in it. The
        confirmation prompt shows how many of each will be trashed; --force
        skips it. Move anything you want to keep out of the area first.
        clings undo cannot reverse this; restore from the Things Trash.

        EXAMPLES:
          clings areas delete "Misc"
          clings areas rm "Misc" --force
        """,
        aliases: ["rm"]
    )

    @Argument(help: "Name or ID of the area to delete")
    var area: String

    @Flag(name: .shortAndLong, help: "Skip confirmation prompt")
    var force = false

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let client = CommandRuntime.makeClient()
        let target = try Area.resolve(area, in: await client.fetchAreas())

        var todos: [Todo] = []
        for list in [ListView.inbox, .today, .upcoming, .anytime, .someday] {
            todos += try await client.fetchQueryList(list)
        }
        let prompt = try await Self.confirmationPrompt(for: target, projects: client.fetchProjects(), todos: todos)

        guard try confirmMutation(prompt, authorized: force) else {
            try printOutcome(MutationOutcome(applied: false, undoRecorded: false, message: "Canceled request; no change applied"), output: output)
            return
        }

        try await client.deleteArea(id: target.id)
        print(CLIResponse.render(makeFormatter(output).format(message: "Deleted area: \(target.name)"), output: output))
    }

    /// Counts what Things will trash with the area. Todos inside the area's
    /// projects go with their project, so only loose todos are counted, once
    /// each even when they appear in several lists.
    static func confirmationPrompt(for area: Area, projects: [Project], todos: [Todo]) -> String {
        let projectCount = projects.filter { $0.area?.id == area.id }.count
        let todoCount = Set(todos.filter { $0.area?.id == area.id && $0.project == nil }.map(\.id)).count
        return "Delete area '\(area.name)'? Its \(projectCount) project(s) and \(todoCount) other todo(s) "
            + "will move to the Things Trash; clings undo cannot reverse this."
    }
}

// MARK: - Helpers

private func makeFormatter(_ output: OutputOptions) -> OutputFormatter {
    output.json ? JSONOutputFormatter() : TextOutputFormatter(useColors: !output.noColor)
}

private func nonEmpty(_ value: String, label: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw ThingsError.invalidState("\(label) cannot be empty")
    }
    return trimmed
}
