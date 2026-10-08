# CodeMender Headless Scanner Container

This guide provides end-to-end instructions for building, configuring, and running the containerized **Google Cloud CodeMender Scanner**.

CodeMender is an AI-powered code security agent from Google Cloud that leverages advanced reasoning models (such as `gemini-3.8-flash`) to detect, analyze, and remediate security vulnerabilities in source code. This container packages the CodeMender CLI (`cm`) and its runtime dependencies into a headless, automated Docker environment suitable for local machines, on-premises infrastructure, and automated CI/CD pipelines.

---

## Table of Contents

- [CodeMender Headless Scanner Container: Customer User Guide](#codemender-headless-scanner-container-customer-user-guide)
  - [Table of Contents](#table-of-contents)
  - [1. Architecture Overview](#1-architecture-overview)
  - [2. Prerequisites](#2-prerequisites)
    - [Docker Environment](#docker-environment)
    - [Google Cloud Project \& Service Account](#google-cloud-project--service-account)
    - [Git Provider Access Token](#git-provider-access-token)
    - [Network Connectivity Requirements](#network-connectivity-requirements)
  - [3. Building the Container Image](#3-building-the-container-image)
    - [Standard Build (Linux x86\_64)](#standard-build-linux-x86_64)
    - [Building on Apple Silicon (M1/M2/M3/M4)](#building-on-apple-silicon-m1m2m3m4)
    - [Specifying CLI Version](#specifying-cli-version)
  - [4. Container Configuration](#4-container-configuration)
    - [Volume Mounts](#volume-mounts)
    - [Environment Variables](#environment-variables)
  - [5. Running the Container](#5-running-the-container)
    - [Quick Start Example](#quick-start-example)
    - [Scanning a Specific Branch](#scanning-a-specific-branch)
    - [Using a Different Reasoning Model](#using-a-different-reasoning-model)
    - [Running with an Environment File (`.env`)](#running-with-an-environment-file-env)
  - [6. Scan Output and Findings](#6-scan-output-and-findings)
    - [Output Location](#output-location)
    - [Inspecting Results with `jq`](#inspecting-results-with-jq)
      - [1. Check scan summary or count of findings:](#1-check-scan-summary-or-count-of-findings)
      - [2. List vulnerabilities by severity, category, and file location:](#2-list-vulnerabilities-by-severity-category-and-file-location)
      - [3. View critical and high severity findings:](#3-view-critical-and-high-severity-findings)
  - [7. Security Best Practices](#7-security-best-practices)
  - [8. Troubleshooting \& FAQ](#8-troubleshooting--faq)
    - [1. `[ERROR] The /output directory is not mounted or not writable.`](#1-error-the-output-directory-is-not-mounted-or-not-writable)
    - [2. `[ERROR] Google Service Account Key not found or not readable...`](#2-error-google-service-account-key-not-found-or-not-readable)
    - [3. `[ERROR] Credentials file ... is not a valid Google Cloud Service Account JSON key.`](#3-error-credentials-file--is-not-a-valid-google-cloud-service-account-json-key)
    - [4. `fatal: unable to access 'https://***@https://github.com/...': Could not resolve host: https:`](#4-fatal-unable-to-access-httpshttpsgithubcom-could-not-resolve-host-https)
    - [5. `403 Forbidden` / `Vertex AI API has not been used in project...`](#5-403-forbidden--vertex-ai-api-has-not-been-used-in-project)
    - [6. Permission Denied: `caller does not have required permission aiplatform.endpoints.predict`](#6-permission-denied-caller-does-not-have-required-permission-aiplatformendpointspredict)

---

## 1. Architecture Overview

When the container runs, it performs an automated sequence:

```
+---------------------------------------------------------------------------------------+
| Customer Host / CI Runner                                                             |
|                                                                                       |
|   Directories on Host:                                                                |
|     • ./output/                 <-- Receives vulnerability findings JSON              |
|     • ./secrets/sa-key.json     <-- Google Cloud Service Account private key          |
|                                                                                       |
|   +-------------------------------------------------------------------------------+   |
|   | CodeMender Container (Docker)                                                 |   |
|   |                                                                               |   |
|   |   1. Pre-flight checks: validates /output write permissions and sa-key.json       |   |
|   |   2. Git clone: shallow clones private repo via HTTPS token into /workspace   |   |
|   |   3. Configuration: provisions ~/.codemender/config.yaml (headless mode)      |   |
|   |   4. AI Scan: executes 'cm --sandbox=false --bypass-warning find .'           |   |
|   |   5. Export: generates JSON report via 'cm report -f json' > /output/...      |   |
|   +-------------------------------------------------------------------------------+   |
|                                     |                                                 |
|                                     | HTTPS (TCP 443)                                 |
|                                     v                                                 |
|        Google Cloud Vertex AI & IAM (oauth2.googleapis.com, aiplatform.googleapis.com) |
+---------------------------------------------------------------------------------------+
```

---

## 2. Prerequisites

### Docker Environment
- Docker Engine 20.10+ or Docker Desktop installed and running.
- Container architecture is `linux/amd64` (supported on Linux x86_64, Windows, and macOS via emulation).

### Google Cloud Project & Service Account

1. **Google Cloud Project**: You need an active Google Cloud project with billing enabled.
2. **Enable Required APIs**:
   ```bash
   gcloud services enable \
     aiplatform.googleapis.com \
     cloudresourcemanager.googleapis.com \
     --project="YOUR_PROJECT_ID"
   ```
3. **Create Service Account**:
   ```bash
   gcloud iam service-accounts create codemender-runner \
     --display-name="CodeMender Scanner Runner" \
     --project="YOUR_PROJECT_ID"
   ```
4. **Grant Vertex AI User Role**:
   ```bash
   gcloud projects add-iam-policy-binding "YOUR_PROJECT_ID" \
     --member="serviceAccount:codemender-runner@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
     --role="roles/aiplatform.user"
   ```
5. **Generate Service Account Key**:
   ```bash
   gcloud iam service-accounts keys create ./sa-key.json \
     --iam-account="codemender-runner@YOUR_PROJECT_ID.iam.gserviceaccount.com"
   ```
   > [!IMPORTANT]
   > Keep `sa-key.json` secure. Do not commit it to version control. Restrict its permissions on the host:
   > ```bash
   > chmod 600 ./sa-key.json
   > ```

### Git Provider Access Token
Generate a read-only Personal Access Token (PAT) from your Git provider:
- **GitHub**: Fine-grained PAT with **Contents: Read-only** (or classic token with `repo` scope).
- **GitLab**: Project Access Token or Personal Access Token with `read_repository` scope.
- **Bitbucket**: Repository Access Token with `repository:read` permission.

### Network Connectivity Requirements
The host and container must be able to make outbound HTTPS requests (TCP port 443) to:
- `oauth2.googleapis.com` (Google OAuth authentication)
- `aiplatform.googleapis.com` (Vertex AI CodeMender reasoning backend)
- `cloudresourcemanager.googleapis.com` (Project resource verification)
- `artifactregistry.googleapis.com` (During Docker build for CLI download)
- Your Git hosting provider domain (e.g., `github.com`, `gitlab.com`, or private server)

---

## 3. Building the Container Image

Navigate to the directory containing `Dockerfile` and `entrypoint.sh`:

### Standard Build (Linux x86_64)

```bash
docker build -t codemender-scanner:latest .
```

### Building on Apple Silicon (M1/M2/M3/M4)
Because the CodeMender CLI distribution is built for `linux/amd64`, use `--platform linux/amd64` when building on ARM-based Macs:

```bash
docker build --platform linux/amd64 -t codemender-scanner:latest .
```

### Specifying CLI Version
To build with a specific version of the CodeMender CLI (defaults to `stable`):

```bash
docker build --build-arg CM_VERSION=stable -t codemender-scanner:latest .
```

---

## 4. Container Configuration

### Volume Mounts

The container requires two host mounts:

| Host Path | Container Target | Mode | Description |
| :--- | :--- | :--- | :--- |
| `$(pwd)/output` | `/output` | Read/Write (`rw`) | **Required**. Host directory where JSON finding reports will be saved. Must be writable by the container. |
| `$(pwd)/sa-key.json` | `/secrets/sa-key.json` | Read-Only (`:ro`) | **Required**. Google Cloud Service Account JSON key. |

### Environment Variables

| Variable | Required | Default | Description | Example |
| :--- | :---: | :---: | :--- | :--- |
| `REPO_URL` | **Yes** | — | Target Git repository URL without protocol prefix when using `GIT_TOKEN`. | `github.com/my-org/my-service.git` |
| `GIT_TOKEN` | **Yes** | — | Personal Access Token (PAT) used to clone private repositories. | `ghp_xxxxxxxxxxxx` |
| `GIT_BRANCH` | No | `main` | Branch, tag, or commit ref to scan. | `develop`, `release/v2.1` |
| `GIT_USERNAME` | No | `oauth2` | Git authentication username. | `oauth2`, `x-access-token` |
| `GOOGLE_APPLICATION_CREDENTIALS` | No | `/secrets/sa-key.json` | In-container path to the Service Account key. | `/secrets/sa-key.json` |
| `GOOGLE_CLOUD_PROJECT` | No | *Auto-detected* | Google Cloud Project ID. Automatically extracted from `sa-key.json` if omitted. | `my-sec-project-123` |
| `CM_MODEL` | No | `gemini-3.8-flash` | Reasoning model for vulnerability detection. | `gemini-3.8-flash`, `gemini-3.1-pro-preview` |
| `OUTPUT_FILENAME` | No | `findings.json` | Name of the output JSON report file inside `/output`. | `my-repo-findings.json` |

> [!TIP]
> **Repository URL Format with `GIT_TOKEN`**:
> The entrypoint script clones using `https://$GIT_TOKEN@$REPO_URL`.
> Supply `REPO_URL` in the format: `github.com/<org>/<repository>.git` (omit the `https://` prefix so the token integrates cleanly into the URL).

---

## 5. Running the Container

Ensure your host output directory exists before running:
```bash
mkdir -p ./output
```

### Quick Start Example

Run a scan against the `main` branch of a private GitHub repository:

```bash
docker run --rm \
  --platform linux/amd64 \
  -v $(pwd)/output:/output \
  -v $(pwd)/sa-key.json:/secrets/sa-key.json:ro \
  -e REPO_URL="github.com/my-org/my-service.git" \
  -e GIT_TOKEN="${GITHUB_PAT}" \
  codemender-scanner:latest
```

### Scanning a Specific Branch

```bash
docker run --rm \
  --platform linux/amd64 \
  -v $(pwd)/output:/output \
  -v $(pwd)/sa-key.json:/secrets/sa-key.json:ro \
  -e REPO_URL="github.com/my-org/my-service.git" \
  -e GIT_BRANCH="feature/payments-v2" \
  -e GIT_TOKEN="${GITHUB_PAT}" \
  -e OUTPUT_FILENAME="payments-v2-findings.json" \
  codemender-scanner:latest
```

### Using a Different Reasoning Model

To utilize an advanced reasoning model (e.g. `gemini-3.1-pro-preview`):

```bash
docker run --rm \
  --platform linux/amd64 \
  -v $(pwd)/output:/output \
  -v $(pwd)/sa-key.json:/secrets/sa-key.json:ro \
  -e REPO_URL="github.com/my-org/my-service.git" \
  -e GIT_TOKEN="${GITHUB_PAT}" \
  -e CM_MODEL="gemini-3.1-pro-preview" \
  -e OUTPUT_FILENAME="deep-scan-findings.json" \
  codemender-scanner:latest
```

### Running with an Environment File (`.env`)

For repeated runs or automated scripts, create a local `.env` file (ensure `.env` is in your `.gitignore`):

```env
REPO_URL=github.com/my-org/my-service.git
GIT_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
GIT_BRANCH=main
CM_MODEL=gemini-3.8-flash
OUTPUT_FILENAME=my-repo-findings.json
```

Then execute:

```bash
docker run --rm \
  --platform linux/amd64 \
  --env-file .env \
  -v $(pwd)/output:/output \
  -v $(pwd)/sa-key.json:/secrets/sa-key.json:ro \
  codemender-scanner:latest
```

---

## 6. Scan Output and Findings

### Output Location
When the scan finishes, findings are saved to:
```text
./output/<OUTPUT_FILENAME> (default: ./output/findings.json)
```

### Inspecting Results with `jq`

You can inspect the generated JSON report using standard CLI tools:

#### 1. Check scan summary or count of findings:
```bash
cat output/findings.json | jq '.findings | length'
```

#### 2. List vulnerabilities by severity, category, and file location:
```bash
cat output/findings.json | jq -r '.findings[] | "[\(.severity)] \(.title) - \(.location.file):\(.location.line)"'
```

#### 3. View critical and high severity findings:
```bash
cat output/findings.json | jq '.findings[] | select(.severity == "CRITICAL" or .severity == "HIGH")'
```

---

## 7. Security Best Practices

1. **Read-Only Secret Mount**: Always mount the Google Service Account key with the `:ro` flag.
2. **Ephemeral Containers**: Always run with the `--rm` flag to guarantee that ephemeral repository clones and temporary tokens are discarded immediately upon completion.
3. **Least Privilege**:
   - Limit the Google Service Account IAM role to **Vertex AI User** (`roles/aiplatform.user`).
   - Limit the Git Personal Access Token strictly to **read-only** repository contents.
4. **Key Rotation**: Rotate Google Service Account keys on a regular cadence (30–90 days).
5. **No Baked Secrets**: Never use `ADD` or `COPY` to bake `sa-key.json` or Git tokens into the Docker image. Always inject credentials dynamically at runtime via mounts and environment variables.

---

## 8. Troubleshooting & FAQ

### 1. `[ERROR] The /output directory is not mounted or not writable.`
- **Cause**: The host directory was not mounted to `/output` or permissions prevent container writing.
- **Solution**:
  ```bash
  mkdir -p ./output && chmod 777 ./output
  # Re-run with: -v $(pwd)/output:/output
  ```

### 2. `[ERROR] Google Service Account Key not found or not readable...`
- **Cause**: The file `sa-key.json` is missing on the host or the volume mount path is incorrect.
- **Solution**: Ensure your key exists on the host and is mounted to `/secrets/sa-key.json`:
  ```bash
  ls -la ./sa-key.json
  # Pass: -v $(pwd)/sa-key.json:/secrets/sa-key.json:ro
  ```

### 3. `[ERROR] Credentials file ... is not a valid Google Cloud Service Account JSON key.`
- **Cause**: The mounted file is either empty or does not contain `"type": "service_account"`.
- **Solution**: Verify the file is an authentic Google Cloud Service Account key downloaded from GCP Console or `gcloud iam service-accounts keys create`.

### 4. `fatal: unable to access 'https://***@https://github.com/...': Could not resolve host: https:`
- **Cause**: `REPO_URL` was specified with a leading `https://`.
- **Solution**: Supply `REPO_URL` without `https://` (e.g., `-e REPO_URL="github.com/owner/repo.git"`).

### 5. `403 Forbidden` / `Vertex AI API has not been used in project...`
- **Cause**: The Vertex AI API is not enabled in your Google Cloud project.
- **Solution**:
  ```bash
  gcloud services enable aiplatform.googleapis.com --project="YOUR_PROJECT_ID"
  ```

### 6. Permission Denied: `caller does not have required permission aiplatform.endpoints.predict`
- **Cause**: The Service Account lacks the `roles/aiplatform.user` IAM role.
- **Solution**:
  ```bash
  gcloud projects add-iam-policy-binding "YOUR_PROJECT_ID" \
    --member="serviceAccount:codemender-runner@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/aiplatform.user"
  ```
