import Foundation

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

    /// Load from default locations, falling back to defaults
    static func loadDefault() -> AppConfig {
        let searchPaths = [
            "./config.json",
            "./appconfig.json",
            "/etc/myloadbalancer/config.json",
        ]

        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) {
                do {
                    let config = try load(from: path)
                    print("[config] Loaded configuration from \(path)")
                    return config
                } catch {
                    print("[warn] Failed to load config from \(path): \(error)")
                }
            }
        }

        print("[config] Using default configuration")
        return .default
    }

    /// Default configuration
    static let `default` = AppConfig(
        server: .default,
        docker: .default,
        deployment: DeploymentConfig(
            name: "myapp",
            dockerfile: "../myapp/Dockerfile",
            context: "../myapp",
            replicas: 2,
            containerPort: 8080,
            healthCheckPath: "/health",
            healthCheckInterval: 10,
            remoteUrl: nil
        )
    )
}

/// Server configuration
struct ServerConfig: Codable {
    /// Port the load balancer listens on
    let port: Int

    /// Host to bind to
    let host: String

    static let `default` = ServerConfig(
        port: 8080,
        host: "0.0.0.0"
    )
}

/// Docker configuration
struct DockerConfig: Codable {
    /// Path to the docker executable
    let executablePath: String

    /// Additional environment variables for docker commands
    let environment: [String: String]?

    static let `default` = DockerConfig(
        executablePath: "/usr/bin/docker",
        environment: nil
    )
}
