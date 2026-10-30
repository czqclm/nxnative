// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json, which build_ipa.sh writes for this game
// from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts. A variable an env file set (Documents/env.txt, the bundle's
// dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) is shown but kept. All settings share one screen, grouped by section (rows: LauncherRow.swift). Choices that differ from the game's default are kept
// in UserDefaults; Reset to tested defaults shows the defaults, and Play then forgets them. DM_LAUNCHER=0 in Documents/env.txt starts the game at once with the saved choices; DM_SAVED_CHOICES=0 ignores them (and keeps them)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }


/// Cloud saves: an iCloud Drive folder shared with the Mac app (chosen in its settings window's
/// Cloud saves too). The host brings the save in from there when the game starts and
/// sends it there after each save (dm/host/save_sync.h); the folder is a bookmark (CloudSaves.m).
private struct CloudSavesSection: View {
    @State private var folder: String = ""
    @State private var note: String = ""
    @State private var picking = false

    var body: some View {
        Section {
            HStack {
                Text("云存档")
                Spacer()
                Text(folder.isEmpty ? "关闭" : (folder as NSString).lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Button(folder.isEmpty ? "选择 iCloud 云盘文件夹…" : "选择其他文件夹…") { picking = true }
            if !folder.isEmpty {
                Button("关闭云存档", role: .destructive) {
                    dm_clear_cloud_saves(); refresh(); note = ""
                }
            }
        } footer: {
            Text(note.isEmpty
                 ? "在 iCloud 云盘中选择一个文件夹，并在 Mac 应用的云存档设置中选择同一文件夹。游戏启动时导入云端存档，每次保存后同步到该文件夹；被替换的存档会保留在 save-backups 中。"
                 : note)
        }
        .sheet(isPresented: $picking) {
            DocumentPicker(types: [.folder]) { url in
                picking = false
                if dm_store_cloud_saves(url) {
                    note = "已保存。点击“开始游戏”后将使用此文件夹。"
                    refresh()
                } else {
                    note = "无法记住所选文件夹，请尝试选择其他文件夹。"
                }
            } onCancel: { picking = false }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        var stale: ObjCBool = false
        folder = dm_cloud_saves_path(&stale) ?? ""
        if stale.boolValue && folder.isEmpty {
            note = "之前选择的文件夹已无法访问（应用签名已变更）。请重新选择。"
        }
    }
}

/// UIDocumentPickerViewController for a folder, in the two callbacks a SwiftUI sheet wants.
private struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType] = [.folder]
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .open (not .import): the folder stays where it is and the bookmark keeps pointing at it.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) } else { onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}

private struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let play: () -> Void
    @State private var memory = os_proc_available_memory()
    @State private var resetConfirm = false

    private var gameName: String { (info("CFBundleDisplayName") as? String) ?? "游戏" }

    private var settingsList: some View {
        List {
            DuoDisplaySection()
            ForEach(m.sections, id: \.self) { section in
                let rows = m.rows(in: section)
                if !rows.isEmpty {
                    Section(launcherText(section)) {
                        ForEach(rows) { SettingRow(s: $0, m: m) }
                    }
                }
            }
            Section {
                Button("恢复游戏默认设置") { resetConfirm = true }
                    .disabled(!m.changed)
            } footer: {
                Text("恢复本游戏的启动选项。触控布局请进入游戏后，点 ⚙ 单独调整。")
            }
            CloudSavesSection()
            Section {
                HStack {
                    Text("应用可用内存")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            } footer: {
                Text("这是应用当前还可使用的内存额度，由 iOS 动态管理，与游戏文件大小不同。")
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.horizontal, 12, for: .scrollContent)
    }

    private func summary(compact: Bool) -> some View {
        VStack(spacing: compact ? 10 : 20) {
            if compact {
                HStack(spacing: 12) {
                    if let icon = appIcon() {
                        Image(uiImage: icon).resizable().frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(gameName).font(.headline).lineLimit(2)
                        Text("版本 \((info("CFBundleShortVersionString") as? String) ?? "") · Duo 触控版")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                if let icon = appIcon() {
                    Image(uiImage: icon).resizable().frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 22)).accessibilityHidden(true)
                }
                Text(gameName).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                Text("版本 \((info("CFBundleShortVersionString") as? String) ?? "")")
                    .font(.callout).foregroundStyle(.secondary)
                Text("iPhone Duo 触控版").font(.caption).foregroundStyle(.secondary)
            }
            playButton
        }
        .padding(compact ? 16 : 24)
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 780 && geometry.size.width > geometry.size.height {
                HStack(spacing: 0) {
                    summary(compact: false).frame(width: min(geometry.size.width * 0.32, 360))
                    settingsList
                }
            } else {
                VStack(spacing: 0) {
                    summary(compact: true)
                    settingsList
                }
            }
        }
        .background(DuoLayoutObserver().ignoresSafeArea())
        .preferredColorScheme(.dark)
        .confirmationDialog("恢复本游戏的启动选项？", isPresented: $resetConfirm, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) { m.reset() }
            Button("取消", role: .cancel) {}
        }
        .task {
            while !Task.isCancelled {
                memory = os_proc_available_memory()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder var playButton: some View {
        let button = Button(action: play) { Text("开始游戏").font(.title3.weight(.semibold)).frame(maxWidth: 220) }
            .controlSize(.large).accessibilityIdentifier("launcher.play")
        if #available(iOS 26.0, *) { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.borderedProminent) }
    }

    private func appIcon() -> UIImage? {
        if let i = UIImage(named: "AppIcon") { return i }
        guard let icons = info("CFBundleIcons") as? [String: Any], let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String], let last = files.last else { return nil }
        return UIImage(named: last)
    }
}

// Shows the launcher over the root view controller and calls done once the settings are in the environment; false (done is not called) when there is no launcher
@_cdecl("dm_show_launcher")
public func dmShowLauncher(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) -> Bool {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher.json"), let data = try? Data(contentsOf: url) else { return false }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return false }
    if ProcessInfo.processInfo.environment["DM_LAUNCHER"] == "0" { fputs("launcher: off (DM_LAUNCHER=0)\n", stderr); LauncherModel(file.settings).applySaved(); return false }
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    let model = LauncherModel(file.settings)
    var host: UIViewController?
    let view = LauncherView(m: model) {
        guard let h = host else { return }
        host = nil
        model.apply()
        h.dismiss(animated: false) { done() }
    }
    let h = UIHostingController(rootView: view)
    h.modalPresentationStyle = .fullScreen
    host = h
    parent.present(h, animated: false)
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    return true
}
