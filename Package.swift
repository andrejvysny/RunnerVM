// swift-tools-version:6.1
import PackageDescription

let package = Package(
  name: "RunnerVM",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "runnerd", targets: ["runnerd"]),
    .executable(name: "runnerctl", targets: ["runnerctl"]),
    .executable(name: "vmworker", targets: ["vmworker"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.1"),
    .package(url: "https://github.com/apple/swift-log", from: "1.6.0"),
    .package(url: "https://github.com/apple/swift-nio", from: "2.80.0"),
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    .package(url: "https://github.com/jpsim/Yams", from: "5.1.0"),
  ],
  targets: [
    // Domain: IDs, models, state machines, errors, configuration model. No I/O.
    .target(name: "RunnerCore"),
    .target(name: "RunnerLogging", dependencies: [
      "RunnerCore",
      .product(name: "Logging", package: "swift-log"),
    ]),
    .target(name: "RPC", dependencies: [
      "RunnerCore",
      .product(name: "NIOCore", package: "swift-nio"),
      .product(name: "NIOPosix", package: "swift-nio"),
    ]),
    .target(name: "Persistence", dependencies: [
      "RunnerCore",
      .product(name: "GRDB", package: "GRDB.swift"),
    ]),
    // Only module allowed to import Virtualization.
    .target(name: "VirtualizationCore", dependencies: ["RunnerCore"],
            linkerSettings: [.linkedFramework("Virtualization")]),
    .target(name: "WorkerProtocol", dependencies: ["RunnerCore", "RPC"]),
    .target(name: "GuestControl", dependencies: ["RunnerCore", "RPC"]),
    .target(name: "ImageStore", dependencies: ["RunnerCore", "RunnerLogging"]),
    .target(name: "OCIRegistry", dependencies: ["RunnerCore", "RunnerLogging"]),
    .target(name: "GitHubControl", dependencies: ["RunnerCore", "RunnerLogging"]),
    .target(name: "Scheduler", dependencies: ["RunnerCore"]),
    .target(name: "Metrics", dependencies: ["RunnerCore"]),
    .target(name: "ConfigLoader", dependencies: [
      "RunnerCore",
      .product(name: "Yams", package: "Yams"),
    ]),
    .target(name: "DaemonAPI", dependencies: ["RunnerCore", "RPC", "GuestControl"]),
    .target(name: "Orchestration", dependencies: [
      "RunnerCore", "RunnerLogging", "RPC", "DaemonAPI", "Persistence", "Scheduler",
      "WorkerProtocol", "GuestControl", "ImageStore", "GitHubControl", "Metrics",
    ]),
    .executableTarget(name: "runnerd", dependencies: [
      "Orchestration", "DaemonAPI", "ConfigLoader", "RunnerLogging",
      .product(name: "ArgumentParser", package: "swift-argument-parser"),
    ]),
    .executableTarget(name: "runnerctl", dependencies: [
      "DaemonAPI", "ConfigLoader", "GuestControl",
      .product(name: "ArgumentParser", package: "swift-argument-parser"),
    ]),
    .executableTarget(name: "vmworker", dependencies: [
      "VirtualizationCore", "WorkerProtocol", "RPC", "RunnerLogging",
      .product(name: "ArgumentParser", package: "swift-argument-parser"),
    ]),
    .testTarget(name: "RunnerCoreTests", dependencies: ["RunnerCore"]),
    .testTarget(name: "RPCTests", dependencies: ["RPC"]),
    .testTarget(name: "RunnerLoggingTests", dependencies: ["RunnerLogging"]),
    .testTarget(name: "PersistenceTests", dependencies: ["Persistence"]),
    .testTarget(name: "ConfigLoaderTests", dependencies: ["ConfigLoader"]),
    .testTarget(name: "DaemonAPITests", dependencies: ["DaemonAPI", "GuestControl"]),
    .testTarget(name: "ImageStoreTests", dependencies: ["ImageStore"]),
    .testTarget(name: "SchedulerTests", dependencies: ["Scheduler"]),
    .testTarget(name: "MetricsTests", dependencies: ["Metrics"]),
    .testTarget(name: "GitHubControlTests", dependencies: ["GitHubControl"]),
    .testTarget(name: "OCIRegistryTests", dependencies: ["OCIRegistry", "ImageStore"]),
    .testTarget(name: "WorkerProtocolTests", dependencies: ["WorkerProtocol"]),
    .testTarget(name: "GuestControlTests", dependencies: ["GuestControl", "RPC", "RunnerCore"]),
    .testTarget(name: "OrchestrationTests", dependencies: [
      "Orchestration", "ConfigLoader", "DaemonAPI", "Persistence", "ImageStore", "Scheduler",
      "WorkerProtocol", "GuestControl", "GitHubControl", "RPC", "RunnerCore",
    ]),
    .testTarget(name: "VirtualizationCoreTests", dependencies: ["VirtualizationCore"]),
  ],
  swiftLanguageModes: [.v6]
)
