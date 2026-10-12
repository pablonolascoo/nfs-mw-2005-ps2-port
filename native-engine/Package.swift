// swift-tools-version:5.9
// Rockport: motor nativo macOS (AppKit + MetalKit) para los datos convertidos de NFS Most Wanted (PS2).
import PackageDescription

let package = Package(
    name: "Rockport",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Rockport",
            path: "Sources/Rockport",
            linkerSettings: [
                .linkedFramework("AppKit"), .linkedFramework("Metal"), .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"), .linkedFramework("ImageIO"), .linkedFramework("CoreGraphics"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
