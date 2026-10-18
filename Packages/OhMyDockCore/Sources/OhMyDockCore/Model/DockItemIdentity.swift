import Foundation

/// Key used to match a profile item against a Dock tile.
///
/// Spacers are **not unique**: every spacer of the same kind has the same identity, so
/// a diff must match spacers by position rather than by identity.
public enum DockItemIdentity: Hashable, Sendable {
    case app(bundleId: String)
    /// Apps with an empty `bundleId`, keyed by standardized `path` (empty if none).
    case appPath(String)
    case url(String)
    case folder(path: String)
    case file(path: String)
    case spacer(SpacerKind)
    case unknown(tileType: String, label: String?)
}

extension DockItem {
    public var identity: DockItemIdentity {
        switch self {
        case .app(let ref):
            ref.bundleId.isEmpty
                ? .appPath(ref.path.map(standardizedPath) ?? "")
                : .app(bundleId: ref.bundleId)
        case .url(let item): .url(item.url.absoluteString)
        case .folder(let item): .folder(path: standardizedPath(item.path))
        case .file(let item): .file(path: standardizedPath(item.path))
        case .spacer(let kind): .spacer(kind)
        case .unknown(let tile): .unknown(tileType: tile.tileType, label: tile.label)
        }
    }
}

/// Lexically standardizes an absolute path: collapses `//`, drops `.`, resolves `..`, and
/// removes a trailing slash. Never touches the filesystem, so symlinks are not resolved.
/// Relative paths are returned unchanged.
func standardizedPath(_ path: String) -> String {
    guard path.hasPrefix("/") else { return path }
    var parts: [Substring] = []
    for component in path.split(separator: "/", omittingEmptySubsequences: true) {
        switch component {
        case ".": continue
        case "..": _ = parts.popLast()
        default: parts.append(component)
        }
    }
    return "/" + parts.joined(separator: "/")
}
