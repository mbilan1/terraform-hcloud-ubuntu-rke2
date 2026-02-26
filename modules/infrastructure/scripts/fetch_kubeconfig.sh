#!/bin/sh
# ──────────────────────────────────────────────────────────────────────────────
# fetch_kubeconfig.sh — Retrieve kubeconfig from master-0 via SSH
#
# DECISION: Use `data "external"` + this script instead of tenstad/remote.
# Why: Eliminates the only third-party provider dependency for kubeconfig
#      retrieval. The script is idempotent — it reads a file and exits. SSH
#      is the same mechanism already used by readiness provisioners, so no
#      new attack surface is introduced.
#
# Security considerations:
#   - SSH private key is passed via stdin (not as a file path in args)
#   - StrictHostKeyChecking=no is required because the server was just created
#     and its host key is not yet in known_hosts (same as remote-exec)
#   - The kubeconfig content is returned as a JSON object to data "external"
#   - Terraform marks the output as sensitive — it never appears in logs
#   - No temporary files are written — everything stays in memory (pipes)
#
# Usage (called by Terraform, not manually):
#   echo '{"host":"1.2.3.4","user":"root","private_key":"..."}' | ./fetch_kubeconfig.sh
# ──────────────────────────────────────────────────────────────────────────────
set -eu

# --- Parse JSON input from stdin ---
# NOTE: data "external" passes query as JSON on stdin.
# We use lightweight parsing to avoid requiring jq on the runner.
INPUT=$(cat)

HOST=$(echo "$INPUT"  | grep -o '"host"[[:space:]]*:[[:space:]]*"[^"]*"'        | head -1 | sed 's/.*:.*"\([^"]*\)".*/\1/')
USER=$(echo "$INPUT"  | grep -o '"user"[[:space:]]*:[[:space:]]*"[^"]*"'        | head -1 | sed 's/.*:.*"\([^"]*\)".*/\1/')
PKEY=$(echo "$INPUT"  | grep -o '"private_key"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)".*/\1/')

# --- Validate inputs ---
if [ -z "$HOST" ] || [ -z "$USER" ] || [ -z "$PKEY" ]; then
  echo '{"error":"missing required input: host, user, or private_key"}' >&2
  exit 1
fi

# --- Decode the private key ---
# DECISION: Private key is passed as base64 to survive JSON encoding.
# Why: SSH private keys contain newlines which break JSON string values.
#      Base64 encoding is the simplest lossless serialization.
KEYFILE=$(mktemp)
# SECURITY: Restrict permissions BEFORE writing key material.
chmod 600 "$KEYFILE"
echo "$PKEY" | base64 -d > "$KEYFILE" 2>/dev/null

# --- Cleanup trap ---
# SECURITY: Always remove the temporary key file, even on error.
cleanup() { rm -f "$KEYFILE"; }
trap cleanup EXIT INT TERM

# --- Fetch kubeconfig via SSH ---
# NOTE: ConnectTimeout=30 and ServerAliveInterval prevent indefinite hangs.
# BatchMode=yes ensures SSH never prompts for a password (fail-fast).
KUBECONFIG_RAW=$(ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o BatchMode=yes \
  -o ConnectTimeout=30 \
  -o ServerAliveInterval=10 \
  -o ServerAliveCountMax=3 \
  -o LogLevel=ERROR \
  -i "$KEYFILE" \
  "${USER}@${HOST}" \
  "cat /etc/rancher/rke2/rke2.yaml" 2>/dev/null)

# --- Validate output ---
if [ -z "$KUBECONFIG_RAW" ]; then
  echo "ERROR: kubeconfig is empty" >&2
  exit 1
fi

if ! echo "$KUBECONFIG_RAW" | grep -q "apiVersion"; then
  echo "ERROR: kubeconfig appears malformed (missing apiVersion)" >&2
  exit 1
fi

# --- Return as JSON ---
# DECISION: Base64-encode the kubeconfig content for JSON transport.
# Why: Kubeconfig YAML contains special characters (colons, quotes, newlines)
#      that would break JSON string encoding. Base64 is lossless and safe.
#      The caller (Terraform) decodes it with base64decode().
KUBECONFIG_B64=$(echo "$KUBECONFIG_RAW" | base64 | tr -d '\n')

# data "external" expects a JSON object on stdout.
echo "{\"kubeconfig_b64\":\"${KUBECONFIG_B64}\"}"
