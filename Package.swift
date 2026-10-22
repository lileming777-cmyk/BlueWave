// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "BlueWave", platforms: [.macOS(.v14)], products: [.library(name: "BlueWaveCore", targets: ["BlueWaveCore"]), .executable(name: "BlueWave", targets: ["BlueWave"])], targets: [.target(name: "BlueWaveCore"), .executableTarget(name: "BlueWave", dependencies: ["BlueWaveCore"]), .testTarget(name: "BlueWaveCoreTests", dependencies: ["BlueWaveCore", "BlueWave"])])
