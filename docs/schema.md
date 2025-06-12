# ClodMesh Configuration Schema Specification

## Overview

The ClodMesh configuration schema is based on YAML 1.2 with extensions for component composition, dependency management, and connection topology. It draws inspiration from Docker Compose, Kubernetes manifests, and OpenAPI specifications.

## Schema Version

Current version: `1.0.0`

## Top-Level Structure

```yaml
# Required: Schema version
version: string

# Optional: Schema validation URL
schema: uri

# Optional: Metadata about this configuration
metadata:
  name: string
  description: string
  author: string
  license: string

# Optional: Global settings inherited by all components
globals:
  environment: object
  secrets: object
  logging: object

# Required: Component definitions
components: ComponentMap

# Optional: Connection topology (if not defined inline)
connections: ConnectionList

# Optional: Deployment configuration
deployment:
  strategy: string
  resources: ResourceRequirements
```

## Component Definition

Each component is defined with the following structure:

```yaml
components:
  component-name:              # Unique identifier within this config
    # Required: npm package name with optional version
    module: string            # Format: "@scope/package[@version]"
    
    # Optional: Inherit from another component definition
    extends: string           # Reference to another component
    
    # Optional: Component-specific configuration
    config: object           # Validated against component's schema
    
    # Optional: Environment variables
    environment:
      KEY: value
    
    # Optional: Resource requirements
    resources:
      memory: string         # E.g., "512Mi", "2Gi"
      cpu: string           # E.g., "100m", "2"
    
    # Optional: Health check configuration
    healthCheck:
      endpoint: string
      interval: duration
      timeout: duration
      retries: integer
    
    # Optional: Scaling configuration
    scaling:
      min: integer          # Minimum instances
      max: integer          # Maximum instances
      targetCPU: integer    # CPU percentage for autoscaling
    
    # Optional: Connection definitions
    connections:
      sends-to: string | [string]      # Target component(s)
      receives-from: string | [string] # Source component(s)
      protocol: string                 # Override default protocol
    
    # Optional: Named instances with config overrides
    instances:
      instance-name:
        config: object      # Overrides for this instance
        environment: object # Additional env vars
```

## Connection Definitions

Connections can be defined inline within components or separately:

```yaml
connections:
  - from: component-name[.instance-name]
    to: component-name[.instance-name]
    protocol: json-rpc | grpc | amqp | http
    pattern: request-reply | publish-subscribe | fire-forget
    config:
      timeout: duration
      retries: integer
      circuit-breaker:
        threshold: integer
        timeout: duration
```

## Data Types

### Duration
Format: `<number><unit>` where unit is `ms`, `s`, `m`, `h`
Examples: `100ms`, `30s`, `5m`, `1h`

### Resource Quantity
Format: `<number><unit>` where unit is `Ki`, `Mi`, `Gi` for memory, `m` for CPU
Examples: `256Mi`, `1Gi`, `100m`, `2`

### Module Reference
Format: `[@<scope>/]<package>[@<version>]`
Examples: 
- `ollama-connector`
- `@clodmesh/ollama-connector`
- `@clodmesh/ollama-connector@1.2.3`

## Inheritance and Composition

### YAML Anchors
Standard YAML anchors can be used for reuse:

```yaml
defaults: &defaults
  timeout: 30s
  retries: 3

components:
  service-a:
    module: "@clodmesh/service"
    config:
      <<: *defaults
      specific-setting: value
```

### Component Extension
Components can extend others:

```yaml
components:
  base-llm:
    module: "@clodmesh/ollama-connector"
    config:
      temperature: 0.7
      max_tokens: 2000
  
  alpha:
    extends: base-llm
    config:
      model: "llama3.1:8b"
      temperature: 0.5  # Override parent setting
```

## Variable Substitution

Environment variables can be referenced:

```yaml
components:
  database:
    module: "@clodmesh/postgres"
    config:
      host: ${DB_HOST:-localhost}
      port: ${DB_PORT:-5432}
      password: ${DB_PASSWORD:?Database password required}
```

