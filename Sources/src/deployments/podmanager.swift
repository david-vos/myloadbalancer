import Foundation
import Vapor

/// Manages pods lifecycle - starts, monitors health, and replaces unhealthy pods
final class PodManager: @unchecked Sendable {
    private var pods: [String: Pod] = [:] // podId -> Pod
    private var deployments: [String: DeploymentConfig] = [:] // name -> config
    private var currentVersions: [String: String] = [:] // deploymentName -> current release version
    private var nextPort: Int = 9000
    private let docker: DockerClient
    private var healthChecker: HealthChecker?
    private var releaseChecker: ReleaseChecker?
    private var healthCheckTask: Task<Void, Never>?
    private var isRollingUpdate: [String: Bool] = [:] // Track ongoing rolling updates per deployment
    private var logger: Logger?
    private var lastReleaseCheck: Date? // Track last time we checked for releases
    private let releaseCheckInterval: TimeInterval = 120 // Check for releases every 2 minutes (120 seconds)

    var healthyPods: [Pod] {
        pods.values.filter { $0.status == .running }
    }

    func healthyPods(forDeployment name: String) -> [Pod] {
        pods.values.filter { $0.deploymentName == name && $0.status == .running }
    }

    /// Get pod counts grouped by version for a deployment
    func podCountsByVersion(forDeployment name: String) -> [String: Int] {
        let deploymentPods = pods.values.filter { $0.deploymentName == name && $0.status == .running }
        var counts: [String: Int] = [:]
        for pod in deploymentPods {
            let version = pod.releaseVersion ?? "unknown"
            counts[version, default: 0] += 1
        }
        return counts
    }

    /// Get all pod counts grouped by version across all deployments
    func allPodCountsByVersion() -> [String: [String: Int]] {
        var result: [String: [String: Int]] = [:]
        for deploymentName in deployments.keys {
            result[deploymentName] = podCountsByVersion(forDeployment: deploymentName)
        }
        return result
    }

    /// Get detailed info for all pods grouped by deployment
    func allPodsInfo() -> [String: [(id: String, name: String, status: String, version: String)]] {
        var result: [String: [(id: String, name: String, status: String, version: String)]] = [:]
        for deploymentName in deployments.keys {
            let deploymentPods = pods.values.filter { $0.deploymentName == deploymentName }
            result[deploymentName] = deploymentPods.map { pod in
                (
                    id: String(pod.id.prefix(8)),
                    name: "pod-\(pod.id.prefix(8))",
                    status: pod.status.rawValue,
                    version: pod.releaseVersion ?? "unknown"
                )
            }
        }
        return result
    }

    /// Check if any rolling update is in progress
    var hasActiveRollingUpdate: Bool {
        isRollingUpdate.values.contains(true)
    }

    /// Get deployments currently in rolling update
    var deploymentsInRollingUpdate: [String] {
        isRollingUpdate.filter { $0.value }.map { $0.key }
    }

    init(dockerConfig: DockerConfig) {
        docker = DockerClient(config: dockerConfig)
    }

    func setClient(_ client: Client) {
        healthChecker = HealthChecker(client: client)
        releaseChecker = ReleaseChecker(client: client)
    }

    func setLogger(_ logger: Logger) {
        self.logger = logger
        docker.setLogger(logger)
        releaseChecker?.setLogger(logger)
    }

    private func log(_ level: Logger.Level, _ message: String) {
        logger?.log(level: level, "\(message)")
    }

    /// Clean up orphaned containers from previous crashes
    func cleanupOrphanedContainers() async {
        await docker.cleanupOrphanedContainers()
    }

    /// Deploy a new service with the given configuration
    func deploy(_ config: DeploymentConfig) async throws {
        log(.info, "[deploy] Deploying \(config.name) with \(config.replicas) replicas...")
        deployments[config.name] = config

        // Fetch current version from GitHub if remoteUrl is configured
        if let remoteUrl = config.remoteUrl, let releaseChecker = releaseChecker {
            log(.info, "[deploy] Fetching latest release version from \(remoteUrl)...")
            if let latestRelease = await releaseChecker.getLatestRelease(remoteUrl: remoteUrl) {
                currentVersions[config.name] = latestRelease.tagName
                log(.info, "[deploy] Using version: \(latestRelease.tagName)")
            } else {
                log(.warning, "[deploy] Could not fetch release version, will use 'unknown'")
            }
        }

        // Build image if dockerfile is specified
        if config.needsBuild {
            guard let dockerfile = config.dockerfile else {
                throw DeploymentError.missingDockerfile
            }
            let context = config.context ?? "."
            let version = currentVersions[config.name]
            var buildArgs: [String: String]? = nil
            if let version = version {
                buildArgs = ["RELEASE_VERSION": version]
            }
            try await docker.buildImage(
                dockerfile: dockerfile,
                context: context,
                tag: config.resolvedImage,
                buildArgs: buildArgs
            )
        }

        for index in 0 ..< config.replicas {
            let pod = try await startPod(for: config)
            log(.info, "[ok] Started replica \(index + 1): \(pod)")
        }

        startHealthChecks()
    }

