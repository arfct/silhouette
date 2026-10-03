import AppKit
import SystemExtensions

/// Activates the embedded camera extension. macOS copies it out of the app
/// bundle and asks the user to approve it once in System Settings.
final class ExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
    var onStatus: ((String) -> Void)?
    var onActivated: (() -> Void)?
    var onNeedsApproval: (() -> Void)?

    static var appIsInApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    /// Deep link into System Settings → General → Login Items & Extensions,
    /// scrolled to the Extensions section where Camera Extensions lives.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension?extensionPointIdentifier=com.apple.system_extension.cmio")!

    static func openSystemSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    func activate() {
        guard Self.appIsInApplications else {
            onStatus?("Move Silhouette.app to /Applications to install the virtual camera.")
            return
        }
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: VirtualCameraConstants.extensionBundleID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        onStatus?("Installing camera extension…")
    }

    func deactivate() {
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: VirtualCameraConstants.extensionBundleID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        onStatus?("Approve it under Camera Extensions, then relaunch Silhouette.")
        onNeedsApproval?()
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            onStatus?("Camera extension installed.")
            onActivated?()
        case .willCompleteAfterReboot:
            onStatus?("Camera extension installs after a restart.")
        @unknown default:
            onStatus?("Camera extension: unknown result.")
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        onStatus?("Extension failed: \(error.localizedDescription)")
    }
}
