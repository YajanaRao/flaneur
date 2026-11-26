// swift-tools-version:5.9
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let infoPlist = packageRoot.appendingPathComponent("Resources/Info.plist").path

func selectedDeveloperDir() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["-p"]
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return "/Library/Developer/CommandLineTools" }
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return path.isEmpty ? "/Library/Developer/CommandLineTools" : path
}

let developerDir = selectedDeveloperDir()

// The generated test runner searches this directory with -I, not -F, so it never
// sees Testing.framework. XCTest is not in this Command Line Tools install.
let testingModule = URL(fileURLWithPath: developerDir)
    .appendingPathComponent("Library/Developer/Frameworks/Testing.framework/Modules/Testing.swiftmodule")
let modulesDir = packageRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/Modules")
let testingLink = modulesDir.appendingPathComponent("Testing.swiftmodule")
let link = Process()
link.executableURL = URL(fileURLWithPath: "/bin/sh")
link.arguments = [
    "-c", "mkdir -p \"$1\" && ln -sfn \"$2\" \"$3\"",
    "sh", modulesDir.path, testingModule.path, testingLink.path,
]
link.standardOutput = FileHandle.nullDevice
link.standardError = FileHandle.nullDevice
try? link.run()
link.waitUntilExit()

let package = Package(
    name: "flaneur",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "flaneur", targets: ["flaneur"])
    ],
    targets: [
        .target(
            name: "FlaneurKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "flaneur",
            dependencies: ["FlaneurKit"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlist,
                ])
            ]
        ),
        .testTarget(
            name: "FlaneurTests",
            dependencies: ["FlaneurKit"],
            swiftSettings: [
                .unsafeFlags([
                    "-F", "\(developerDir)/Library/Developer/Frameworks",
                    "-plugin-path", "\(developerDir)/usr/lib/swift/host/plugins/testing",
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "\(developerDir)/Library/Developer/Frameworks",
                    "-framework", "Testing",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "\(developerDir)/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "\(developerDir)/Library/Developer/usr/lib",
                ])
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
