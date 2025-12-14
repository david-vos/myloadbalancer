import Foundation

/// Simple Docker client using CLI commands
class DockerClient {
    private let executablePath: String
    private let environment: [String: String]?

    enum DockerError: Error, CustomStringConvertible {
        case commandFailed(String)
        case containerNotFound
        case buildFailed(String)

        var description: String {
            switch self {
            case let .commandFailed(msg): return "Docker command failed: \(msg)"
            case .containerNotFound: return "Container not found"
            case let .buildFailed(msg): return "Docker build failed: \(msg)"
            }
        }
    }

    init(config: DockerConfig = .default) {
        self.executablePath = config.executablePath
        self.environment = config.environment
    }

    /// Build an image from a Dockerfile
    func buildImage(
        dockerfile: String,
        context: String,
        tag: String
    ) async throws {
        let args = [
            "build",
            "-f", dockerfile,
            "-t", tag,
            context,
        ]

        print("[build] Building image \(tag) from \(dockerfile)...")
        let output = try await execute(args, timeout: 600) // 10 min timeout for builds
        
        // Check if build succeeded by looking for the image
        let checkArgs = ["image", "inspect", tag]
        do {
            _ = try await execute(checkArgs)
            print("[build] Image \(tag) built successfully")
        } catch {
            throw DockerError.buildFailed(output)
        }
    }

    /// Run a new container and return its ID
    func runContainer(
        image: String,
        name: String,
        hostPort: Int,
        containerPort: Int
    ) async throws -> String {
        let args = [
            "run", "-d",
            "--name", name,
            "-p", "\(hostPort):\(containerPort)",
            image,
        ]

        let output = try await execute(args)
        let containerId = output.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !containerId.isEmpty else {
            throw DockerError.commandFailed("No container ID returned")
        }

        return containerId
    }

    /// Stop a running container
    func stopContainer(id: String) async throws {
        _ = try await execute(["stop", "-t", "5", id])
    }

    /// Remove a container
    func removeContainer(id: String) async throws {
        _ = try await execute(["rm", "-f", id])
    }

    /// Check if a container is running
    func isRunning(id: String) async -> Bool {
        do {
            let output = try await execute(["inspect", "-f", "{{.State.Running}}", id])
            return output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        } catch {
            return false
        }
    }

    /// List containers matching a name prefix
    func listContainers(prefix: String) async throws -> [String] {
        let output = try await execute([
            "ps", "-a",
            "--filter", "name=\(prefix)",
            "--format", "{{.ID}}",
        ])

        return output
            .split(separator: "\n")
            .map { String($0) }
    }

    /// Execute a docker command
    private func execute(_ args: [String], timeout: TimeInterval = 30) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = pipe

            // Set custom environment if provided
            if let environment = environment {
                var env = ProcessInfo.processInfo.environment
                for (key, value) in environment {
                    env[key] = value
                }
                process.environment = env
            }

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: DockerError.commandFailed(output))
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
