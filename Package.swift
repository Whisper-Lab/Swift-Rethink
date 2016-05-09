import PackageDescription

let package = Package(
    name: "Rethink",
    targets: [Target(name: "Rethink")],
    exclude: ["Rethink.xcodeproj", "Rethink.xcworkspace", "README.md", "LICENSE", "Sources/Info.plist", "Tests"]
)
