import Foundation

enum LoadBalancingStrategy {
    case roundRobin
    case random
    case leastConnections
}

/// Routes traffic to healthy pods using configurable strategy
final class LoadBalancer: @unchecked Sendable {
    private var currentIndex: Int = 0
    private let strategy: LoadBalancingStrategy
    private let podManager: PodManager
    private let lock = NSLock()

    init(podManager: PodManager, strategy: LoadBalancingStrategy = .roundRobin) {
        self.podManager = podManager
        self.strategy = strategy
    }

    /// Get the next healthy pod to route traffic to
    func nextPod(forDeployment name: String) -> Pod? {
        let pods = podManager.healthyPods(forDeployment: name)
        guard !pods.isEmpty else { return nil }

        switch strategy {
        case .roundRobin:
            lock.lock()
            let pod = pods[currentIndex % pods.count]
            currentIndex += 1
            lock.unlock()
            return pod
        case .random:
            return pods.randomElement()
        case .leastConnections:
            return pods.first // Simplified - would track connections in real impl
        }
    }

    /// Get the address of the next healthy pod
    func nextAddress(forDeployment name: String) -> String? {
        nextPod(forDeployment: name)?.hostAddress
    }
}
