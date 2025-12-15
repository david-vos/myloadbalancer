import Foundation

enum ConfigError: Error, CustomStringConvertible {
    case notFound([String])
    case invalidConfig(String, Error)

    var description: String {
        switch self {
        case let .notFound(paths):
            return "No config.json found. Searched paths:\n" + paths.map { "  - \($0)" }.joined(separator: "\n")
        case let .invalidConfig(path, error):
            return "Failed to parse config at \(path): \(error)"
        }
    }
}

/// Main application configuration
struct AppConfig: Codable {
    /// Server configuration
    let server: ServerConfig

    /// Docker configuration
    let docker: DockerConfig

    /// Deployment configuration
    let deployment: DeploymentConfig

    /// Load from a JSON file
    static func load(from path: String) throws -> AppConfig {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(AppConfig.self, from: data)
    }

    /// Load from default locations, throws if not found
    static func loadDefault() throws -> AppConfig {
        let searchPaths = [
            "./config.json",
            "./appconfig.json",
            "/etc/myloadbalancer/config.json",
        ]

        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) {
                do {
                    let config = try load(from: path)
                    return config
                } catch {
                    throw ConfigError.invalidConfig(path, error)
                }
            }
        }

        throw ConfigError.notFound(searchPaths)
    }
}

/// Server configuration
struct ServerConfig: Codable {
    /// Port the load balancer listens on
    let port: Int

    /// Host to bind to
    let host: String
}

/// Docker configuration
struct DockerConfig: Codable {
    /// Path to the docker executable
    let executablePath: String

    /// Additional environment variables for docker commands
    let environment: [String: String]?
}
