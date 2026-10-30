// swift-tools-version: 6.2
// Build through scripts/build-app.sh or scripts/swift-test.sh: they build libxs_core.a first.
import PackageDescription

let rustLib = Context.packageDirectory + "/target/release"

let package = Package(
    name: "XSearch",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "XSearch", targets: ["XSearch"])],
    targets: [
        .target(
            name: "CXSearchCore",
            path: "Packages/XSearchCore/CXSearchCore",
            linkerSettings: [.unsafeFlags(["-L\(rustLib)"]), .linkedLibrary("xs_core"), .linkedLibrary("c++"), .linkedLibrary("z")]
        ),
        .target(name: "XSearchCore", dependencies: ["CXSearchCore"], path: "Packages/XSearchCore/Sources"),
        .target(name: "CScan", path: "Packages/NameEngine/CScan", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "NameEngine", dependencies: ["XSearchCore", "CScan"], path: "Packages/NameEngine/Sources"),
        .target(name: "Catalog", dependencies: ["XSearchCore", "NameEngine", "CScan"], path: "Packages/Catalog/Sources", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "XSearch", dependencies: ["XSearchCore", "NameEngine", "Catalog"], path: "App/Sources"),
        .testTarget(name: "XSearchCoreTests", dependencies: ["XSearchCore"], path: "Packages/XSearchCore/Tests"),
        .testTarget(name: "NameEngineTests", dependencies: ["NameEngine"], path: "Packages/NameEngine/Tests"),
        .testTarget(name: "CatalogTests", dependencies: ["Catalog"], path: "Packages/Catalog/Tests"),
    ],
    swiftLanguageModes: [.v6]
)
