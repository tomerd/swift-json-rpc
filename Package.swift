// swift-tools-version:4.0

import PackageDescription

var targets: [PackageDescription.Target] = [
    .target(name: "JSONRPC", dependencies: ["NIO", "NIOFoundationCompat"]),
    .target(name: "ServerExample", dependencies: ["JSONRPC"]),
    .target(name: "ClientExample", dependencies: ["JSONRPC"]),
    .target(name: "LightsdDemo", dependencies: ["JSONRPC"]),
    .testTarget(name: "JsonRpcTests", dependencies: ["JSONRPC"]),
]

let package = Package(
    name: "swift-json-rpc",
    products: [
        .library(name: "JSONRPC", targets: ["JSONRPC"]),
        .executable(name: "ServerExample", targets: ["ServerExample"]),
        .executable(name: "ClientExample", targets: ["ClientExample"]),
        .executable(name: "LightsdDemo", targets: ["LightsdDemo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", .upToNextMajor(from: "1.9.5")),
    ],
    targets: targets
)
