// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "TermiFreedom", platforms: [.macOS(.v14)], products: [.executable(name: "TermiFreedom", targets: ["TermiFreedom"])], dependencies: [.package(path: "Vendor/SwiftTerm")], targets: [.target(name: "TermiFreedomCore"), .executableTarget(name: "TermiFreedom", dependencies: ["TermiFreedomCore", "SwiftTerm"]), .testTarget(name: "TermiFreedomCoreTests", dependencies: ["TermiFreedomCore"])], swiftLanguageModes: [.v5])
