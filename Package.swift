import PackageDescription

let package = Package(
    name: "Rethink",
    targets: [
        Target(
            name: "SCRAM"
        ),
        Target(
            name: "Rethink",
            dependencies: [.Target(name: "SCRAM")]
        )
    ],
    dependencies: [
        .Package(url: "https://github.com/IBM-Swift/BlueSocket.git", majorVersion: 0, minor: 5)
    ],
    exclude: ["Rethink.xcodeproj", "Rethink.xcworkspace", "README.md", "LICENSE", "Sources/Info.plist", "Tests"]
)
