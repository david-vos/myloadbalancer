import Foundation
import Vapor

/// Pod info for health check response
struct PodInfo: Codable {
    let id: String
    let name: String
    let status: String
    let version: String
}

/// Health check response structure
struct LoadBalancerHealth: Codable {
    /// Status of the load balancer: "healthy", "degraded", or "updating"
    let status: String
    /// Detailed info for each pod, grouped by deployment
    let pods: [String: [PodInfo]]
    /// List of deployments currently in a rolling update (nil if none)
    let rollingUpdates: [String]?
}

/// Lifecycle handler to clean up pods on shutdown
struct PodManagerLifecycle: LifecycleHandler {
    let podManager: PodManager
    let logger: Logger

    func shutdown(_ app: Application) {
        logger.info("[shutdown] Cleaning up pods...")
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await podManager.shutdown()
            semaphore.signal()
        }
        // Wait up to 30 seconds for cleanup
        _ = semaphore.wait(timeout: .now() + 30)
        logger.info("[shutdown] Cleanup complete")
    }
}

@main
struct MainLoadBalancer {
    static func main() async throws {
        let config = try AppConfig.loadDefault()

        let podManager = PodManager(dockerConfig: config.docker)
        let loadBalancer = LoadBalancer(podManager: podManager, strategy: .roundRobin)
        let deployment = config.deployment

        // Create Vapor app using async API
        let app = try await Application.make(.detect())
        app.http.server.configuration.port = config.server.port
        app.http.server.configuration.hostname = config.server.host

        // Pass the HTTP client and logger to the pod manager
        podManager.setClient(app.client)
        podManager.setLogger(app.logger)

        // Setup lifecycle handler for graceful shutdown
        app.lifecycle.use(PodManagerLifecycle(podManager: podManager, logger: app.logger))

        // Health check endpoint returning JSON status
        app.get("health") { _ -> Response in
            let podsInfo = podManager.allPodsInfo()
            let rollingUpdates = podManager.deploymentsInRollingUpdate

            let status: String
            if podManager.healthyPods.isEmpty {
                status = "degraded"
            } else if podManager.hasActiveRollingUpdate {
                status = "updating"
            } else {
                status = "healthy"
            }

            // Convert to PodInfo structs
            var pods: [String: [PodInfo]] = [:]
            for (deployment, podList) in podsInfo {
                pods[deployment] = podList.map { pod in
                    PodInfo(id: pod.id, name: pod.name, status: pod.status, version: pod.version)
                }
            }

            let healthResponse = LoadBalancerHealth(
                status: status,
                pods: pods,
                rollingUpdates: rollingUpdates.isEmpty ? nil : rollingUpdates
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(healthResponse)

            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: "application/json")
            return Response(status: .ok, headers: headers, body: .init(data: data))
        }

        // Proxy root path
        app.get { req async throws -> Response in
            return await proxyRequest(req, loadBalancer: loadBalancer, deployment: deployment.name)
        }

        // Proxy all other requests to backend pods
        app.get("**") { req async throws -> Response in
            return await proxyRequest(req, loadBalancer: loadBalancer, deployment: deployment.name)
        }

        app.post { req async throws -> Response in
            return await proxyRequest(req, loadBalancer: loadBalancer, deployment: deployment.name)
        }

        app.post("**") { req async throws -> Response in
            return await proxyRequest(req, loadBalancer: loadBalancer, deployment: deployment.name)
        }

        app.logger.info("[info] MyLoadBalancer - Mini Container Orchestrator")

        // Clean up any orphaned containers from previous crashes
        await podManager.cleanupOrphanedContainers()

        // Deploy pods on startup
        do {
            try await podManager.deploy(deployment)
            app.logger.info("[status] Deployment: \(deployment.name), Replicas: \(deployment.replicas), Health checks: every \(Int(deployment.healthCheckInterval))s")
            app.logger.info("[info] Load balancer listening on http://\(config.server.host):\(config.server.port)")
            app.logger.info("[info] Routing traffic to healthy \(deployment.name) pods")
        } catch {
            app.logger.error("[error] Failed to deploy: \(error)")
        }

        // Run the server
        try await app.execute()
        try await app.asyncShutdown()
    }
}
