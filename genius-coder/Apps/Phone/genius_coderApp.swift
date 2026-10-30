import SwiftUI
import LocalAuthentication

@main
struct genius_coderApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    private var bannerBinding: Binding<Bool> {
        Binding(
            get: { model.banner != nil },
            set: { if !$0 { model.banner = nil } }
        )
    }

    var body: some View {
        Group {
            if model.requireFaceID && !model.unlocked {
                LockScreenView()
            } else if model.paired == nil {
                PairingView()
            } else {
                ProjectsView()
            }
        }
        .task {
            if !model.requireFaceID {
                model.unlockAndStart()
            }
        }
        .alert("提示", isPresented: bannerBinding) {
            Button("好", role: .cancel) { model.banner = nil }
        } message: {
            Text(model.banner ?? "")
        }
    }
}

/// Face ID (with device passcode fallback) gate. Nothing — not even the
/// local cache — is read before this passes (see `AppModel.unlockAndStart`).
struct LockScreenView: View {
    @EnvironmentObject private var model: AppModel
    @State private var failureText: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("genius-coder")
                .font(.title.bold())
            Text("已锁定")
                .foregroundStyle(.secondary)
            if let failureText {
                Text(failureText)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button("解锁") {
                authenticate()
            }
            .buttonStyle(.borderedProminent)
            Spacer()
            Spacer()
        }
        .padding()
        .task {
            authenticate()
        }
    }

    private func authenticate() {
        let context = LAContext()
        context.localizedFallbackTitle = "使用设备密码"
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
            failureText = "无法使用 Face ID 或设备密码：\(evaluationError?.localizedDescription ?? "未知错误")"
            return
        }
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "解锁 genius-coder"
        ) { success, error in
            DispatchQueue.main.async {
                if success {
                    model.unlockAndStart()
                } else {
                    failureText = error?.localizedDescription ?? "验证失败，请重试"
                }
            }
        }
    }
}
