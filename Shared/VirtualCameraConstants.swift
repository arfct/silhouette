import Foundation

/// Values shared between the app and the camera extension. The app finds the
/// extension's device by `deviceUID` and its sink stream by `sinkStreamName`.
enum VirtualCameraConstants {
    static let deviceUID = UUID(uuidString: "5B1D7E42-9A3C-4D6F-B8E1-2C4F6A8D0E10")!
    static let sourceStreamID = UUID(uuidString: "5B1D7E42-9A3C-4D6F-B8E1-2C4F6A8D0E11")!
    static let sinkStreamID = UUID(uuidString: "5B1D7E42-9A3C-4D6F-B8E1-2C4F6A8D0E12")!
    static let deviceName = "Silhouette"
    static let sourceStreamName = "Silhouette Video"
    static let sinkStreamName = "Silhouette Sink"
    static let extensionBundleID = "com.artifact.Silhouette.Camera"
    static let appBundleID = "com.artifact.Silhouette"

    /// Output format. The app renders every frame at this size regardless of
    /// the physical camera's resolution.
    static let width = 1920
    static let height = 1080
    static let frameRate: Int32 = 30
}
