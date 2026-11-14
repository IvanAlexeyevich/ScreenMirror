import SwiftUI
import ReplayKit

/// The user taps the real system picker. No private selectors or hidden-button automation.
struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        view.preferredExtension = BroadcastExtensionID.find(in: Bundle.main.builtInPlugInsURL)
            ?? (Bundle.main.bundleIdentifier ?? "org.example.ScreenMirror") + ".Broadcast"
        view.showsMicrophoneButton = false
        return view
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) { }
}
