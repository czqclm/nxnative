// One launcher setting as a row (a menu, a slider with its percentage, a toggle), shared by the iOS launcher (Launcher.swift) and the Mac app's settings window (dm/mac/Launcher.swift).
// A row whose setting is fixed by an env file or by the launch environment is shown but disabled.
import SwiftUI

// This personal iOS build uses Chinese; the shared Mac front end stays unchanged.
func launcherText(_ source: String) -> String {
#if os(iOS)
    let translations: [String: String] = [
        "Game": "游戏", "Controls": "控制", "Performance": "性能",
        "Picture": "画面适配", "Fit": "完整显示", "Fill": "铺满（裁切）",
        "Game's upscaler": "游戏画面放大器", "Game's own": "游戏自带",
        "Fill crops the game's 16:9 picture to cover the screen. Health bars, subtitles or maps near the edges can be cut off. A full-screen picture without cropping needs a patch for each game.": "铺满会裁切 16:9 画面的边缘，血条、字幕或地图可能被截断。若要全屏且不裁切，需要针对游戏制作补丁。",
        "Frame rate": "目标帧率", "30 fps": "30 帧/秒", "60 fps": "60 帧/秒",
        "Dynamic resolution": "动态分辨率", "Render scale": "渲染比例",
        "Console mode": "主机模式", "Docked": "底座模式", "Handheld": "掌机模式",
        "Upscaling": "画面放大", "Standard": "标准", "Game language": "游戏语言",
        "Frame-rate counter": "显示帧率", "Touch feedback": "触摸震感",
        "Game rumble": "游戏震动", "Rumble strength": "震动强度", "Rumble cutoff": "手柄震动过滤阈值",
        "Frame buffering": "帧缓冲", "Metal 4 pipelines": "Metal 4 渲染管线",
        "Pipeline prebuild": "管线预构建", "Encode thread": "独立图形指令线程",
        "Hold frames when late": "延迟帧保持", "Performance HUD": "性能监控面板",
        "Adjusts resolution between 70% and 100% under load. Turn off to keep full resolution for the selected console mode.": "根据负载在 70% 至 100% 之间调整分辨率。关闭后保持所选主机模式的完整分辨率。",
        "Uses more GPU time and can increase heat.": "增加 GPU 工作量，可能使设备更热。",
        "Up to one frame more display latency.": "最多增加一帧显示延迟。",
        "Keeps a pipeline archive; uses more memory.": "保存渲染管线缓存，会使用更多内存。",
        "The first start waits a few minutes for it, once.": "需启用 Metal 4；首次准备可能需要几分钟。",
        "Set at launch": "由启动参数固定", "Set by an env file": "由配置文件固定"
    ]
    return translations[source] ?? source
#else
    return source
#endif
}

extension LauncherModel {
    func binding(_ s: Setting) -> Binding<String> { Binding(get: { self.values[s.env] ?? s.def }, set: { self.values[s.env] = $0 }) }
}

struct SettingRow: View {
    let s: Setting
    @ObservedObject var m: LauncherModel

    private var locked: Bool { m.fixed.contains(s.env) }
    private var note: String {
        guard locked else { return launcherText(s.note) }
        return (s.note.isEmpty ? "" : launcherText(s.note) + " · ") + launcherText(m.fromLaunch.contains(s.env) ? "Set at launch" : "Set by an env file")
    }
    private var rangeValue: Binding<Double> {
        Binding(get: { Double(m.values[s.env] ?? s.def) ?? s.max ?? 1 },
                set: { m.values[s.env] = String(format: "%.2f", $0) })
    }
    private var percentage: String { m.rangeLabel(s, rangeValue.wrappedValue) }

    private var settingLabel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(launcherText(s.label))
            if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    var body: some View {
        Group {
            switch s.kind {
            case "choice":
                Picker(selection: m.binding(s)) {
                    ForEach(s.options ?? [], id: \.[0]) { option in
#if os(iOS)
                        Text(s.env == "DM_LANG" ? (Locale(identifier: "zh-Hans").localizedString(forIdentifier: option[0]) ?? option[1]) : launcherText(option[1])).tag(option[0])
#else
                        Text(option[1]).tag(option[0])
#endif
                    }
                } label: {
                    settingLabel
                }
                .pickerStyle(.menu)
            case "range":
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        settingLabel
                        Spacer()
                        Text(percentage).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: rangeValue, in: (s.min ?? 0)...(s.max ?? 1), step: s.step ?? 0.05)
                        .accessibilityLabel(launcherText(s.label))
                        .accessibilityValue(percentage)
                }
            default:
                Toggle(isOn: Binding(get: { (m.values[s.env] ?? s.def) == s.onValue }, set: { m.values[s.env] = $0 ? s.onValue : s.offValue })) {
                    settingLabel
                }
            }
        }
        .disabled(locked)
    }
}
