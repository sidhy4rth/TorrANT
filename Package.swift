// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TorrANT",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TorrANT",
            path: "Sources/TorrANT",
            exclude: ["Resources"]
        ),
        // Brave's native-messaging helper, bundled as Contents/MacOS/torrant-catch
        .executableTarget(
            name: "TorrANTCatch",
            path: "Sources/TorrANTCatch"
        ),
    ]
)
