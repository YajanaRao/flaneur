import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import FlaneurKit

struct ProjectTests {
    @Test func githubRemotesBecomeRepositoryLinks() {
        let expected = GitHubRepository(
            nameWithOwner: "Humanisys/bento", url: URL(string: "https://github.com/Humanisys/bento")!
        )
        #expect(Projects.repository(remote: "https://github.com/Humanisys/bento.git") == expected)
        #expect(Projects.repository(remote: "git@github.com:Humanisys/bento.git") == expected)
        #expect(Projects.repository(remote: "ssh://git@github.com/Humanisys/bento.git") == expected)
        #expect(Projects.repository(remote: "https://gitlab.com/Humanisys/bento.git") == nil)
    }

    @Test func workflowComesFromDiskWithItsDispatchInputs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("deploy.yml")
        let yaml = """
        name: Deploy to S3
        on:
          push:
            branches: [main]
          workflow_dispatch:
            inputs:
              app:
                description: App to deploy
                required: true
                type: choice
                options:
                  - all
                  - web
              delete:
                description: Delete missing objects
                required: false
                type: boolean
                default: false
        jobs:
          deploy:
            runs-on: ubuntu-latest
        """
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let workflow = try #require(Projects.parseWorkflow(at: file))
        #expect(workflow.name == "Deploy to S3")
        #expect(workflow.fileName == "deploy.yml")
        #expect(workflow.inputs.count == 2)
        #expect(workflow.inputs[0].name == "app")
        #expect(workflow.inputs[0].kind == .choice)
        #expect(workflow.inputs[0].required)
        #expect(workflow.inputs[0].options == ["all", "web"])
        #expect(workflow.inputs[1].name == "delete")
        #expect(workflow.inputs[1].kind == .boolean)
        #expect(workflow.inputs[1].defaultValue == "false")

