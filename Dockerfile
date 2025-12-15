# Build stage
FROM swift:6.2.1 AS builder

WORKDIR /app

# Copy package files first for better caching
COPY Package.swift .

# Copy source code
COPY Sources/ Sources/

# Build the application in release mode
RUN swift build -c release

# Runtime stage
FROM swift:6.2.1-slim

# Install Docker CLI (we'll mount the docker socket)
RUN apt-get update && apt-get install -y \
    docker.io \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the built executable
COPY --from=builder /app/.build/release/myloadbalancer .

# Expose the load balancer port
EXPOSE 8080

# Run the application
CMD ["./myloadbalancer"]
