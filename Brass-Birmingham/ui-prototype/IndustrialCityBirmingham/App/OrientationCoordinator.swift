import OSLog
import SwiftUI
import UIKit

enum OrientationGeometryPolicy {
    static func isSatisfied(
        mask: UIInterfaceOrientationMask,
        interfaceOrientation: UIInterfaceOrientation,
        bounds: CGRect
    ) -> Bool {
        guard interfaceOrientation != .unknown,
              mask.contains(interfaceOrientation.mask) else {
            return false
        }

        if interfaceOrientation.isLandscape {
            return bounds.width > bounds.height
        }

        return bounds.height >= bounds.width
    }
}

private extension UIInterfaceOrientation {
    var mask: UIInterfaceOrientationMask {
        UIInterfaceOrientationMask(rawValue: 1 << rawValue)
    }
}

struct OrientationMaskRegistry {
    private var masks: [String: UIInterfaceOrientationMask] = [:]

    mutating func set(
        _ mask: UIInterfaceOrientationMask,
        for sceneIdentifier: String
    ) {
        masks[sceneIdentifier] = mask
    }

    func mask(for sceneIdentifier: String?) -> UIInterfaceOrientationMask {
        guard let sceneIdentifier else { return .allButUpsideDown }
        return masks[sceneIdentifier] ?? .allButUpsideDown
    }

    mutating func reset(_ sceneIdentifier: String) {
        masks.removeValue(forKey: sceneIdentifier)
    }
}

@MainActor
enum OrientationCoordinator {
    private static var registry = OrientationMaskRegistry()
    private static let logger = Logger(
        subsystem: "com.didi.prototype.IndustrialCityBirmingham",
        category: "Orientation"
    )

    static func supportedMask(for window: UIWindow?) -> UIInterfaceOrientationMask {
        registry.mask(for: sceneIdentifier(for: window?.windowScene))
    }

    static func apply(
        _ mask: UIInterfaceOrientationMask,
        to scene: UIWindowScene?
    ) {
        guard let scene else { return }
        let sceneIdentifier = scene.session.persistentIdentifier
        registry.set(mask, for: sceneIdentifier)
        scene.windows.first(where: \.isKeyWindow)?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()

        scene.requestGeometryUpdate(
            .iOS(interfaceOrientations: mask)
        ) { error in
            logger.error(
                "Geometry update failed for scene \(sceneIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    static func applyAndWait(
        _ mask: UIInterfaceOrientationMask,
        to scene: UIWindowScene?,
        timeout: Duration = .seconds(3)
    ) async -> Bool {
        guard let scene else {
            logger.warning("Cannot await orientation geometry without a window scene")
            return false
        }

        apply(mask, to: scene)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var stableSamples = 0
        while !Task.isCancelled {
            let window = scene.windows.first(where: \.isKeyWindow)
            let rootViewController = window?.rootViewController
            let bounds = [
                scene.coordinateSpace.bounds,
                window?.bounds,
                rootViewController?.viewIfLoaded?.bounds
            ].compactMap { $0 }
            let geometrySatisfied = bounds.count == 3
                && bounds.allSatisfy({ bounds in
                   OrientationGeometryPolicy.isSatisfied(
                       mask: mask,
                       interfaceOrientation: scene.interfaceOrientation,
                       bounds: bounds
                   )
               })
            if geometrySatisfied,
               rootViewController?.transitionCoordinator == nil {
                stableSamples += 1
            } else {
                stableSamples = 0
            }

            if stableSamples >= 2 {
                rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                rootViewController?.view.setNeedsLayout()
                window?.setNeedsLayout()
                rootViewController?.view.layoutIfNeeded()
                window?.layoutIfNeeded()
                await Task.yield()
                return true
            }

            guard clock.now < deadline else { break }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }

        guard !Task.isCancelled else { return false }
        let sceneIdentifier = scene.session.persistentIdentifier
        logger.error(
            "Timed out waiting for scene \(sceneIdentifier, privacy: .public) to satisfy orientation mask \(mask.rawValue, privacy: .public)"
        )
        return false
    }

    static func reset(scene: UIWindowScene?) {
        guard let scene else { return }
        let sceneIdentifier = scene.session.persistentIdentifier
        registry.reset(sceneIdentifier)

        scene.requestGeometryUpdate(
            .iOS(interfaceOrientations: .allButUpsideDown)
        ) { error in
            logger.error(
                "Geometry reset failed for scene \(sceneIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
        scene.windows.first(where: \.isKeyWindow)?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private static func sceneIdentifier(for scene: UIWindowScene?) -> String? {
        scene?.session.persistentIdentifier
    }
}

@MainActor
final class WindowSceneReference {
    weak var scene: UIWindowScene?
}

struct WindowSceneProbe: UIViewRepresentable {
    let onSceneChange: @MainActor (UIWindowScene?) -> Void

    func makeUIView(context: Context) -> WindowSceneProbeView {
        WindowSceneProbeView(onSceneChange: onSceneChange)
    }

    func updateUIView(_ uiView: WindowSceneProbeView, context: Context) {
        uiView.onSceneChange = onSceneChange
        uiView.reportSceneIfNeeded()
    }

    static func dismantleUIView(
        _ uiView: WindowSceneProbeView,
        coordinator: Void
    ) {
        uiView.onSceneChange?(nil)
        uiView.onSceneChange = nil
    }
}

final class WindowSceneProbeView: UIView {
    var onSceneChange: (@MainActor (UIWindowScene?) -> Void)?
    private weak var lastScene: UIWindowScene?

    init(onSceneChange: @escaping @MainActor (UIWindowScene?) -> Void) {
        self.onSceneChange = onSceneChange
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneDidDisconnect(_:)),
            name: UIScene.didDisconnectNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportSceneIfNeeded()
    }

    func reportSceneIfNeeded() {
        let scene = window?.windowScene
        guard scene !== lastScene else { return }
        lastScene = scene
        onSceneChange?(scene)
    }

    @objc private func sceneDidDisconnect(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene,
              scene === lastScene else { return }
        lastScene = nil
        onSceneChange?(nil)
    }
}
