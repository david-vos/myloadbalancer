import Vapor

/// Represents a GitHub release
struct GitHubRelease: Codable {
    let tagName: String
    let name: String?
    let publishedAt: String?
    let htmlUrl: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case publishedAt = "published_at"
        case htmlUrl = "html_url"
    }
}

/// Checks GitHub for new releases
class ReleaseChecker {
    private let client: Client

    init(client: Client) {
        self.client = client
    }

    /// Parse owner and repo from a GitHub URL
    /// Supports formats like:
    /// - https://github.com/owner/repo
    /// - https://github.com/owner/repo.git
    /// - github.com/owner/repo
    func parseGitHubUrl(_ urlString: String) -> (owner: String, repo: String)? {
        var cleanUrl = urlString
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "github.com/", with: "")
            .replacingOccurrences(of: ".git", with: "")

        // Remove trailing slash if present
        if cleanUrl.hasSuffix("/") {
            cleanUrl = String(cleanUrl.dropLast())
        }

        let parts = cleanUrl.split(separator: "/")
        guard parts.count >= 2 else { return nil }

        return (owner: String(parts[0]), repo: String(parts[1]))
    }

    /// Fetch the latest release from a GitHub repository
    func getLatestRelease(remoteUrl: String) async -> GitHubRelease? {
        guard let (owner, repo) = parseGitHubUrl(remoteUrl) else {
            print("[release] Invalid GitHub URL: \(remoteUrl)")
            return nil
        }

        let apiUrl = "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"

        do {
            var headers = HTTPHeaders()
            headers.add(name: .accept, value: "application/vnd.github.v3+json")
            headers.add(name: .userAgent, value: "myloadbalancer")

            let response = try await client.get(URI(string: apiUrl), headers: headers)

            guard response.status == .ok else {
                if response.status == .notFound {
                    print("[release] No releases found for \(owner)/\(repo)")
                } else {
                    print("[release] GitHub API error: \(response.status)")
                }
                return nil
            }

            let release = try response.content.decode(GitHubRelease.self)
            return release
        } catch {
            print("[release] Failed to fetch release: \(error)")
            return nil
        }
    }

    /// Check if a new release is available compared to the current version
    func checkForUpdate(remoteUrl: String, currentVersion: String?) async -> GitHubRelease? {
        guard let latestRelease = await getLatestRelease(remoteUrl: remoteUrl) else {
            return nil
        }

        // If no current version, any release is "new"
        guard let current = currentVersion else {
            return latestRelease
        }

        // Compare versions (simple string comparison - works for semantic versioning)
        if latestRelease.tagName != current {
            return latestRelease
        }

        return nil
    }
}
