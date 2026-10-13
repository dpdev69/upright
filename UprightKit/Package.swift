// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UprightKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "UprightKit", targets: ["UprightKit"]),
        .executable(name: "upright-probe", targets: ["upright-probe"]),
    ],
    targets: [
        .target(name: "UprightKit"),
        .executableTarget(name: "upright-probe", dependencies: ["UprightKit"]),
        .testTarget(name: "UprightKitTests", dependencies: ["UprightKit"]),
    ]
)
