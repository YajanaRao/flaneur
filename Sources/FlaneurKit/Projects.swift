import Foundation

public struct GitHubRepository: Hashable, Sendable, Codable {
    public let nameWithOwner: String
    public let url: URL

    public init(nameWithOwner: String, url: URL) {
        self.nameWithOwner = nameWithOwner
        self.url = url
    }
}

public struct WorkflowInput: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case string, choice, boolean
    }

    public let name: String
    public let description: String
    public let kind: Kind
    public let required: Bool
    public let defaultValue: String
    public let options: [String]

    public init(
        name: String, description: String = "", kind: Kind = .string, required: Bool = false,
        defaultValue: String = "", options: [String] = []
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.required = required
        self.defaultValue = defaultValue
        self.options = options
    }
}

public struct Workflow: Hashable, Sendable, Codable {
    public let name: String
    public let fileName: String
    public let inputs: [WorkflowInput]

    public init(name: String, fileName: String, inputs: [WorkflowInput] = []) {
        self.name = name
        self.fileName = fileName
        self.inputs = inputs
    }
}

public struct ProjectFolder: Hashable, Sendable, Codable {
    public let url: URL
    public let name: String
    public let repository: GitHubRepository?
    public let branch: String
    public let branches: [String]
    public let workflows: [Workflow]
    public let workflowSignature: String

    public init(
        url: URL, name: String? = nil, repository: GitHubRepository? = nil,
        branch: String = "", branches: [String] = [], workflows: [Workflow] = [],
        workflowSignature: String = ""
    ) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.repository = repository
        self.branch = branch
        self.branches = branches
        self.workflows = workflows
        self.workflowSignature = workflowSignature
    }
}

public enum Projects {
    private static let git = "/usr/bin/git"
    private static let gh = "/opt/homebrew/bin/gh"
    private static let freshFor: Duration = .seconds(300)

    public static func warm() async {
        _ = await collect()
    }

    static func collect(
        onUpdate: @escaping @Sendable ([ProjectFolder]) -> Void = { _ in }
    ) async -> [ProjectFolder] {
        await Cache.shared.projects(onUpdate: onUpdate)
    }

