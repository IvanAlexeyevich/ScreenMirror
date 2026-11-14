import SwiftUI
import UIKit
import VisionKit

struct DevicePickerView: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var camera = false
    @State private var cameraError: String?
    @State private var manual = false
    var body: some View {
        NavigationStack {
            List {
                Section("Телевизоры") {
                    ForEach(model.devices) { tv in
                        Button {
                            model.selected = tv; dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "tv")
                                VStack(alignment: .leading) {
                                    Text(tv.name); Text(tv.model).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.selected?.id == tv.id { Image(systemName: "checkmark.circle.fill") }
                            }
                        }.disabled(model.prepared || model.busy)
                    }
                    Button { Task { await model.scan() } } label: {
                        HStack { if model.busy { ProgressView() }; Text(model.busy ? "Ищем…" : "Найти телевизор") }
                    }.disabled(model.busy || model.prepared)
                    Text(model.status).font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button { camera = true } label: { Label("Подключить по QR-коду", systemImage: "qrcode.viewfinder") }
                        .disabled(model.busy || model.prepared)
                } footer: { Text("Если поиск не находит TV, QR-код можно создать нашим помощником на Mac в той же Wi-Fi сети. Достаточно подключить один раз.") }
                Section {
                    DisclosureGroup("Ввести адрес вручную", isExpanded: $manual) {
                        TextField("http://…", text: $model.manualURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        Button("Сохранить телевизор") {
                            if let url = PairingCode.url(from: model.manualURL) { Task { await model.add(url) } }
                            else { cameraError = "Нужен полный адрес описания устройства, начинающийся с http:// или https://" }
                        }.disabled(model.busy || model.prepared)
                    }
                    if model.selected != nil {
                        Button("Забыть выбранный телевизор", role: .destructive) { model.forgetSelected() }.disabled(model.prepared)
                    }
                    Link("Настройки доступа к локальной сети", destination: URL(string: UIApplication.openSettingsURLString)!)
                }
            }.navigationTitle("Подключение").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
                .sheet(isPresented: $camera) {
                    NavigationStack {
                        QRPairingScanner { text in
                            camera = false
                            if let url = PairingCode.url(from: text) { Task { await model.add(url) } }
                            else { cameraError = "Этот QR-код не содержит адрес телевизора Screen Mirror" }
                        } onError: { message in camera = false; cameraError = message }
                            .navigationTitle("Наведите на QR-код")
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { camera = false } } }
                    }
                }
                .alert("Подключение", isPresented: Binding(get: { cameraError != nil }, set: { if !$0 { cameraError = nil } })) {
                    Button("OK") { cameraError = nil }
                } message: { Text(cameraError ?? "") }
        }
    }
}

struct QRPairingScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    var onError: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode, onError: onError) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        DispatchQueue.main.async {
            guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
                onError("Сканер недоступен. Проверьте разрешение камеры в настройках iPhone."); return
            }
            do { try scanner.startScanning() } catch { onError(error.localizedDescription) }
        }
        return scanner
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) { }
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { controller.stopScanning() }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        let onError: (String) -> Void
        private var completed = false
        init(onCode: @escaping (String) -> Void, onError: @escaping (String) -> Void) { self.onCode = onCode; self.onError = onError }
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !completed else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let text = code.payloadStringValue {
                    completed = true; scanner.stopScanning(); onCode(text); break
                }
            }
        }
        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            guard !completed else { return }; completed = true; onError("Камера недоступна: \(error.localizedDescription)")
        }
    }
}
