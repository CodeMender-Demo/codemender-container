#!/usr/bin/env bash

# ==============================================================================
# CodeMender Headless Container Entrypoint
# ==============================================================================

log_info()  { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn()  { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }
log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

# ------------------------------------------------------------------------------
# 1. Pre-flight & Credential Validation
# ------------------------------------------------------------------------------
log_info "Performing pre-flight checks..."

# Verify /output directory is mounted and writable
if [ ! -d "/output" ] || [ ! -w "/output" ]; then
  log_error "The /output directory is not mounted or not writable. Mount a host directory using: -v \$(pwd)/output:/output"
  exit 2
fi

# Verify and resolve Google Service Account Key credentials
GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS:-/secrets/sa-key.json}"

# Fallback to /secrets/sa-key.json if default path does not exist
if [ ! -f "${GOOGLE_APPLICATION_CREDENTIALS}" ] && [ -f "/secrets/sa-key.json" ]; then
  GOOGLE_APPLICATION_CREDENTIALS="/secrets/sa-key.json"
fi

if [ ! -f "${GOOGLE_APPLICATION_CREDENTIALS}" ] || [ ! -r "${GOOGLE_APPLICATION_CREDENTIALS}" ]; then
  log_error "Google Service Account Key not found or not readable at: '${GOOGLE_APPLICATION_CREDENTIALS}'"
  log_error "Mount your Service Account JSON key using: -v \$(pwd)/sa-key.json:/secrets/sa-key.json:ro"
  exit 2
fi

# Validate file is a Google Service Account key
if ! grep -q '"type": *"service_account"' "${GOOGLE_APPLICATION_CREDENTIALS}" 2>/dev/null; then
  log_error "Credentials file at '${GOOGLE_APPLICATION_CREDENTIALS}' is not a valid Google Cloud Service Account JSON key."
  exit 2
fi

SA_EMAIL=$(grep -o '"client_email": *"[^"]*"' "${GOOGLE_APPLICATION_CREDENTIALS}" | head -n1 | cut -d'"' -f4 || true)
if [ -n "${SA_EMAIL}" ]; then
  log_info "Using Google Cloud Service Account: ${SA_EMAIL}"
else
  log_info "Using Google Cloud Service Account Key at: ${GOOGLE_APPLICATION_CREDENTIALS}"
fi

# Auto-detect GOOGLE_CLOUD_PROJECT from Service Account key if not set
if [ -z "${GOOGLE_CLOUD_PROJECT:-}" ]; then
  DETECTED_PROJECT=$(grep -o '"project_id": *"[^"]*"' "${GOOGLE_APPLICATION_CREDENTIALS}" | head -n1 | cut -d'"' -f4 || true)
  if [ -n "${DETECTED_PROJECT}" ]; then
    GOOGLE_CLOUD_PROJECT="${DETECTED_PROJECT}"
    log_info "Auto-detected GOOGLE_CLOUD_PROJECT='${GOOGLE_CLOUD_PROJECT}' from Service Account key."
  fi
fi

# Verify GOOGLE_CLOUD_PROJECT is set
if [ -z "${GOOGLE_CLOUD_PROJECT:-}" ]; then
  log_error "GOOGLE_CLOUD_PROJECT must be specified or defined in the Service Account key."
  exit 2
fi

export GOOGLE_APPLICATION_CREDENTIALS
export GOOGLE_CLOUD_PROJECT
export CLOUDSDK_CORE_PROJECT="${GOOGLE_CLOUD_PROJECT}"

# Verify REPO_URL is populated
if [ -z "${REPO_URL:-}" ]; then
  log_error "REPO_URL environment variable must be provided."
  exit 2
fi

# Default environment variables
GIT_BRANCH="${GIT_BRANCH:-main}"
GIT_USERNAME="${GIT_USERNAME:-oauth2}"
CM_MODEL="${CM_MODEL:-gemini-3.8-flash}"
OUTPUT_FILENAME="${OUTPUT_FILENAME:-findings.json}"

