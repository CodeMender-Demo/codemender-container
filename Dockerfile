# ==============================================================================
# CodeMender Headless Scanner Container
# ==============================================================================
FROM debian:bookworm-slim

LABEL description="Headless Google Cloud CodeMender scanner with Workload Identity Federation"

ARG CM_VERSION=stable

# Install core runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    openssh-client \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Download and install the CodeMender CLI (Linux x86_64)
RUN curl -fsSL -o /tmp/cm-linux-amd64.zip \
    "https://artifactregistry.googleapis.com/download/v1/projects/cmoc-prod/locations/us/repositories/codemender-cli-production/files/cm%3A${CM_VERSION}%3Acm-linux-amd64.zip:download?alt=media" \
    && unzip -q /tmp/cm-linux-amd64.zip -d /tmp/cm-dist \
    && chmod +x /tmp/cm-dist/cm \
    && mv /tmp/cm-dist/cm /usr/local/bin/cm \
    && rm -rf /tmp/cm-linux-amd64.zip /tmp/cm-dist \
    && cm init    

# Create required operational directories
RUN mkdir -p /workspace /output /secrets

# Copy entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Default environment configuration
ENV GOOGLE_APPLICATION_CREDENTIALS=/secrets/credential-configuration.json \
    CM_MODEL=gemini-3.8-flash \
    CM_FIND_MODE=standard \
    OUTPUT_FILENAME=$FOLDER-findings.json \
    GIT_BRANCH=main \
    GIT_USERNAME=git

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
