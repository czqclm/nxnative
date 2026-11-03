// Display selection stays in the launcher; touch editing belongs to the live game view.
import SwiftUI
import UIKit

struct DuoDisplaySection: View {
    @AppStorage("DmControlReflectionEnabled") private var controlReflectionEnabled = true
    @State private var mode: String = {
        let saved = UserDefaults.standard.string(forKey: "DmTouchDisplayMode") ?? "automatic"
        // Keep the stored legacy override intact; both old inner choices now
        // select the inner screen and let its orientation choose the profile.
        return saved == "folded" ? "inner" : saved
    }()
    @State private var active = dm_touch_active_profile()

    private var currentName: String {
        ["outer": "外屏", "inner": "内屏横屏", "folded": "内屏竖屏"][active] ?? "外屏"
    }

    var body: some View {
        Section {
            Picker("屏幕选择", selection: $mode) {
                Text("自动识别").tag("automatic")
                Text("外屏").tag("outer")
                Text("内屏").tag("inner")
            }
            .accessibilityIdentifier("touch.displayMode")
            .onChange(of: mode) { _, value in
                UserDefaults.standard.set(value, forKey: "DmTouchDisplayMode")
                NotificationCenter.default.post(name: .DmTouchSettingsDidChange, object: nil)
            }
            .onReceive(NotificationCenter.default.publisher(for: .DmTouchSettingsDidChange)) { _ in
                active = dm_touch_active_profile()
            }
            LabeledContent("当前布局", value: currentName)
            Toggle("控制区倒影", isOn: $controlReflectionEnabled)
                .accessibilityIdentifier("touch.controlReflection")
                .onChange(of: controlReflectionEnabled) { _, _ in
                    NotificationCenter.default.post(name: Notification.Name("DmControlReflectionDidChange"), object: nil)
                }
        } header: {
            Text("iPhone Duo")
        } footer: {
            Text("竖屏上方显示画面、下方放置按键；倒影仅在内屏竖屏弯折且角度可用时显示，展开、外屏和横屏不显示。弯折不切换按键布局。内屏竖屏、内屏横屏、外屏分别保存。进入游戏后点 ⚙ 调整。")
        }
    }
}

// SwiftUI owns this wrapper; UIKit owns the noninteractive region observer inside it.
struct DuoLayoutObserver: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        dm_duo_observe_layout_in_view(view)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { view.setNeedsLayout() }
}
