import Vapor

/// Health check response structure
struct LoadBalancerHealth: Codable {
    /// Status of the load balancer: "healthy", "degraded", or "updating"
    let status: String
    /// Active pods per deployment, grouped by version
    let pods: [String: [String: Int]]
    /// List of deployments currently in a rolling update (nil if none)
    let rollingUpdates: [String]?
}

@main
struct MainLoadBalancer {
    static func main() async throws {
        let config = AppConfig.loadDefault()

        let podManager = PodManager(dockerConfig: config.docker)
        let loadBalancer = LoadBalancer(podManager: podManager, strategy: .roundRobin)
        let deployment = config.deployment

        // Create Vapor app using async API
        let app = try await Application.make(.detect())
        app.http.server.configuration.port = config.server.port
        app.http.server.configuration.hostname = config.server.host

        // Pass the HTTP client to the pod manager for health checks
        podManager.setClient(app.client)

        // Health check endpoint returning JSON status
        app.get("health") { _ -> Response in
            let podsByVersion = podManager.allPodCountsByVersion()
            let rollingUpdates = podManager.deploymentsInRollingUpdate

            let status: String
            if podManager.healthyPods.isEmpty {
                status = "degraded"
            } else if podManager.hasActiveRollingUpdate {
                status = "updating"
            } else {
                status = "healthy"
            }

            let healthResponse = LoadBalancerHealth(
                status: status,
                pods: podsByVersion,
                rollingUpdates: rollingUpdates.isEmpty ? nil : rollingUpdates
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(healthResponse)

            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: "application/json")
            return Response(status: .ok, headers: headers, body: .init(data: data))
        }

        // Proxy all other requests to backend pods
        app.get("**") { req async throws -> Response in
            return await proxyRequest(req, loadBalancer: loadBalancer, deployment: deployment.name)
        }

        app.post("**") { req async throws -> Response in
            return await proxyRequest(req, loadBalancer: loadBalancer, deployment: deployment.name)
        }

        print("[info] MyLoadBalancer - Mini Container Orchestrator")

        // Deploy pods on startup
        do {
            try await podManager.deploy(deployment)
            print("[status] Deployment: \(deployment.name), Replicas: \(deployment.replicas), Health checks: every \(Int(deployment.healthCheckInterval))s")
            print("[info] Load balancer listening on http://\(config.server.host):\(config.server.port)")
            print("[info] Routing traffic to healthy \(deployment.name) pods")
        } catch {
            print("[error] Failed to deploy: \(error)")
        }

        // Run the server
        try await app.execute()
        try await app.asyncShutdown()
    }
}
