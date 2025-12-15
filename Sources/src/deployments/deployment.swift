import Foundation

/// Configuration for a deployment (like a Kubernetes Deployment)
struct DeploymentConfig: Codable {
    let name: String
    let image: String?
    let dockerfile: String?
    let context: String?
    let replicas: Int
    let containerPort: Int
    let healthCheckPath: String
    let healthCheckInterval: TimeInterval
    /// GitHub repository URL for automatic release updates (e.g., "https://github.com/owner/repo")
    let remoteUrl: String?

    enum CodingKeys: String, CodingKey {
        case name
        case image
        case dockerfile
        case context
        case replicas
        case containerPort
        case healthCheckPath
        case healthCheckInterval
        case remoteUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        image = try container.decodeIfPresent(String.self, forKey: .image)
        dockerfile = try container.decodeIfPresent(String.self, forKey: .dockerfile)
        context = try container.decodeIfPresent(String.self, forKey: .context)
        replicas = try container.decodeIfPresent(Int.self, forKey: .replicas) ?? 1
        containerPort = try container.decodeIfPresent(Int.self, forKey: .containerPort) ?? 8080
        healthCheckPath = try container.decodeIfPresent(String.self, forKey: .healthCheckPath) ?? "/health"
        healthCheckInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .healthCheckInterval) ?? 10
        remoteUrl = try container.decodeIfPresent(String.self, forKey: .remoteUrl)
    }

    /// Create a deployment from a pre-built image
    init(
        name: String,
        image: String,
        replicas: Int = 1,
        containerPort: Int = 8080,
        healthCheckPath: String = "/health",
        healthCheckInterval: TimeInterval = 10,
        remoteUrl: String? = nil
    ) {
        self.name = name
        self.image = image
        self.dockerfile = nil
        self.context = nil
        self.replicas = replicas
        self.containerPort = containerPort
        self.healthCheckPath = healthCheckPath
        self.healthCheckInterval = healthCheckInterval
        self.remoteUrl = remoteUrl
    }

    /// Create a deployment that builds from a Dockerfile
    init(
        name: String,
        dockerfile: String,
        context: String = ".",
        replicas: Int = 1,
        containerPort: Int = 8080,
        healthCheckPath: String = "/health",
        healthCheckInterval: TimeInterval = 10,
        remoteUrl: String? = nil
    ) {
        self.name = name
        self.image = nil
        self.dockerfile = dockerfile
        self.context = context
        self.replicas = replicas
        self.containerPort = containerPort
        self.healthCheckPath = healthCheckPath
        self.healthCheckInterval = healthCheckInterval
        self.remoteUrl = remoteUrl
    }

    /// The image name to use (either provided or generated from name)
    var resolvedImage: String {
        image ?? "\(name):local"
    }

    /// Whether this deployment needs to be built
    var needsBuild: Bool {
        dockerfile != nil
    }
}

/// Represents a running container instance (like a Pod)
class Pod: Identifiable, CustomStringConvertible {
    let id: String
    let deploymentName: String
    let image: String
    let containerPort: Int
    var hostPort: Int
    var containerId: String?
    var containerIP: String?
    var status: PodStatus = .pending
    var healthCheckFailures: Int = 0
    let createdAt: Date
    /// The release version this pod was created with (e.g., "v1.2.3")
    let releaseVersion: String?

    var hostAddress: String {
        if let ip = containerIP {
            return "\(ip):\(containerPort)"
        }
        return "127.0.0.1:\(hostPort)"
    }

    var description: String {
        let versionStr = releaseVersion.map { " \($0)" } ?? ""
        return "Pod(\(id.prefix(8)), status: \(status), port: \(hostPort)\(versionStr))"
    }

    init(deploymentName: String, image: String, containerPort: Int, hostPort: Int, releaseVersion: String? = nil) {
        id = UUID().uuidString
        self.deploymentName = deploymentName
        self.image = image
        self.containerPort = containerPort
        self.hostPort = hostPort
        self.releaseVersion = releaseVersion
        createdAt = Date()
    }
}

enum PodStatus: String, CustomStringConvertible {
    case pending
    case running
    case unhealthy
    case terminating
    case terminated

    var description: String { rawValue }
}
