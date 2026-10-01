import Foundation

/// Folder paths inside the app's container are stored as `~/…`, because iOS
/// moves the container to a new path when the app is reinstalled or updated.
/// Syncthing expands `~` to `$HOME` (the current container); Swift code that
/// touches the files must do the same. See go/stbridge/paths.go.
public enum FolderPath {
    /// The app container (`$HOME`), without a trailing slash.
    public static var home: String { (NSHomeDirectory() as NSString).standardizingPath }

    /// Absolute file URL for a stored folder path.
    public static func resolve(_ path: String, home: String = FolderPath.home) -> URL {
        URL(filePath: expand(path, home: home), directoryHint: .isDirectory)
    }

    public static func expand(_ path: String, home: String = FolderPath.home) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + "/" + path.dropFirst(2) }
        return path
    }

    /// `~/…` form for paths inside the container; others unchanged.
    public static func portable(_ path: String, home: String = FolderPath.home) -> String {
        let p = (path as NSString).standardizingPath
        let h = (home as NSString).standardizingPath
        if p == h { return "~" }
        if p.hasPrefix(h + "/") { return "~/" + p.dropFirst(h.count + 1) }
        // A previous container (after reinstall): …/Containers/Data/Application/<UUID>/rest
        if let range = p.range(of: #"^.*/Containers/Data/Application/[0-9A-Fa-f-]{36}(/|$)"#, options: .regularExpression) {
            let rest = p[range.upperBound...]
            return rest.isEmpty ? "~" : "~/" + rest
        }
        return path
    }

    /// Human-friendly location, e.g. "On My iPhone › SuperSynch › Sync".
    public static func displayName(_ path: String, appName: String = "SuperSynch") -> String {
        let p = portable(path)
        if p == "~/Documents" { return String(localized: "On My iPhone › \(appName)", bundle: SyncthingKit.bundle) }
        if p.hasPrefix("~/Documents/") {
            let rest = p.dropFirst("~/Documents/".count).replacingOccurrences(of: "/", with: " › ")
            return String(localized: "On My iPhone › \(appName) › \(rest)", bundle: SyncthingKit.bundle)
        }
        return path
    }
}
