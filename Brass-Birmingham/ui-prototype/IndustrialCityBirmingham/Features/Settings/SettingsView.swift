import SwiftUI

struct SettingsView: View {
    @Environment(MotionPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section("体验") {
                Toggle("音效", isOn: $preferences.isSoundEnabled)
                Toggle("触觉", isOn: $preferences.isHapticsEnabled)
                Toggle("减少动态效果", isOn: $preferences.reduceMotion)
                Toggle("色觉辅助符号", isOn: $preferences.colorAssistEnabled)
            }
        }
        .tint(BrassColor.brass.color)
        .navigationTitle("设置")
    }
}
