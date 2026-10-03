import Foundation
import os.log

private let log = Logger(subsystem: VirtualCameraConstants.appBundleID, category: "files")

/// A user-chosen file the sandbox lets us read. Access lasts while the
/// instance is alive, and a security-scoped bookmark lets the app reopen it
/// on the next launch.
final class ScopedFile {
    let url: URL
    private let scoped: Bool

    init(url: URL) {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
    }

    init?(bookmark: Data) {
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            self.url = url
            scoped = url.startAccessingSecurityScopedResource()
            log.info("resolved bookmark → \(url.path, privacy: .public) stale=\(stale) scoped=\(self.scoped)")
        } catch {
            log.error("bookmark resolution failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
    }

    var bookmark: Data? {
        // Files in File Provider locations (Dropbox, iCloud Drive) sometimes refuse a
        // read-write scoped bookmark; a read-only one is all this app needs anyway.
        let attempts: [URL.BookmarkCreationOptions] = [[.withSecurityScope, .securityScopeAllowOnlyReadAccess], [.withSecurityScope]]
        for options in attempts {
            do {
                let data = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
                log.info("bookmark created for \(self.url.path, privacy: .public) (\(data.count) bytes, options \(options.rawValue))")
                return data
            } catch {
                log.error("bookmark (options \(options.rawValue)) failed for \(self.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return nil
    }
}
