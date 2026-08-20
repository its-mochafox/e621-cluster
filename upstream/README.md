# Upstream snapshots

Copies of the upstream files this chart is derived from, taken at
`e621ng/e621ng@1235a4f72297955df7f567bfa6e67c3213025188`.

Nothing here is used at runtime. They exist so `.github/workflows/upstream-drift.yml`
can tell you when upstream changes something the chart depends on, which is the
whole reason this repo carries no upstream source.

| File | What the chart takes from it |
| --- | --- |
| `docker-compose.yml` | Pinned versions for postgres, redis, opensearch, memcached, iqdb and autocompleted, plus the shared environment block |
| `default.conf.template` | The nginx config. `.dockerignore` keeps this file out of the production image, so it cannot be read from the image at runtime and has to be vendored into `configmap-nginx.yaml` |
| `sidekiq.yml` | The `SIDEKIQ_QUEUES` / `SIDEKIQ_CONCURRENCY` contract |
| `database.yml` | Which `DB_*` variables are required, and the hardcoded `e621` role and database names |
| `Procfile` | Reference queue weights, split across `values.jobs.groups` |
| `Dockerfile` | Build target, runtime uid, default command, and the `GIT_TAG` build arg |

When the drift workflow opens a PR, review the diff, apply anything the chart
needs, then merge to re-baseline.
