import Foundation

/// Namespace and bundle anchor for the shared core.
public enum SyncthingKit {
    public static let bundle = Bundle(for: BundleToken.self)
}

private final class BundleToken {}