    enum DeploymentError: Error, CustomStringConvertible {
        case missingDockerfile
        case missingImage

        var description: String {
            switch self {
            case .missingDockerfile: return "Dockerfile path is required for build deployments"
            case .missingImage: return "Either image or dockerfile must be specified"
            }
        }
    }

    /// Start a new pod for the given deployment
    private func startPod(for config: DeploymentConfig, releaseVersion: String? = nil) async throws -> Pod {
        let hostPort = nextPort
        nextPort += 1

        let version = releaseVersion ?? currentVersions[config.name]
        let pod = Pod(
            deploymentName: config.name,
            image: config.resolvedImage,
            containerPort: config.containerPort,
            hostPort: hostPort,
            releaseVersion: version
        )

        // Start the Docker container
        let containerId = try await docker.runContainer(
            image: config.resolvedImage,
            name: "pod-\(pod.id.prefix(8))",
            hostPort: hostPort,
            containerPort: config.containerPort
        )

        pod.containerId = containerId

        // Get the container's IP address for internal networking
        let containerIP = try await docker.getContainerIP(id: containerId)
        pod.containerIP = containerIP

        pod.status = .running
        pods[pod.id] = pod

        return pod
    }

    /// Check health of all pods and replace unhealthy ones
    func checkAllHealth() async {
        guard let healthChecker = healthChecker else { return }

        // Check for new releases for each deployment (throttled to once per 2 minutes)
        let now = Date()
        if let lastCheck = lastReleaseCheck {
            let timeSinceLastCheck = now.timeIntervalSince(lastCheck)
            if timeSinceLastCheck >= releaseCheckInterval {
                await checkForReleaseUpdates()
                lastReleaseCheck = now
            }
        } else {
            // First check - do it immediately
            await checkForReleaseUpdates()
            lastReleaseCheck = now
        }

        for (_, pod) in pods where pod.status == .running {
            guard let config = deployments[pod.deploymentName] else { continue }

            // Use container IP for health checks (same as proxy)
            let host = pod.containerIP ?? "127.0.0.1"
            let port = pod.containerIP != nil ? pod.containerPort : pod.hostPort

            let isHealthy = await healthChecker.check(
                host: host,
                port: port,
                path: config.healthCheckPath
            )

            if isHealthy {
                pod.healthCheckFailures = 0
            } else {
                pod.healthCheckFailures += 1
                log(.warning, "[warn] Pod \(pod.id.prefix(8)) health check failed (\(pod.healthCheckFailures)/3)")

                if pod.healthCheckFailures >= 3 {
                    await replacePod(pod)
                }
            }
        }
    }

    /// Check all deployments for new releases and trigger rolling updates
    private func checkForReleaseUpdates() async {
        guard let releaseChecker = releaseChecker else {
            log(.warning, "[release] Release checker not available")
            return
        }

        for (name, config) in deployments {
            // Skip if no remote URL configured
            guard let remoteUrl = config.remoteUrl else { continue }

            // Skip if already doing a rolling update for this deployment
            if isRollingUpdate[name] == true {
                log(.info, "[release] Rolling update already in progress for \(name), skipping check")
                continue
            }

            let currentVersion = currentVersions[name]
            log(.info, "[release] Checking for updates for \(name) (current: \(currentVersion ?? "none"))...")

            if let newRelease = await releaseChecker.checkForUpdate(
                remoteUrl: remoteUrl,
                currentVersion: currentVersion
            ) {
                log(.info, "[release] New release detected for \(name): \(newRelease.tagName) (was: \(currentVersion ?? "none"))")
                await performRollingUpdate(deployment: name, newVersion: newRelease.tagName)
            } else {
                log(.debug, "[release] No new release found for \(name) (current: \(currentVersion ?? "none"))")
            }
        }
    }

