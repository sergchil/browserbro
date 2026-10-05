import Foundation

/// Reads Arc's `StorableSidebar.json`: which Space belongs to which profile.
///
/// Arc stores Swift dictionaries as flat `[key, value, key, value]` arrays. `sidebar.containers` holds
/// one entry per window kind: `{"global":{}}` (the main window) and `{"littleBrowser":{…}}` (mini windows,
/// whose spaces are not in the main window and can't be targeted). Only the `global` container counts.
public enum ArcSidebar {
    /// Profile directory ("Default", "Profile 2") → ID of its first Space in the main window.
    public static func spaceIDsByProfile(json data: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sidebar = root["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [Any] else { return [:] }
        var result: [String: String] = [:]
        for (i, item) in containers.enumerated() where i > 0 {
            guard let key = containers[i - 1] as? [String: Any], key["global"] != nil,
                  let container = item as? [String: Any], let spaces = container["spaces"] as? [Any] else { continue }
            for case let space as [String: Any] in spaces {
                guard let id = space["id"] as? String, let dir = profileDirectory(space["profile"]) else { continue }
                if result[dir] == nil { result[dir] = id }
            }
        }
        return result
    }

    /// `{"default":true}` → "Default"; `{"custom":{"_0":{"directoryBasename":"Profile 2"}}}` → "Profile 2".
    static func profileDirectory(_ value: Any?) -> String? {
        guard let profile = value as? [String: Any] else { return nil }
        if profile["default"] != nil { return "Default" }
        if let custom = profile["custom"] as? [String: Any], let inner = custom["_0"] as? [String: Any] {
            return inner["directoryBasename"] as? String
        }
        return nil
    }
}
