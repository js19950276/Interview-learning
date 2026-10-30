import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var host = ""
    @State private var portText = ""
    @State private var showForgetConfirm = false
    @State private var showClearConfirm = false

    var body: some View {
        Form {
            Section {
                Toggle("Face ID 解锁", isOn: $model.requireFaceID)
            } header: {
                Text("安全")
            } footer: {
                Text("打开 App 时要求 Face ID；没有面容时使用设备密码。默认开启。")
            }

            if let paired = model.paired {
                Section("Bridge") {
                    LabeledContent("Bridge ID") {
                        Text(paired.bridgeId)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("证书指纹") {
                        Text(String(paired.certificateFingerprint.prefix(16)) + "…")
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("设备 ID") {
                        Text(paired.deviceId)
                            .font(.caption.monospaced())
                    }
                }

                Section {
                    TextField("主机（IP 或主机名）", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口", text: $portText)
                        .keyboardType(.numberPad)
                    Button("应用并重连") {
                        applyManualHost()
                    }
                } header: {
                    Text("手动填写 Bridge 主机")
                } footer: {
                    Text("手机先用上次成功的地址；局域网 2 秒连不上时自动改用保存的 Tailscale 地址。")
                }
            }

            Section("数据") {
                Button("清空缓存", role: .destructive) {
                    showClearConfirm = true
                }
            }

            Section {
                Button("忘记此设备", role: .destructive) {
                    showForgetConfirm = true
                }
            } footer: {
                Text("删除 Keychain 里的密钥与配对信息，之后需要重新扫码配对。")
            }
        }
        .navigationTitle("设置")
        .onAppear(perform: populateHostFields)
        .confirmationDialog(
            "忘记此设备？",
            isPresented: $showForgetConfirm,
            titleVisibility: .visible
        ) {
            Button("忘记此设备", role: .destructive) {
                model.forgetDevice()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除 Keychain 中的密钥与配对信息。")
        }
        .confirmationDialog(
            "清空本地缓存？",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                model.clearCache()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("断开时将无法再浏览已缓存的会话。")
        }
    }

    private func populateHostFields() {
        guard let paired = model.paired else { return }
        if host.isEmpty {
            host = paired.host
        }
        if portText.isEmpty {
            portText = String(paired.port)
        }
    }

    private func applyManualHost() {
        let newHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newHost.isEmpty else { return }
        let newPort = UInt16(portText.trimmingCharacters(in: .whitespaces)) ?? 8787
        Task {
            await model.applyManualHost(host: newHost, port: newPort)
        }
    }
}
