import SwiftUI
import UIKit

struct MirrorHomeView: View {
    @ObservedObject var model: Model
    @State private var devices = false
    @State private var settings = false
    @State private var diagnostics = false
    private let accent = Color(red: 0.28, green: 0.40, blue: 0.98)
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Ваш экран. На большом.")
                        .font(.largeTitle.bold()).padding(.top, 14)
                    Text("iPhone и телевизор должны быть в одной сети Wi-Fi.")
                        .foregroundStyle(.secondary)
                    receiverCard
                    broadcastCard
                    HStack(spacing: 8) {
                        Label(model.resolution, systemImage: "sparkles")
                        Spacer(); Text("\(model.fps) FPS"); Spacer()
                        Text("\(model.bitrate / 1_000_000) Мбит/с")
                    }.font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Text("Выбранный телевизор и настройки сохраняются на этом iPhone.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Диагностика и проверка подключения") { diagnostics = true }
                        .font(.footnote)
                    Text("Версия \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }.padding(24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Screen Mirror").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { settings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Настройки трансляции")
                }
            }
            .tint(accent)
            .sheet(isPresented: $devices) { DevicePickerView(model: model) }
            .sheet(isPresented: $settings) { MirrorSettingsView(model: model) }
            .sheet(isPresented: $diagnostics) { MirrorDiagnosticsView(model: model) }
        }
    }
    private var receiverCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Image(systemName: "tv").font(.system(size: 30)).foregroundStyle(accent)
                    .frame(width: 64, height: 64).background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.selected?.name ?? "Выберите телевизор").font(.headline)
                    Text(model.selected.map { model.onlineIDs.contains($0.id) ? "Доступен в вашей сети" : "Сохранён на этом iPhone" } ?? "Найдём устройства поблизости")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.busy { HStack { ProgressView(); Text(model.status).font(.footnote) } }
            else { Text(model.status).font(.footnote).foregroundStyle(.secondary) }
            Button { devices = true } label: {
                HStack { Text(model.selected == nil ? "Найти телевизор" : "Другой телевизор"); Spacer(); Image(systemName: "chevron.right") }
            }.disabled(model.prepared)
        }.padding(20).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }
    private var broadcastCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(model.broadcasting ? "Захват экрана активен" : "Готовы показать экран?", systemImage: model.broadcasting ? "record.circle" : "rectangle.on.rectangle")
                .font(.headline)
            if model.prepared {
                if !model.broadcasting {
                    HStack(spacing: 16) {
                        BroadcastPicker().frame(width: 60, height: 60)
                        Text("Нажмите системную кнопку и подтвердите начало трансляции.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Text(model.mirrorStatus).font(.caption).foregroundStyle(.secondary)
                Button(role: .destructive) { Task { await model.stopBroadcast() } } label: {
                    Label("Остановить трансляцию", systemImage: "stop.fill").frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.bordered)
            } else {
                Text("Выберите телевизор, затем подтвердите запись экрана в iOS.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button { Task { await model.prepareBroadcast() } } label: {
                    Label("Начать трансляцию", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 10)
                }.buttonStyle(.borderedProminent).disabled(model.selected == nil || model.busy)
            }
        }.padding(20).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }
}

struct MirrorSettingsView: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                if model.prepared { Text("Чтобы изменить настройки, сначала остановите трансляцию.").font(.footnote) }
                Section("Изображение") {
                    Picker("Качество", selection: $model.resolution) { Text("720p").tag("720p"); Text("1080p").tag("1080p") }
                    Picker("Частота кадров", selection: $model.fps) { Text("15 FPS").tag(15); Text("30 FPS").tag(30) }
                    Picker("Битрейт", selection: $model.bitrate) {
                        ForEach([2,3,4,6,8,12], id: \.self) { rate in Text("\(rate) Мбит/с").tag(rate * 1_000_000) }
                    }
                    Toggle("Исправлять альбомный переворот", isOn: $model.correctLandscapeFlip)
                }.disabled(model.prepared)
                Section {
                    Toggle("Передавать звук", isOn: $model.audio)
                    Toggle("Переподключать телевизор", isOn: $model.reconnect)
                    Toggle("Ровная подача потока", isOn: $model.steadyStream)
                } footer: {
                    Text("Ровная подача заполняет паузы служебными пакетами без ухудшения изображения. Может уменьшить буферизацию TV, но увеличивает расход Wi-Fi. Внутренний буфер телевизора приложение не настраивает.")
                }.disabled(model.prepared)
                Section("Дополнительно") {
                    Picker("Передача", selection: $model.transport) { Text("Напрямую — Samsung").tag("ts"); Text("HLS").tag("hls") }
                }.disabled(model.prepared)
                Section { Text("Настройки сохраняются автоматически. Для 1080p начните с 8 Мбит/с. Защищённый контент может не передавать изображение или звук.").font(.footnote) }
            }.navigationTitle("Настройки").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }
}

struct MirrorDiagnosticsView: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Проверка телевизора") {
                    Button("Прочитать поддерживаемые форматы") { Task { await model.connect() } }
                    Toggle("Тест HLS (иначе MPEG-TS)", isOn: $model.live)
                    Button("Запустить видео и тон") { Task { await model.test() } }
                    Button("Остановить тест") { Task { await model.stop() } }
                }.disabled(model.selected == nil || model.prepared || model.busy)
                Section("Журнал") {
                    ShareLink("Экспортировать журнал", item: model.diagnostics)
                    Text(model.diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }.navigationTitle("Диагностика").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }
}
