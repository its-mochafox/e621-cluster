# e621-cluster

Helm chart and CI for running [e621ng](https://github.com/e621ng/e621ng) on
Kubernetes, tracking the upstream `master` branch.

## Why there is no upstream source here

This repo contains no files from e621ng. Nothing is forked, nothing is merged,
and there is therefore nothing to conflict when upstream moves. The chart
consumes an image built from an unmodified upstream checkout, and the three
places where the chart still has to know something about upstream are watched
automatically:

| Coupling | How it stays current |
| --- | --- |
| The application image | `build-upstream.yml` builds upstream's `Dockerfile` (`target: production`) from a clean checkout of `master`, six-hourly, and opens a PR bumping the tag |
| The nginx config | Vendored in `configmap-nginx.yaml`, because `.dockerignore` keeps `docker/default.conf.template` out of the production image. `upstream-drift.yml` opens a PR when upstream's copy changes |
| Pinned dependency versions and required env vars | Snapshotted in `upstream/`, same drift workflow |

Upstream only publishes images on tag pushes, so tracking `master` means
building it here rather than pulling a published one.

## Layout

```
charts/e621/          the chart
upstream/             snapshots used only for drift detection
scripts/              secret generation
docs/                 secrets and day-two operations
.github/workflows/    image build, drift detection, lint
```

## Install

```sh
kubectl create namespace e621
./scripts/gen-secrets.sh e621 | kubectl apply -f -

kubectl -n e621 create secret docker-registry ghcr \
  --docker-server=ghcr.io \
  --docker-username=<github-user> \
  --docker-password=<PAT with read:packages>

helm -n e621 install e621 charts/e621 \
  --set hostname=e621.example.com \
  --set storage.data.storageClassName=<your RWX class>
```

The `post-install` hook loads `db/structure.sql`, creates the OpenSearch
indices, and seeds the admin and system users. It is idempotent and safe to
re-run. Watch it with `kubectl -n e621 logs job/e621-bootstrap`.

Upgrades run `db:migrate` as a `pre-upgrade` hook before any new pod starts.

## Topology

```
                 ┌─ web pod ────────────────────────────┐
   your proxy ──▶│ nginx :8080 ──▶ pitchfork :9000      │──▶ postgres
   (terminates   │   ▲ assets copied from the app image │──▶ redis
    TLS)         └───┼──────────────────────────────────┘──▶ opensearch
                     │                                     ──▶ memcached
                     ├──▶ autocompleted :8118 ──▶ postgres  ──▶ iqdb
                     │
   jobs-general ─────┤  sidekiq: high_prio, default, tags, iqdb, low_prio
   jobs-media   ─────┘  sidekiq: video, thumb
                     │
                     └──▶ shared RWX volume at /app/public/data
```

nginx is a sidecar rather than its own Deployment because vite emits
content-hashed asset filenames. A separately-rolled nginx would serve stale
hashes to HTML rendered by freshly-rolled web pods and 404 every asset for the
duration of the rollout.

nginx cannot be dropped: the `secure_link` checks on `/data/deleted/`,
`/data/replacements/` and `/data/staff_files/` are the only thing protecting
those paths. Rails does not enforce it.

## Things worth knowing before you deploy

**TLS terminates outside the cluster.** The app sets `config.force_ssl = true`
and `config.assume_ssl` is development-only upstream, so `RAILS_ASSUME_SSL` does
nothing in production. The nginx sidecar hardcodes `X-Forwarded-Proto: https`
(`web.nginx.assumeSsl`). Without it every request enters a permanent redirect
loop. HSTS is emitted with `preload` and a one-year max-age, which pins the
domain to HTTPS in browsers.

**Storage must be ReadWriteMany.** The web pods, every jobs group and the nginx
sidecars all mount the same post-data claim. Workers write originals, previews,
samples, crops and video variants; web writes avatars and replacements.

**The Postgres role and database are both hardcoded to `e621`.**
`config/database.yml` does not read a username or database name from the
environment, so an external Postgres has to expose exactly those.

**`DANBOORU_*` values arrive in Ruby as Strings.** Setting a numeric setting
through `danbooru.config` makes `Danbooru.config.validate!` raise at boot. Put
numeric and non-scalar settings in `danbooru.localConfig`, which is rendered
into `config/danbooru_local_config.rb`.

**`SIDEKIQ_CONCURRENCY` must stay below `jobs.dbWorkerPoolSize`,** and web
memory limits should exceed `768Mi × web.workerCount`, since pitchfork recycles
workers between 386MB and 768MB PSS and the OOM killer is less graceful.

**The sitemap is broken unless you enable `sitemap.enabled`.**
`SitemapGeneratorJob` runs on a worker and writes to that pod's own `public/`,
which nginx never sees, while `robots.txt` advertises `/sitemap.xml.gz`.

**IQDB is single-replica by design.** It is backed by one database file.

See `docs/operations.md` for draining, consoles, reindexing and one-off scripts,
and `docs/secrets.md` for the Secret contract.
