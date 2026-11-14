// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ScreenMirrorCore", products: [.library(name: "MirrorCore", targets: ["MirrorCore"])], targets: [
    .target(name: "MirrorCore", path: ".", exclude: ["CoreTests", "Tests", "Fixtures", "research", "docs", "tools", "Config", "ScreenMirror.xcodeproj", "README.md", "project.yml", "App/BroadcastPicker.swift", "App/HTTPServer.swift", "App/Model.swift", "App/ScreenMirrorApp.swift", "App/MirrorHomeView.swift", "App/DevicePickerView.swift", "Broadcast/MediaPipeline.swift", "Broadcast/SampleHandler.swift"], sources: ["Shared", "App/UPnP.swift", "Broadcast/TransportStream.swift"]),
    .testTarget(name: "MirrorCoreTests", dependencies: ["MirrorCore"], path: "CoreTests")
])
