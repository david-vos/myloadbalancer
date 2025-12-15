import Vapor

/// Performs HTTP health checks on pods
class HealthChecker {
    private let client: Client

    init(client: Client) {
        self.client = client
    }

    /// Check if a service is healthy by calling its health endpoint
    func check(host: String, port: Int, path: String) async -> Bool {
        let urlString = "http://\(host):\(port)\(path)"

        do {
            let response = try await client.get(URI(string: urlString))
            let isHealthy = (200 ..< 300).contains(response.status.code)
            if !isHealthy {
                // Log non-2xx responses for debugging
                print("[healthcheck] \(host):\(port)\(path) returned status \(response.status.code)")
            }
            return isHealthy
        } catch {
            // Log errors for debugging
            print("[healthcheck] \(host):\(port)\(path) failed: \(error)")
            return false
        }
    }
}
