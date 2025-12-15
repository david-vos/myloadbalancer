import Vapor

/// Proxy an incoming request to a healthy backend pod
func proxyRequest(_ request: Request, loadBalancer: LoadBalancer, deployment: String) async -> Response {
    guard let backendAddress = loadBalancer.nextAddress(forDeployment: deployment) else {
        return Response(
            status: .serviceUnavailable,
            body: .init(string: "No healthy backends available")
        )
    }

    let path = request.url.path
    let urlString = "http://\(backendAddress)\(path)"

    request.logger.debug("[proxy] Proxying \(request.method) \(path) -> \(backendAddress)")

    do {
        // Build headers without host
        var proxyHeaders = request.headers
        proxyHeaders.remove(name: .host)

        // Use Vapor's built-in client
        let clientResponse = try await request.client.send(
            request.method,
            headers: proxyHeaders,
            to: URI(string: urlString),
            beforeSend: { clientRequest in
                clientRequest.body = request.body.data
            }
        )

        var headers = clientResponse.headers
        // Remove transfer-encoding as Vapor handles this
        headers.remove(name: .transferEncoding)

        return Response(
            status: clientResponse.status,
            headers: headers,
            body: .init(buffer: clientResponse.body ?? ByteBuffer())
        )
    } catch {
        request.logger.error("[error] Proxy error: \(error)")
        return Response(
            status: .badGateway,
            body: .init(string: "Backend error: \(error.localizedDescription)")
        )
    }
}