# ------------------------------------------------------------------------------
# 2. Git Authentication & Cloning
# ------------------------------------------------------------------------------

# Sanitize repository URL for log output
SANITIZED_URL=$(echo "${REPO_URL}" | sed -E 's#(https?://)[^@]+@#\1***@#g')
log_info "Cloning repository from: ${SANITIZED_URL} (branch/ref: ${GIT_BRANCH})"

git clone https://$GIT_TOKEN@$REPO_URL --depth=1

# ------------------------------------------------------------------------------
# 3. CodeMender Workspace Configuration
# ------------------------------------------------------------------------------
FOLDER_NAME=$(basename "$REPO_URL" .git)
echo "The repository was cloned into: $FOLDER_NAME"
cd "$FOLDER_NAME"

cat <<EOF > ~/.codemender/config.yaml
# CodeMender CLI configuration.
# The server endpoint is baked in at build time (see build profiles).
# Override it here only if you need a different endpoint.

server: {}

# Customer-supplied team identifier sent as the X-CodeMender-Team-Id
# telemetry header. Overridden by --team-id flag or $CM_TEAM_ID env var.
# Max 63 chars, must match [A-Za-z0-9._-]. Omit to skip the header.
# team_id: "acme-security"

scan:
  extensions:
    include: [".py", ".java", ".go", ".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".c", ".cc", ".cpp", ".cxx", ".h", ".hpp", ".cs", ".rs", ".kt", ".kts", ".rb", ".php", ".sol", ".tf", ".hcl", ".erb", ".haml", ".rake", ".ru", ".pl", ".pm", ".sh", ".bash", ".ex", ".exs", ".eex", ".heex", ".sql", ".bat", ".ps1"]
    exclude: [".min.js", ".generated.go", ".pb.go"]
  max_file_size_kb: 500
  incremental: true

# Restrict agent file access to these directories (all commands).
# When empty, the scan target directory is used as the boundary.
# project_paths:
#   - "/home/admin_adamhlevy_altostrat_com/VulnerableApp"
#   - "/path/to/shared-lib"

output:
  format: table   # "table", "json", "sarif"

sandbox:
  enabled: false

tools:
  confirm_commands: false
  confirm_writes: false

vcs:
  type: ""               # VCS type: "git", "mercurial", "custom", or "" (auto-detect)
  commands:
    reset: ""            # Shell command to reset codebase (auto-populated for known VCS)
    diff: ""             # Shell command to show changes (auto-populated for known VCS)
    status: ""           # Shell command to list modified files (auto-populated for known VCS)
    stage: ""            # Shell command to stage changes (auto-populated for known VCS)
  # Known VCS types (git, mercurial) auto-populate commands.
  # For custom VCS, you MUST set the commands above.
  # Examples:
  #   type: git           # uses: git checkout HEAD -- . && git clean -fd
  #   type: mercurial     # uses: hg revert --all --no-backup && hg purge
  #   type: custom
  #   commands:
  #     reset: "./scripts/reset.sh"
  #     diff: "diff -rq baseline/ current/"
  #     stage: "git add -A"

build:
  command: ""              # Shell command to build/verify changes from the agent
  # Examples:
  #   Make:       "make build && make test"
  #   Go:         "go build ./... && go test ./..."
  #   Custom:     "./scripts/verify.sh"
EOF


# ------------------------------------------------------------------------------
# 4. Vulnerability Scanning (cm find)
# ------------------------------------------------------------------------------
OUTPUT_FILE_PATH="/output/${OUTPUT_FILENAME}"
log_info "Starting CodeMender scan. Repository: $FOLDER_NAME"

cm --sandbox=false --bypass-warning find . --model "$CM_MODEL" || true

# ------------------------------------------------------------------------------
# 5. Post-Processing & Output 
# ------------------------------------------------------------------------------
log_info "Writing findings report to $OUTPUT_FILE_PATH"
cm report -f json > $OUTPUT_FILE_PATH

log_info "CodeMender container execution finished successfully."
exit 0
