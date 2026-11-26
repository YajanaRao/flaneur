import Foundation

enum GitHub {
    static func words(for urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com"
        else { return nil }
        let parts = url.path.split(separator: "/").map { $0.lowercased() }
        guard parts.count >= 2 else { return nil }
        let repo = parts[1]
        guard let page = page(in: parts) else { return "github \(repo)" }
        return "github \(repo) \(page)"
    }

    private static func page(in parts: [String]) -> String? {
        guard parts.count >= 3 else { return nil }
        switch parts[2] {
        case "tree", "blob", "blame", "commit", "commits":
            return nil
        case "pull":
            return "pulls"
        default:
            return parts[2]
        }
    }
}
