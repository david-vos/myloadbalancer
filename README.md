# MyLoadBalancer

A mini container orchestrator and load balancer written in Swift. It automatically deploys Docker containers, performs health checks, and routes traffic to healthy pods using round-robin load balancing.

## What it does

- Deploys multiple replicas of a Docker container
- Health checks pods periodically and replaces unhealthy ones
- Load balances incoming HTTP requests across healthy pods
- Self-healing: automatically restarts failed containers

## Requirements

- Swift 5.9+
- Docker

## Usage

### Run locally

```bash
swift build
swift run
```

The load balancer starts on `http://localhost:8080` and deploys 2 nginx replicas by default.

### Run with Docker

```bash
docker compose up --build
```

This builds and runs the load balancer in a container, mounting the Docker socket so it can manage sibling containers.

## Configuration

Create a `config.json` file (see `config.example.json`):

```json
{
  "server": {
    "port": 8080,
    "host": "0.0.0.0"
  },
  "docker": {
    "executablePath": "/usr/bin/docker",
    "environment": {
      "DOCKER_HOST": "unix:///var/run/docker.sock"
    }
  },
  "deployment": {
    "name": "web",
    "image": "nginx:alpine",
    "replicas": 2,
    "containerPort": 80,
    "healthCheckPath": "/",
    "healthCheckInterval": 10
  }
}
```

The app searches for config in these locations:
1. `./config.json`
2. `./appconfig.json`
3. `/etc/myloadbalancer/config.json`

### Config options

#### Server
- `port` - Port the load balancer listens on (default: 8080)
- `host` - Host to bind to (default: "0.0.0.0")

#### Docker
- `executablePath` - Path to docker executable (default: "/usr/bin/docker")
- `environment` - Additional environment variables for docker commands

#### Deployment

**Using a pre-built image:**
```json
{
  "deployment": {
    "name": "web",
    "image": "nginx:alpine",
    "replicas": 2,
    "containerPort": 80,
    "healthCheckPath": "/",
    "healthCheckInterval": 10
  }
}
```

**Building from a Dockerfile:**
```json
{
  "deployment": {
    "name": "myapp",
    "dockerfile": "./Dockerfile",
    "context": ".",
    "replicas": 3,
    "containerPort": 3000,
    "healthCheckPath": "/health",
    "healthCheckInterval": 10
  }
}
```

This will run `docker build` before starting the containers, so you can deploy any app you'd normally run with `docker compose up --build`.

## Endpoints

- `GET /health` - Load balancer health check
- `GET /**` - Proxied to backend pods
- `POST /**` - Proxied to backend pods
