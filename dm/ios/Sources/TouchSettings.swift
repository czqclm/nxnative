// Display selection stays in the launcher; touch editing belongs to the live game view.
import SwiftUI
import UIKit

struct DuoDisplaySection: View {
    @State private var mode = UserDefaults.standard.string(forKey: "DmTouchDisplayMode") ?? "automatic"
    @State private var active = dm_touch_active_profile()

    private var currentName: String {
        ["outer": "外屏", "inner": "展开内屏", "folded": "折叠双区"][active] ?? "外屏"
    }

    var body: some View {
        Section {
            Picker("布局模式", selection: $mode) {
                Text("自动识别").tag("automatic")
                Text("外屏").tag("outer")
                Text("展开内屏").tag("inner")
                Text("折叠双区").tag("folded")
            }
            .accessibilityIdentifier("touch.displayMode")
            .onChange(of: mode) { _, value in
                UserDefaults.standard.set(value, forKey: "DmTouchDisplayMode")
                NotificationCenter.default.post(name: .DmTouchSettingsDidChange, object: nil)
            }
            .onReceive(NotificationCenter.default.publisher(for: .DmTouchSettingsDidChange)) { _ in
                active = dm_touch_active_profile()
            }
            LabeledContent("当前形态", value: currentName)
        } header: {
            Text("iPhone Duo")
        } footer: {
            Text("进入游戏后，点画面上的 ⚙ 按钮，直接调整当前按键和摇杆。外屏、展开内屏、折叠双区分别保存。")
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
