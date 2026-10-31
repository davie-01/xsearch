// swift-tools-version: 6.2
// Build through scripts/build-app.sh or scripts/swift-test.sh: they build libxs_core.a first.
import PackageDescription

let rustLib = Context.packageDirectory + "/target/release"
/// Sparkle.framework (auto-update), fetched by scripts/fetch-sparkle.sh; embedded by build-app.sh.
let sparkle = Context.packageDirectory + "/.tools/sparkle-2.10.0"

let package = Package(
    name: "XSearch",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "XSearch", targets: ["XSearch"]), .executable(name: "xs-extract", targets: ["xs-extract"]),
               .executable(name: "IndexService", targets: ["IndexService"])],
    targets: [
        .target(
            name: "CXSearchCore",
            path: "Packages/XSearchCore/CXSearchCore",
            // libxs_ffi.a is the app's only Rust library (content engine + M1 name-key C ABI);
            // linking two Rust static libraries would duplicate the Rust runtime.
            // Full path: target/release also holds libxs_ffi.dylib (for uniffi-bindgen), which
            // `-lxs_ffi` would prefer over the static archive.
            linkerSettings: [.unsafeFlags(["\(rustLib)/libxs_ffi.a"]), .linkedLibrary("c++"), .linkedLibrary("z")]
        ),
        .target(name: "xs_ffiFFI", dependencies: ["CXSearchCore"], path: "Packages/ContentEngine/xs_ffiFFI"),
        // Generated UniFFI bindings (scripts/gen-bindings.sh) plus a thin Swift layer.
        .target(name: "ContentEngine", dependencies: ["xs_ffiFFI"], path: "Packages/ContentEngine/Sources",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "XSearchCore", dependencies: ["CXSearchCore"], path: "Packages/XSearchCore/Sources"),
        .target(name: "CScan", path: "Packages/NameEngine/CScan", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "NameEngine", dependencies: ["XSearchCore", "CScan"], path: "Packages/NameEngine/Sources"),
        .target(name: "Catalog", dependencies: ["XSearchCore", "NameEngine", "CScan", "ContentEngine", "Extraction"], path: "Packages/Catalog/Sources", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "Extraction", dependencies: ["ContentEngine", "XSearchCore"], path: "Packages/Extraction/Sources"),
        // Extraction worker process (killable on timeout / crash); bundled into the app.
        .executableTarget(name: "xs-extract", dependencies: ["Extraction"], path: "Packages/Extraction/Worker"),
        .executableTarget(name: "IndexService", dependencies: ["Catalog"], path: "Packages/IndexService"),
        .executableTarget(name: "XSearch", dependencies: ["XSearchCore", "NameEngine", "Catalog", "ContentEngine", "Extraction"], path: "App/Sources",
                          swiftSettings: [.unsafeFlags(["-F", sparkle])],
                          linkerSettings: [.unsafeFlags(["-F", sparkle, "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "XSearchCoreTests", dependencies: ["XSearchCore"], path: "Packages/XSearchCore/Tests"),
        .testTarget(name: "NameEngineTests", dependencies: ["NameEngine"], path: "Packages/NameEngine/Tests"),
        .testTarget(name: "CatalogTests", dependencies: ["Catalog", "ContentEngine", "xs-extract"], path: "Packages/Catalog/Tests"),
        .testTarget(name: "ContentEngineTests", dependencies: ["ContentEngine"], path: "Packages/ContentEngine/Tests"),
        .testTarget(name: "ExtractionTests", dependencies: ["Extraction", "xs-extract"], path: "Packages/Extraction/Tests"),
    ],
    swiftLanguageModes: [.v6]
)
