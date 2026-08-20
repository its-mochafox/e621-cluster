#!/usr/bin/env bash
# Generates the Secret the chart expects. Run once, keep the output somewhere
# safe, and never regenerate totp-encryption-key on a live install.
#
#   ./scripts/gen-secrets.sh e621 | kubectl apply -f -
#
# Or write it to a file first if you want to review or back it up:
#
#   ./scripts/gen-secrets.sh e621 > secrets.yaml
set -euo pipefail

NAMESPACE="${1:-default}"
NAME="${2:-e621-secrets}"

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required" >&2
  exit 1
fi

hex() { openssl rand -hex "$1"; }

cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${NAME}
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  # Rails secret_key_base and session signing key. Rotating either logs everyone
  # out and invalidates every signed cookie.
  secret-token: "$(hex 32)"
  session-secret-key: "$(hex 32)"

  # Postgres password for the hardcoded "e621" role.
  db-password: "$(hex 24)"

  # AES key for stored TOTP secrets. Must be exactly 64 hex characters.
  # Rotating this permanently breaks every enrolled 2FA device, with no
  # recovery path. Back it up before you do anything else.
  totp-encryption-key: "$(hex 32)"

  # secure_link signing keys. Rails generates the HMAC and the nginx sidecar
  # validates it, so the chart wires the same values into both. Rotating them
  # invalidates in-flight download links but is otherwise safe.
  protected-file-secret: "$(hex 32)"
  replacement-file-secret: "$(hex 32)"
  staff-file-secret: "$(hex 32)"

  # Signs remember-me cookies and emailed links.
  remember-key: "$(hex 32)"
  email-key: "$(hex 32)"

  # Optional. Production hardwires the mailer to mailgun, so without these no
  # mail is delivered (password resets, email verification, forum subscriptions).
  # mailgun-api-key: ""
  # mailgun-domain: ""
EOF
