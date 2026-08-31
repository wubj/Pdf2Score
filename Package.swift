// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Pdf2Score",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Pdf2Score",
            path: "Sources/Pdf2Score"
        )
    ]
)
