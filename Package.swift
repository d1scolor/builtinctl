// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "builtinctl",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "builtinctl", targets: ["builtinctl"]),
        .library(name: "BuiltinCtlCore", targets: ["BuiltinCtlCore"]),
    ],
    targets: [
        .target(name: "BuiltinCtlCore"),
        .executableTarget(name: "builtinctl", dependencies: ["BuiltinCtlCore"]),
        .testTarget(name: "BuiltinCtlCoreTests", dependencies: ["BuiltinCtlCore"]),
    ]
)