Syntax:
- `${VAR}` - Use value of VAR
- `${VAR:-default}` - Use value of VAR or default if unset
- `${VAR:?error message}` - Fail if VAR is unset

## Schema Validation

Each component module should provide a JSON Schema for its configuration:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "properties": {
    "model": {
      "type": "string",
      "description": "The model identifier"
    },
    "temperature": {
      "type": "number",
      "minimum": 0,
      "maximum": 2,
      "default": 0.7
    }
  },
  "required": ["model"]
}
```

## Complete Example

```yaml
version: "1.0.0"
schema: "https://clodmesh.org/schemas/v1"

metadata:
  name: "ClodBrain Dual-LLM System"
  description: "A split-brain architecture with two LLMs"
  author: "Robert de Forest"

globals:
  environment:
    LOG_LEVEL: info
  logging:
    format: json
    output: stdout

components:
  # Base configuration for LLMs
  base-llm: &base-llm
    module: "@clodmesh/ollama-connector@2.0.0"
    resources:
      memory: "4Gi"
      cpu: "2"
    healthCheck:
      endpoint: "/health"
      interval: 30s
      timeout: 5s
      retries: 3

  # Logical hemisphere
  alpha:
    <<: *base-llm
    config:
      model: "llama3.1:8b-instruct-q4_K_M"
      system_prompt: |
        You are the logical, analytical hemisphere of a dual-AI system.
        Focus on structured thinking and factual analysis.
      temperature: 0.3
    connections:
      sends-to: coordinator

  # Creative hemisphere  
  beta:
    <<: *base-llm
    config:
      model: "qwen2.5-coder:7b-instruct-q4_K_M"
      system_prompt: |
        You are the creative, intuitive hemisphere of a dual-AI system.
        Focus on novel connections and imaginative solutions.
      temperature: 0.9
    connections:
      sends-to: coordinator

  # Message coordinator
  coordinator:
    module: "@clodmesh/message-coordinator@1.5.0"
    config:
      modes:
        - parallel
        - sequential
        - debate
        - synthesis
        - handoff
      default_mode: parallel
    connections:
      sends-to: [alpha, beta, memory, web-gateway]
      receives-from: [alpha, beta, web-gateway]

  # Knowledge graph storage
  memory:
    module: "@clodmesh/neo4j-adapter@3.1.0"
    config:
      uri: ${NEO4J_URI:-bolt://localhost:7687}
      username: ${NEO4J_USER:-neo4j}
      password: ${NEO4J_PASSWORD:?Neo4j password required}
    connections:
      receives-from: coordinator

  # Web interface
  web-gateway:
    module: "@clodmesh/express-gateway@2.0.0"
    config:
      port: ${PORT:-3000}
      cors:
        enabled: true
        origins: ["http://localhost:3000"]
      static:
        path: "./public"
        index: "index.html"
    connections:
      sends-to: coordinator
      receives-from: coordinator
    scaling:
      min: 2
      max: 10
      targetCPU: 70

# Explicit connection configurations
connections:
  - from: web-gateway
    to: coordinator
    protocol: json-rpc
    pattern: request-reply
    config:
      timeout: 30s
      
  - from: coordinator
    to: memory
    protocol: json-rpc
    pattern: fire-forget
    config:
      retry: 3

deployment:
  strategy: rolling-update
  resources:
    total-memory: "16Gi"
    total-cpu: "8"
```

## Validation Rules

1. **Component names** must be unique within a configuration
2. **Module references** must be valid npm package names
3. **Circular dependencies** in `extends` are forbidden
4. **Connection targets** must reference defined components
5. **Resource quantities** must not exceed deployment limits
6. **Required environment variables** must be provided

## Future Extensions

Planned extensions for future versions:

1. **Conditional components** based on environment
2. **Component templates** for common patterns  
3. **Multi-environment** configurations
4. **Secret management** integration
5. **Observability** configuration
6. **Policy definitions** for security and resource governance