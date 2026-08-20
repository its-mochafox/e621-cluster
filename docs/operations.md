# Operations

Commands assume `-n e621` and a release named `e621`. Adjust to taste.

## Rolling out a new upstream commit

`build-upstream.yml` runs six-hourly, builds upstream `master` if it has moved,
pushes `ghcr.io/realmochafox/e621ng:master-<sha>`, and opens a PR bumping
`appVersion` in `charts/e621/Chart.yaml`.

Merge the PR, then:

```sh
helm -n e621 upgrade e621 charts/e621 -f your-values.yaml
```

The `pre-upgrade` hook runs `db:migrate` and must succeed before any new pod
starts. Watch it with:

```sh
kubectl -n e621 logs job/e621-migrate -f
```

To build a specific commit out of band, run the workflow manually with a `ref`
input. To rebuild an already-published tag, set `force`.

## Draining a web pod

`/health` returns 503 while a drain file exists, which fails the nginx sidecar's
readiness probe and removes the pod from the Service. The app container's
liveness probe deliberately uses `/status` instead, so a drained pod is not
restarted.

```sh
kubectl -n e621 exec <pod> -c e621 -- bin/drain true
kubectl -n e621 exec <pod> -c e621 -- bin/drain false
```

The drain file lives on a per-pod emptyDir, so it does not survive a restart.
The same mechanism runs automatically in the `preStop` hook, which drains and
waits 15 seconds before pitchfork receives SIGTERM.

## Consoles and one-off work

```sh
# Rails console
kubectl -n e621 exec -it deploy/e621-web -c e621 -- bundle exec rails console

# psql
kubectl -n e621 exec -it sts/e621-postgres -- psql -U e621 -d e621

# One-off maintenance scripts shipped upstream in db/fixes/
kubectl -n e621 exec -it deploy/e621-web -c e621 -- bundle exec rails runner db/fixes/129_prune_exception_logs.rb
```

Prefer running heavy one-offs against a jobs pod rather than a web pod so they
do not compete with request traffic.

## Sidekiq

The Sidekiq web UI is mounted by the app itself at `/sidekiq`, behind an
admin-only route constraint. There is no separate deployment for it.

Scheduled jobs are registered by `sidekiq-cron` inside every Sidekiq process.
The schedule and the enqueuer election both live in Redis, so multiple groups
and replicas do not duplicate work. Everything scheduled runs on `low_prio`
except `SearchTrendAggregateJob`, which uses `default` — keep both queues
assigned to some group or the scheduled jobs will pile up unprocessed.

## OpenSearch

Indices are named `posts_production` and `post_versions_production` and are
created by the bootstrap job. Creating them is idempotent, so re-running the
bootstrap is the easiest way to add indices for a model upstream introduces
later:

```sh
kubectl -n e621 exec -it deploy/e621-web -c e621 -- \
  bundle exec rails runner '[Post, PostVersion].each { |m| m.document_store.create_index! }'
```

To rebuild from scratch, pass `delete_existing: true` — this drops the index, so
searches return nothing until reindexing finishes.

## Storage

Everything under `/app/public/data` is the shared RWX claim, laid out
hierarchically by md5:

```
<ab>/<cd>/<md5>.<ext>            originals
preview/<ab>/<cd>/<md5>.jpg      thumbnails
sample/<ab>/<cd>/<md5>.jpg       large images and video variants
crop/<ab>/<cd>/<md5>.jpg         avatar crops
deleted/**                       mirror of the above for deleted posts
replacements/                    pending replacements
staff_files/                     staff uploads
mascots/  avatars/  db_export/   miscellaneous
```

The claim carries `helm.sh/resource-policy: keep`, so uninstalling the release
does not delete it.

Files are written with mode 0644 by uid 1000. If your RWX backend ignores
`fsGroup` (NFS usually does), pre-chown the export to `1000:1000`.

## Scaling

- `web.replicas` and `web.workerCount` scale request capacity. Keep the memory
  limit above `768Mi × workerCount`.
- `jobs.groups[].replicas` and `.concurrency` scale background work. Concurrency
  must stay below `jobs.dbWorkerPoolSize`.
- `iqdb` cannot be scaled; it is one database file.
- `postgres`, `redis` and `opensearch` are single-replica by design here. Point
  the chart at managed instances via the `external.*` values if you need more.

`danbooru.config.iqdb_max_concurrent_queries` is a per-`server_name` Redis
counter, and the chart sets `DANBOORU_SERVER_NAME` to the pod name, so each pod
gets its own budget. Size it against a single pod's worker count, not the fleet.
