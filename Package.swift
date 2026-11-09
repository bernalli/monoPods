// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "monoPods",
  platforms: [.macOS("14.2")],
  products: [
    .library(name: "MonoPodsCore", targets: ["MonoPodsCore"]),
    .library(name: "MonoPodsReportCLI", targets: ["MonoPodsReportCLI"]),
    .library(name: "MonoPodsRuntime", targets: ["MonoPodsRuntime"]),
    .executable(name: "MonoPods", targets: ["MonoPods"]),
    .executable(name: "monopods-report", targets: ["MonoPodsReport"]),
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
  ],
  targets: [
    .target(name: "MonoPodsCore"),
    .target(name: "MonoPodsRuntime", dependencies: ["MonoPodsCore"]),
    .executableTarget(
      name: "MonoPods",
      dependencies: ["MonoPodsRuntime", .product(name: "Sparkle", package: "Sparkle")],
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
      ]),
    .testTarget(
      name: "MonoPodsRuntimeTests", dependencies: ["MonoPodsRuntime"],
      path: "Tests/MonoPodsRuntimeTests"),
    .target(name: "MonoPodsReportCLI", dependencies: ["MonoPodsCore"]),
    .executableTarget(
      name: "MonoPodsReport", dependencies: ["MonoPodsCore", "MonoPodsReportCLI"]),
    .testTarget(
      name: "MonoPodsCoreTests", dependencies: ["MonoPodsCore", "MonoPodsReportCLI"], path: "Tests",
      exclude: ["MonoPodsRuntimeTests"], resources: [.copy("Fixtures")]),
  ],
  swiftLanguageModes: [.v6]
)