        let automatic = directory.appendingPathComponent("ci.yml")
        try "name: CI\non: [push, pull_request]\n".write(to: automatic, atomically: true, encoding: .utf8)
        #expect(Projects.parseWorkflow(at: automatic) == nil)
    }

    @Test func foldersGainActionsFromTheirRepository() {
        let repository = GitHubRepository(
            nameWithOwner: "Humanisys/bento", url: URL(string: "https://github.com/Humanisys/bento")!
        )
        let workflow = Workflow(name: "CI", fileName: "ci.yml")
        let project = ProjectFolder(
            url: URL(fileURLWithPath: "/Developer/bento"), repository: repository,
            branch: "dev", branches: ["dev"], workflows: [workflow]
        )
        #expect(Item.project(project).actions.map(\.chord) == [.enter, .runWorkflow, .open, .yank])
        #expect(Item.project(project).actions.map(\.title) == ["Open", "Run Workflow", "Open on GitHub", "Copy Link"])
        #expect(Item.project(project).subtitle == "Humanisys/bento · 1 workflow")
        #expect(Item.project(project).icon == .bundled("GitHubMark"))
        #expect(Item.project(project).icon.template)

        let folder = ProjectFolder(url: URL(fileURLWithPath: "/Developer/notes"))
        #expect(Item.project(folder).actions.map(\.chord) == [.enter])
        #expect(Item.project(folder).icon == .file(folder.url.path))
        #expect(Item.project(folder).primary == .folder(folder.url))
    }

    @Test func githubScopeListsOnlyRepositories() {
        let repository = GitHubRepository(
            nameWithOwner: "Humanisys/bento", url: URL(string: "https://github.com/Humanisys/bento")!
        )
        let project = ProjectFolder(url: URL(fileURLWithPath: "/Developer/bento"), repository: repository)
        let folder = ProjectFolder(url: URL(fileURLWithPath: "/Developer/notes"))
        var state = LauncherState()
        _ = state.handle(.toggle)
        _ = state.handle(.collected(.projects, generation: 1, .projects([project, folder])))
        #expect(state.rows.isEmpty)
        _ = state.handle(.query("g"))
        #expect(state.rows.map(\.title) == ["bento"])
    }

    @Test func githubHandoffClearsThePrefixAndSearchesWithinRepositories() {
        let repository = GitHubRepository(
            nameWithOwner: "Humanisys/bento", url: URL(string: "https://github.com/Humanisys/bento")!
        )
        let project = ProjectFolder(url: URL(fileURLWithPath: "/Developer/bento"), repository: repository)
        let other = ProjectFolder(
            url: URL(fileURLWithPath: "/Developer/tofu"),
            repository: GitHubRepository(nameWithOwner: "Humanisys/tofu", url: URL(string: "https://github.com/Humanisys/tofu")!)
        )
        var state = LauncherState()
        _ = state.handle(.toggle)
        _ = state.handle(.collected(.projects, generation: 1, .projects([project, other])))
        _ = state.handle(.query("g "))
        #expect(state.query == "")
        #expect(state.prompt == "Search GitHub repositories")
        #expect(state.rows.map(\.title) == ["bento", "tofu"])
        _ = state.handle(.query("bento"))
        #expect(state.rows.map(\.title) == ["bento"])
        _ = state.handle(.backspace)
        #expect(state.rows.map(\.title) == ["bento"])
        _ = state.handle(.clearLine)
        _ = state.handle(.backspace)
        #expect(state.prompt == "Search")
    }

    @Test func controlROpensWorkflowsAndBranchSelectionDispatches() {
        let repository = GitHubRepository(
            nameWithOwner: "Humanisys/bento", url: URL(string: "https://github.com/Humanisys/bento")!
        )
        let workflow = Workflow(name: "CI", fileName: "ci.yml")
        let project = ProjectFolder(
            url: URL(fileURLWithPath: "/Developer/bento"), repository: repository,
            branch: "dev", branches: ["dev", "main"], workflows: [workflow]
        )
        var state = LauncherState()
        _ = state.handle(.toggle)
        _ = state.handle(.collected(.projects, generation: 1, .projects([project])))
        _ = state.handle(.query("bento"))

        #expect(state.handle(.runWorkflow) == [])
        #expect(state.phase == .visible(.settling))
        #expect(state.rows.map(\.title) == ["CI"])
        #expect(state.prompt == "bento · Select workflow")

        _ = state.handle(.submit)
        #expect(state.rows.map(\.title) == ["dev", "main"])
        #expect(state.rows.map(\.badge) == ["current", ""])
        #expect(state.footer.map(\.title) == ["Run Workflow"])

        let effects = state.handle(.submit)
        #expect(effects == [
            .dismiss(restoreFocus: false),
            .perform(.githubWorkflow(project: project, workflow: workflow, branch: "dev", inputs: [:]), generation: 1),
        ])
        #expect(state.phase == .hidden)
    }

    @Test func requiredChoicesAndTextBecomeDynamicSteps() {
        let repository = GitHubRepository(
            nameWithOwner: "Humanisys/naan", url: URL(string: "https://github.com/Humanisys/naan")!
        )
        let environment = WorkflowInput(
            name: "environment", description: "Environment", kind: .choice, required: true,
            options: ["dev", "stage"]
        )
        let version = WorkflowInput(name: "version", description: "Version", required: true)
        let workflow = Workflow(name: "Deploy", fileName: "deploy.yml", inputs: [environment, version])
        let project = ProjectFolder(
            url: URL(fileURLWithPath: "/Developer/naan"), repository: repository,
            branch: "dev", branches: ["dev"], workflows: [workflow]
        )
        var state = LauncherState()
        _ = state.handle(.toggle)
        _ = state.handle(.collected(.projects, generation: 1, .projects([project])))
        _ = state.handle(.query("naan"))
        _ = state.handle(.runWorkflow)
        _ = state.handle(.submit)
        _ = state.handle(.submit)

        #expect(state.rows.map(\.title) == ["dev", "stage"])
        _ = state.handle(.submit)
        #expect(state.rows.isEmpty)
        _ = state.handle(.query("v1.2.3"))
        #expect(state.rows.map(\.title) == ["v1.2.3"])

        let effects = state.handle(.submit)
        #expect(effects == [
            .dismiss(restoreFocus: false),
            .perform(.githubWorkflow(
                project: project, workflow: workflow, branch: "dev",
                inputs: ["environment": "dev", "version": "v1.2.3"]
            ), generation: 1),
        ])
    }

    @Test func escapeWalksBackThroughTheWorkflowPicker() {
        let repository = GitHubRepository(
            nameWithOwner: "Humanisys/bento", url: URL(string: "https://github.com/Humanisys/bento")!
        )
        let workflow = Workflow(name: "CI", fileName: "ci.yml")
        let project = ProjectFolder(
            url: URL(fileURLWithPath: "/Developer/bento"), repository: repository,
            branches: ["main"], workflows: [workflow]
        )
        var state = LauncherState()
        _ = state.handle(.toggle)
        _ = state.handle(.collected(.projects, generation: 1, .projects([project])))
        _ = state.handle(.query("bento"))
        _ = state.handle(.runWorkflow)
        _ = state.handle(.submit)
        #expect(state.rows.map(\.title) == ["main"])

        _ = state.handle(.escape)
        #expect(state.rows.map(\.title) == ["CI"])
        _ = state.handle(.escape)
        #expect(state.query == "bento")
        #expect(state.rows.map(\.title) == ["bento"])
        #expect(state.handle(.escape) == [.dismiss(restoreFocus: true)])
    }

    @Test func dispatchUsesTheFilenameRepositoryBranchAndFields() {
        let repository = GitHubRepository(
            nameWithOwner: "Humanisys/sashimi", url: URL(string: "https://github.com/Humanisys/sashimi")!
        )
        let input = WorkflowInput(name: "app", kind: .choice, required: true, options: ["all", "web"])
        let workflow = Workflow(name: "Deploy to S3", fileName: "deploy.yml", inputs: [input])
        let project = ProjectFolder(url: URL(fileURLWithPath: "/Developer/sashimi"), repository: repository)
        #expect(Projects.dispatchArguments(workflow, project: project, branch: "main", inputs: ["app": "web"]) == [
            "workflow", "run", "deploy.yml", "--repo", "Humanisys/sashimi", "--ref", "main",
            "--raw-field", "app=web",
        ])
    }

    @Test func controlRIsDistinctFromCommandR() {
        #expect(Key(event: projectKeyEvent(15, .control)) == .runWorkflow)
        #expect(Key(event: projectKeyEvent(15, .command)) == .restart)
    }
}

private func projectKeyEvent(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: keyCode
    )!
}
