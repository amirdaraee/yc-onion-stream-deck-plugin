// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "YCOnion",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "yc-onion", targets: ["YCOnion"]),
    ],
    targets: [
        .executableTarget(
            name: "YCOnion",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "YCOnionTests",
            dependencies: ["YCOnion"]
        ),
    ]
)
