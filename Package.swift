// swift-tools-version:5.9
import PackageDescription

// The package holds the testable core (Foundation, plus CryptoKit for PKCE).
// The macOS app target lives in DeviceOffboarding.xcodeproj.
let package = Package(
    name: "IntuneOffboarding",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OffboardingCore", targets: ["OffboardingCore"]),
    ],
    targets: [
        .target(name: "OffboardingCore"),
        .testTarget(name: "OffboardingCoreTests", dependencies: ["OffboardingCore"]),
    ]
)
