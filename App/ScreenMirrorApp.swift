import SwiftUI

@main struct ScreenMirrorApp: App {
    @StateObject private var model = Model()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            MirrorHomeView(model: model)
                .task { await model.scan() }
                .onOpenURL { link in
                    if let url = PairingCode.url(from: link.absoluteString) { Task { await model.add(url) } }
                }
        }.onChange(of: phase) { value in
            if value == .background { Task { await model.stop() } }
        }
    }
}
