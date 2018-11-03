// swift-tools-version:4.0

import PackageDescription

var targets: [PackageDescription.Target] = [
    .target(name: "JSONRPC", dependencies: ["NIO", "NIOFoundationCompat"]),
    .target(name: "ExampleServer", dependencies: ["JSONRPC"]),
    .target(name: "ExampleClient", dependencies: ["JSONRPC"]),
    .testTarget(name: "JsonRpcTests", dependencies: ["JSONRPC"]),
]

let package = Package(
    name: "swift-json-rpc",
    products: [
        .library(name: "JSONRPC", targets: ["JSONRPC"]),
        .executable(name: "ExampleServer", targets: ["ExampleServer"]),
        .executable(name: "ExampleClient", targets: ["ExampleClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", .upToNextMajor(from: "1.9.5")),
    ],
    targets: targets
)
