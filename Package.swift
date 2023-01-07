// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftNetworkTables",
    platforms: [
        .macOS(.v11),
        .iOS(.v13)
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "SwiftNetworkTables",
            targets: ["SwiftNetworkTables"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url s*/, from: "1.0.0"),
        .package(url: "https://github.com/daltoniam/Starscream", from: "4.0.0"),
        .package(url: "https://github.com/swiftstack/messagepack", branch: "dev"),
        .package(url: "https://github.com/iwill/generic-json-swift", branch: "master")
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "SwiftNetworkTables",
            dependencies: [
                .product(name: "Starscream", package: "Starscream"),
                .product(name: "GenericJSON", package: "generic-json-swift"),
                .product(name: "MessagePack", package: "messagepack"),
            ]),
        .testTarget(
            name: "SwiftNetworkTablesTests",
            dependencies: ["SwiftNetworkTables"]),
    ]
)