    static func run(
        _ workflow: Workflow, in project: ProjectFolder, branch: String, inputs: [String: String]
    ) async throws -> String {
        let data = try await Shell.run(
            gh, dispatchArguments(workflow, project: project, branch: branch, inputs: inputs),
            timeout: .seconds(30)
        )
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func dispatchArguments(
        _ workflow: Workflow, project: ProjectFolder, branch: String, inputs: [String: String]
    ) -> [String] {
        var arguments = [
            "workflow", "run", workflow.fileName,
            "--repo", project.repository?.nameWithOwner ?? "",
            "--ref", branch,
        ]
        for input in workflow.inputs {
            guard let value = inputs[input.name], !value.isEmpty else { continue }
            arguments += ["--raw-field", "\(input.name)=\(value)"]
        }
        return arguments
    }

    static func repository(remote: String) -> GitHubRepository? {
        let remote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        var path: String
        if remote.hasPrefix("git@github.com:") {
            path = String(remote.dropFirst("git@github.com:".count))
        } else if let components = URLComponents(string: remote), components.host == "github.com" {
            path = components.path
        } else {
            return nil
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/")
        guard parts.count == 2, let url = URL(string: "https://github.com/\(path)") else { return nil }
        return GitHubRepository(nameWithOwner: path, url: url)
    }

    private static func scan(root: URL, cached: [ProjectFolder]) async -> [ProjectFolder] {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return cached }
        let previous = Dictionary(uniqueKeysWithValues: cached.map { ($0.url.path, $0) })
        var projects: [ProjectFolder] = []
        for url in folders.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let path = url.path
            guard manager.fileExists(atPath: url.appendingPathComponent(".git").path) else {
                projects.append(ProjectFolder(url: url))
                continue
            }

            async let remoteData = try? Shell.run(git, ["-C", path, "remote", "get-url", "origin"], timeout: .seconds(2))
            async let branchData = try? Shell.run(git, ["-C", path, "branch", "--show-current"], timeout: .seconds(2))
            async let branchesData = try? Shell.run(
                git,
                ["-C", path, "for-each-ref", "--format=%(refname:short)", "--sort=refname", "refs/remotes/origin"],
                timeout: .seconds(3)
            )
            async let defaultData = try? Shell.run(
                git, ["-C", path, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
                timeout: .seconds(2)
            )

            let remote = await remoteData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let branch = await branchData.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let defaultBranch = await defaultData.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "origin/", with: "") ?? ""
            let branchOutput = await branchesData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            var seen: Set<String> = []
            var branches = branchOutput.split(separator: "\n").compactMap { line -> String? in
                let name = line.trimmingCharacters(in: .whitespaces)
                guard name != "origin/HEAD", name.hasPrefix("origin/") else { return nil }
                let branch = String(name.dropFirst("origin/".count))
                return seen.insert(branch).inserted ? branch : nil
            }
            branches.sort { lhs, rhs in
                if lhs == rhs { return false }
                if lhs == branch { return true }
                if rhs == branch { return false }
                if lhs == defaultBranch { return true }
                if rhs == defaultBranch { return false }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }

            let repo = repository(remote: remote)
            let signature = repo == nil ? "" : workflowSignature(in: url)
            let workflows: [Workflow]
            if let old = previous[path], old.workflowSignature == signature {
                workflows = old.workflows
            } else {
                workflows = repo == nil ? [] : readWorkflows(in: url)
            }
            projects.append(ProjectFolder(
                url: url, repository: repo, branch: branch, branches: branches,
                workflows: workflows, workflowSignature: signature
            ))
        }
        return projects
    }

