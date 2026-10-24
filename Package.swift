// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Neovlet",
  platforms: [.macOS(.v15)],
  products: [.executable(name: "Neovlet", targets: ["Neovlet"])],
  targets: [
    .executableTarget(name: "Neovlet"),
    .testTarget(
      name: "NeovletTests", dependencies: ["Neovlet"],
      path: "tests/NeovletTests"),
  ]
)
