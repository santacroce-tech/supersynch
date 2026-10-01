import Foundation

/// Folders the user picked outside the app's container (via the document
/// picker). iOS grants access through security-scoped bookmarks, which must
/// be resolved and "started" before Syncthing touches the files.
///
/// Limitations (iOS): this works for local file-provider locations such as
/// "On My iPhone" folders of other apps; cloud providers (iCloud Drive etc.)
/// may evict or coordinate files in ways Syncthing doesn't expect.
public final class ExternalFolderAccess: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "externalFolderBookmarks.v1"
    private let lock = NSLock()
    private var active: [FolderID: URL] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var bookmarks: [FolderID: Data] {
        get { (defaults.dictionary(forKey: key) as? [String: Data]) ?? [:] }
        set { defaults.set(newValue, forKey: key) }
    }

    /// Stores a bookmark for a user-picked directory. Call while the picker's
    /// URL is accessible.
    public func register(_ url: URL, for folderID: FolderID) throws {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        lock.lock()
        var all = bookmarks
        all[folderID] = data
        bookmarks = all
        lock.unlock()
    }

    public func unregister(_ folderID: FolderID) {
        lock.lock(); defer { lock.unlock() }
        var all = bookmarks
        all[folderID] = nil
        bookmarks = all
        active.removeValue(forKey: folderID)?.stopAccessingSecurityScopedResource()
    }

    public func isExternal(_ folderID: FolderID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return bookmarks[folderID] != nil
    }

    /// Resolves every bookmark and starts access. Returns the current paths,
    /// which can differ from the stored folder path if the location moved.
    @discardableResult
    public func beginAccess() -> [FolderID: URL] {
        lock.lock(); defer { lock.unlock() }
        var all = bookmarks
        for (id, data) in all where active[id] == nil {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                continue
            }
            if url.startAccessingSecurityScopedResource() {
                active[id] = url
                if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    all[id] = fresh
                }
            }
        }
        bookmarks = all
        return active
    }

    public func endAccess() {
        lock.lock(); defer { lock.unlock() }
        for url in active.values { url.stopAccessingSecurityScopedResource() }
        active = [:]
    }

    public var activeURLs: [FolderID: URL] {
        lock.lock(); defer { lock.unlock() }
        return active
    }
}
