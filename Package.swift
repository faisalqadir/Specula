// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Specula",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Specula", targets: ["SpeculaApp"]),
        .executable(name: "speculatool", targets: ["speculatool"]),
        .library(name: "DICOMCore", targets: ["DICOMCore"]),
        .library(name: "DICOMNet", targets: ["DICOMNet"]),
    ],
    targets: [
        .target(
            name: "DICOMCore",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        .target(name: "DICOMNet", dependencies: ["DICOMCore"]),
        .executableTarget(
            name: "SpeculaApp",
            dependencies: ["DICOMCore", "DICOMNet"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "speculatool", dependencies: ["DICOMCore", "DICOMNet"]),
        .testTarget(name: "DICOMCoreTests", dependencies: ["DICOMCore", "DICOMNet"]),
    ],
    swiftLanguageModes: [.v5]
)
