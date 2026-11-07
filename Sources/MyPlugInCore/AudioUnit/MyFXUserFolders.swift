import Foundation

/// Folders shared between MyDAW and sandboxed AUv3 app extensions.
public enum MyFXUserFolders {
    /// The user's real home. Inside a sandboxed extension, FileManager's home
    /// and Application Support point at the extension's container instead.
    public static var home: URL {
        if let directory = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// ~/Library/Application Support.
    public static var applicationSupport: URL {
        home.appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}
