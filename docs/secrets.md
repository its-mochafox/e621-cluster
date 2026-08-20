# Secrets

The chart reads everything sensitive from one Secret, named by
`values.existingSecret` (default `e621-secrets`). Nothing sensitive is
templated into the chart or committed here.

Generate it with:

```sh
./scripts/gen-secrets.sh <namespace> [secret-name] | kubectl apply -f -
```

## Keys

| Key | Required | Notes |
| --- | --- | --- |
| `secret-token` | yes | Rails `secret_key_base`. The app refuses to boot without it (or a `~/.danbooru/secret_token` file, which the chart does not use). Rotating invalidates every signed cookie. |
| `session-secret-key` | yes | Session cookie signing key. Same boot requirement, same rotation cost. |
| `db-password` | yes | Password for the Postgres role. Consumed by the app, by the in-chart Postgres as `POSTGRES_PASSWORD`, and by `autocompleted`, so all three stay in sync. |
| `totp-encryption-key` | yes | 64 hex characters. Encrypts stored TOTP secrets. Read lazily, so a wrong value fails at 2FA time rather than at boot. **Rotating it permanently breaks every enrolled device with no recovery path.** Back it up. |
| `protected-file-secret` | yes | `secure_link` key for `/data/deleted/`. |
| `replacement-file-secret` | yes | `secure_link` key for `/data/replacements/`. |
| `staff-file-secret` | yes | `secure_link` key for `/data/staff_files/`. |
| `remember-key` | yes | Signs remember-me cookies. |
| `email-key` | yes | Signs links in outbound email. |
| `mailgun-api-key` | no | Production hardwires the mailer to Mailgun. Without it, no password resets, email verification or forum subscription mail. |
| `mailgun-domain` | no | As above. |

The three `secure_link` keys are wired into both the app container and the nginx
sidecar. Rails builds the HMAC and nginx validates it, so they must match
exactly; the chart guarantees this by sourcing both from the same Secret key.
Rotating them invalidates outstanding download links but is otherwise harmless.

The upstream defaults for these are literally `abc123`, so leaving any of them
unset would leave deleted posts, pending replacements and staff files publicly
reachable by anyone who can guess the path.

## Not currently wired up

`OIDC_SIGNING_KEY` is only needed if you set
`danbooru.config.enable_oauth_provider: "true"`. It must be a PEM RSA key of at
least 2048 bits, and the app checks that the file is not world-readable, which
means a Secret volume mounted with the default `0644` mode is rejected. If you
enable OAuth, mount it with `defaultMode: 0400` or pass it through the
environment.

## Registry credentials

The GHCR package is private. Create the pull secret separately and reference it
through `values.imagePullSecrets`:

```sh
kubectl -n <namespace> create secret docker-registry ghcr \
  --docker-server=ghcr.io \
  --docker-username=<github-user> \
  --docker-password=<PAT with read:packages>
```