    /// Perform a rolling update for a deployment to a new version
    private func performRollingUpdate(deployment name: String, newVersion: String) async {
        guard let config = deployments[name] else { return }

        isRollingUpdate[name] = true
        log(.info, "[rolling-update] Starting rolling update for \(name) to \(newVersion)...")

        // Get all current pods for this deployment
        let currentPods = pods.values.filter { $0.deploymentName == name && $0.status == .running }
        let podCount = currentPods.count

        if podCount == 0 {
            log(.info, "[rolling-update] No running pods found for \(name), starting fresh deployment")
            currentVersions[name] = newVersion

            // Rebuild if using dockerfile
            if config.needsBuild {
                do {
                    guard let dockerfile = config.dockerfile else { return }
                    let context = config.context ?? "."
                    let buildArgs = ["RELEASE_VERSION": newVersion]
                    try await docker.buildImage(
                        dockerfile: dockerfile,
                        context: context,
                        tag: config.resolvedImage,
                        buildArgs: buildArgs
                    )
                } catch {
                    log(.error, "[rolling-update] Failed to rebuild image: \(error)")
                    isRollingUpdate[name] = false
                    return
                }
            }

            for _ in 0 ..< config.replicas {
                do {
                    let newPod = try await startPod(for: config, releaseVersion: newVersion)
                    log(.info, "[rolling-update] Started new pod: \(newPod)")
                } catch {
                    log(.error, "[rolling-update] Failed to start pod: \(error)")
                }
            }

            isRollingUpdate[name] = false
            log(.info, "[rolling-update] Completed rolling update for \(name)")
            return
        }

        // Rebuild image if using dockerfile
        if config.needsBuild {
            do {
                guard let dockerfile = config.dockerfile else {
                    isRollingUpdate[name] = false
                    return
                }
                let context = config.context ?? "."
                log(.info, "[rolling-update] Rebuilding image for \(name)...")
                let buildArgs = ["RELEASE_VERSION": newVersion]
                try await docker.buildImage(
                    dockerfile: dockerfile,
                    context: context,
                    tag: config.resolvedImage,
                    buildArgs: buildArgs
                )
            } catch {
                log(.error, "[rolling-update] Failed to rebuild image: \(error)")
                isRollingUpdate[name] = false
                return
            }
        }

        // Update the current version
        currentVersions[name] = newVersion

        // Rolling update: replace pods one at a time
        for (index, oldPod) in currentPods.enumerated() {
            log(.info, "[rolling-update] Replacing pod \(index + 1)/\(podCount) for \(name)...")

            // Start new pod first
            do {
                let newPod = try await startPod(for: config, releaseVersion: newVersion)
                log(.info, "[rolling-update] New pod started: \(newPod)")

                // Wait for new pod to be healthy before removing old one
                let healthy = await waitForPodHealthy(newPod, config: config, timeout: 60)

                if healthy {
                    log(.info, "[rolling-update] New pod is healthy, terminating old pod...")
                    await terminatePod(oldPod)
                } else {
                    log(.warning, "[rolling-update] New pod failed health check, keeping old pod")
                    // Remove the unhealthy new pod
                    await terminatePod(newPod)
                }
            } catch {
                log(.error, "[rolling-update] Failed to start replacement pod: \(error)")
            }

            // Small delay between pod replacements to avoid overwhelming the system
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        }

        isRollingUpdate[name] = false
        log(.info, "[rolling-update] Completed rolling update for \(name) to \(newVersion)")
    }

    /// Wait for a pod to become healthy
    private func waitForPodHealthy(_ pod: Pod, config: DeploymentConfig, timeout: TimeInterval) async -> Bool {
        guard let healthChecker = healthChecker else { return false }

        let startTime = Date()
        let checkInterval: UInt64 = 2_000_000_000 // 2 seconds

        while Date().timeIntervalSince(startTime) < timeout {
            // Use container IP for health checks
            let host = pod.containerIP ?? "127.0.0.1"
            let port = pod.containerIP != nil ? pod.containerPort : pod.hostPort

            let isHealthy = await healthChecker.check(
                host: host,
                port: port,
                path: config.healthCheckPath
            )

            if isHealthy {
                return true
            }

            try? await Task.sleep(nanoseconds: checkInterval)
        }

        return false
    }

    /// Terminate a pod and clean up its container
    private func terminatePod(_ pod: Pod) async {
        pod.status = .terminating

        if let containerId = pod.containerId {
            do {
                try await docker.stopContainer(id: containerId)
                try await docker.removeContainer(id: containerId)
            } catch {
                log(.warning, "[warn] Failed to cleanup container: \(error)")
            }
        }

        pod.status = .terminated
        pods.removeValue(forKey: pod.id)
    }

    /// Replace an unhealthy pod with a new one
    private func replacePod(_ pod: Pod) async {
        log(.info, "[replace] Replacing unhealthy pod \(pod.id.prefix(8))...")

        guard let config = deployments[pod.deploymentName] else {
            await terminatePod(pod)
            return
        }

        // Start new pod first
        do {
            let newPod = try await startPod(for: config, releaseVersion: pod.releaseVersion)
            log(.info, "[replace] New pod started: \(newPod), waiting for health check...")

            // Wait for new pod to be healthy before terminating old one
            let healthy = await waitForPodHealthy(newPod, config: config, timeout: 60)

            if healthy {
                log(.info, "[replace] New pod is healthy, terminating old pod...")
                pod.status = .terminating
                await terminatePod(pod)
                log(.info, "[ok] Old pod terminated")
            } else {
                log(.warning, "[replace] New pod failed health check, keeping old pod, removing new pod")
                await terminatePod(newPod)
            }
        } catch {
            log(.error, "[error] Failed to start replacement pod: \(error)")
        }
    }

    /// Start periodic health checks
    private func startHealthChecks() {
        guard healthCheckTask == nil else { return }

        // Run health checks every 10 seconds using async Task
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkAllHealth()
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
            }
        }

        log(.info, "[health] Health checks started (every 10s)")
    }

    /// Shutdown all pods
    func shutdown() async {
        healthCheckTask?.cancel()
        healthCheckTask = nil

        log(.info, "[shutdown] Shutting down all pods...")
        for (_, pod) in pods {
            if let containerId = pod.containerId {
                try? await docker.stopContainer(id: containerId)
                try? await docker.removeContainer(id: containerId)
            }
        }
        pods.removeAll()
    }
}
