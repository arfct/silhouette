import Foundation
import CoreMediaIO

// Entry point for the CoreMediaIO camera extension. macOS launches this
// process on demand when a client (Zoom, FaceTime, our app) opens the device.
let providerSource = ProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