    private static func workflowFiles(in project: URL) -> [URL] {
        let directory = project.appendingPathComponent(".github/workflows")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.filter { ["yml", "yaml"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func workflowSignature(in project: URL) -> String {
        workflowFiles(in: project).map { file in
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            return "\(file.lastPathComponent):\(size):\(modified)"
        }.joined(separator: "|")
    }

    private static func readWorkflows(in project: URL) -> [Workflow] {
        workflowFiles(in: project).compactMap { parseWorkflow(at: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func parseWorkflow(at url: URL) -> Workflow? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines)
        var name = url.deletingPathExtension().lastPathComponent
        var dispatch: (index: Int, indent: Int)?

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("name:") {
                let value = scalar(String(trimmed.dropFirst("name:".count)))
                if !value.isEmpty { name = value }
            }
            guard indentation(of: line) == 0 else { continue }
            if trimmed.hasPrefix("on:") || trimmed.hasPrefix("\"on\":") || trimmed.hasPrefix("'on':") {
                let value = trimmed.split(separator: ":", maxSplits: 1).dropFirst().joined(separator: ":")
                if value.contains("workflow_dispatch") {
                    return Workflow(name: name, fileName: url.lastPathComponent)
                }
                dispatch = (index, 0)
            } else if dispatch != nil, !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                break
            }
        }
        guard let dispatch else { return nil }

        var dispatchLine: (index: Int, indent: Int)?
        for index in (dispatch.index + 1)..<lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = indentation(of: line)
            if indent == 0 { break }
            if trimmed.hasPrefix("workflow_dispatch:") {
                dispatchLine = (index, indent)
                break
            }
        }
        guard let dispatchLine else { return nil }
        let inputs = parseInputs(in: lines, after: dispatchLine.index, dispatchIndent: dispatchLine.indent)
        return Workflow(name: name, fileName: url.lastPathComponent, inputs: inputs)
    }

    private struct InputBuilder {
        let name: String
        var description = ""
        var kind = WorkflowInput.Kind.string
        var required = false
        var defaultValue = ""
        var options: [String] = []

        func build() -> WorkflowInput {
            WorkflowInput(
                name: name, description: description, kind: kind, required: required,
                defaultValue: defaultValue, options: options
            )
        }
    }

    private static func parseInputs(
        in lines: [String], after dispatchIndex: Int, dispatchIndent: Int
    ) -> [WorkflowInput] {
        guard let inputsIndex = lines.indices.dropFirst(dispatchIndex + 1).first(where: { index in
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return false }
            let indent = indentation(of: lines[index])
            if indent <= dispatchIndent { return true }
            return trimmed == "inputs:"
        }), lines[inputsIndex].trimmingCharacters(in: .whitespaces) == "inputs:"
        else { return [] }
        let inputsIndent = indentation(of: lines[inputsIndex])
        var builders: [InputBuilder] = []
        var inputIndent: Int?
        var readingOptions = false

        for index in (inputsIndex + 1)..<lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = indentation(of: line)
            if indent <= inputsIndent { break }

            if !trimmed.hasPrefix("-"), trimmed.hasSuffix(":"),
               inputIndent == nil || indent == inputIndent
            {
                inputIndent = indent
                let name = String(trimmed.dropLast())
                builders.append(InputBuilder(name: scalar(name)))
                readingOptions = false
                continue
            }
            guard !builders.isEmpty, let currentIndent = inputIndent, indent > currentIndent else { continue }
            if trimmed == "options:" {
                readingOptions = true
                continue
            }
            if readingOptions, trimmed.hasPrefix("-") {
                builders[builders.count - 1].options.append(scalar(String(trimmed.dropFirst())))
                continue
            }
            readingOptions = false
            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<separator])
            let value = scalar(String(trimmed[trimmed.index(after: separator)...]))
            switch key {
            case "description": builders[builders.count - 1].description = value
            case "required": builders[builders.count - 1].required = value == "true"
            case "default": builders[builders.count - 1].defaultValue = value
            case "type":
                builders[builders.count - 1].kind = switch value {
                case "choice": .choice
                case "boolean": .boolean
                default: .string
                }
            default: break
            }
        }
        return builders.map { $0.build() }
    }

    private static func indentation(of line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private static func scalar(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            return String(value.dropFirst().dropLast())
        }
        if value.count >= 2, value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]) }
        return value == "null" || value == "~" ? "" : value
    }

    private actor Cache {
        static let shared = Cache()
        private var cached: [ProjectFolder]?
        private var refreshedAt: ContinuousClock.Instant?
        private var refresh: Task<[ProjectFolder], Never>?

        func projects(onUpdate: @escaping @Sendable ([ProjectFolder]) -> Void) async -> [ProjectFolder] {
            if cached == nil { cached = read() }
            let current = cached ?? []
            if !current.isEmpty { onUpdate(current) }
            if let refreshedAt, refreshedAt.duration(to: .now) < Projects.freshFor, !current.isEmpty {
                return current
            }
            if let refresh { return await refresh.value }
            let task = Task { await Projects.scan(root: Projects.projectsRoot, cached: current) }
            refresh = task
            let found = await task.value
            refresh = nil
            cached = found
            refreshedAt = .now
            write(found)
            return found
        }

        private func read() -> [ProjectFolder] {
            guard let data = try? Data(contentsOf: Projects.cacheURL) else { return [] }
            return (try? JSONDecoder().decode([ProjectFolder].self, from: data)) ?? []
        }

        private func write(_ projects: [ProjectFolder]) {
            let manager = FileManager.default
            let directory = Projects.cacheURL.deletingLastPathComponent()
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(projects) else { return }
            try? data.write(to: Projects.cacheURL, options: .atomic)
        }
    }

    private static var projectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer")
    }

    private static var cacheURL: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        return base.appendingPathComponent("flaneur/projects.json")
    }
}
