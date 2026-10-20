// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SerialTerm",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SerialTerm", targets: ["SerialTerm"]),
        .library(name: "SerialCore", targets: ["SerialCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        // Portable core: serial I/O, logging, transfer plumbing. No AppKit/SwiftUI.
        .target(name: "SerialCore"),
        // macOS app: SwiftUI + SwiftTerm + IOKit port discovery.
        .executableTarget(
            name: "SerialTerm",
            dependencies: [
                "SerialCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .testTarget(name: "SerialCoreTests", dependencies: ["SerialCore"]),
    ],
    swiftLanguageModes: [.v5]
)
