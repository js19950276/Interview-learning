import SwiftUI
import AVFoundation
import PhoneProtocol

struct PairingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var manualJSON = ""
    @State private var manualError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    QRScannerView { payload in
                        Task { await model.pair(scannedQR: payload) }
                    }
                    .frame(height: 300)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                    )
                    manualPasteSection
                }
                .padding()
            }
            .navigationTitle("配对")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var statusCard: some View {
        VStack(spacing: 8) {
            switch model.pairingStep {
            case .idle:
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text("在 Mac 菜单栏打开 genius-coder bridge 的配对二维码，然后用相机扫描。完成配对前没有项目列表。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .working(let text):
                ProgressView()
                Text(text)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            case .failed(let text):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("配对成功")
                    .font(.footnote)
            }
            if let bridgeId = model.paired?.bridgeId {
                Text("Bridge: \(bridgeId)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var isWorking: Bool {
        if case .working = model.pairingStep { return true }
        return false
    }

    private var manualPasteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("手动粘贴")
                .font(.headline)
            TextField("粘贴二维码里的配对 JSON", text: $manualJSON, axis: .vertical)
                .font(.caption.monospaced())
                .lineLimit(3...8)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(8)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            if let manualError {
                Text(manualError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button("配对") {
                pairManually()
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                manualJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func pairManually() {
        let trimmed = manualJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            manualError = "无法读取输入"
            return
        }
        do {
            let payload = try JSONDecoder().decode(PairingQRPayload.self, from: data)
            manualError = nil
            Task { await model.pair(scannedQR: payload) }
        } catch {
            manualError = "不是有效的配对 JSON：\(error.localizedDescription)"
        }
    }
}

// MARK: - QR camera scanner (AVCaptureMetadataOutput)

struct QRScannerView: UIViewControllerRepresentable {
    var onPayload: (PairingQRPayload) -> Void

    func makeUIViewController(context: Context) -> QRCameraController {
        let controller = QRCameraController()
        controller.onQRCode = { code in
            guard let data = code.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(PairingQRPayload.self, from: data) else {
                return
            }
            onPayload(payload)
        }
        return controller
    }

    func updateUIViewController(_ controller: QRCameraController, context: Context) {}
}

final class QRCameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {

    var onQRCode: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var lastScanValue = ""
    private var lastScanAt = Date.distantPast
    private var messageLabel: UILabel?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            showMessage("相机不可用（模拟器上请用下方手动粘贴）")
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showMessage("无法初始化扫描输出")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted {
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                } else {
                    self.showMessage("相机权限被拒绝。请到系统设置里开启，或使用手动粘贴。")
                }
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            session.stopRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let code = metadataObjects
            .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
            .first(where: { $0.stringValue != nil }),
            let value = code.stringValue else {
            return
        }
        let now = Date()
        guard value != lastScanValue || now.timeIntervalSince(lastScanAt) > 2.0 else { return }
        lastScanValue = value
        lastScanAt = now
        onQRCode?(value)
    }

    private func showMessage(_ text: String) {
        guard messageLabel == nil else { return }
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            view.trailingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 16),
        ])
        messageLabel = label
    }
}
