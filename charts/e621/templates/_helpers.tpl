{{/*
Name helpers
*/}}
{{- define "e621.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "e621.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "e621.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "e621.labels" -}}
helm.sh/chart: {{ include "e621.chart" . }}
{{ include "e621.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "e621.selectorLabels" -}}
app.kubernetes.io/name: {{ include "e621.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "e621.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "e621.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "e621.image" -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}

{{/*
Dependency endpoints. Each falls back to an externally managed endpoint when the
in-chart StatefulSet is disabled.
*/}}
{{- define "e621.postgres.host" -}}
{{- if .Values.postgres.enabled -}}
{{- printf "%s-postgres" (include "e621.fullname" .) -}}
{{- else -}}
{{- required "postgres.external.host is required when postgres.enabled is false" .Values.postgres.external.host -}}
{{- end -}}
{{- end -}}

{{- define "e621.postgres.port" -}}
{{- if .Values.postgres.enabled -}}5432{{- else -}}{{ .Values.postgres.external.port }}{{- end -}}
{{- end -}}

{{- define "e621.redis.url" -}}
{{- if .Values.redis.enabled -}}
{{- printf "redis://%s-redis:6379/0" (include "e621.fullname" .) -}}
{{- else -}}
{{- required "redis.external.url is required when redis.enabled is false" .Values.redis.external.url -}}
{{- end -}}
{{- end -}}

{{- define "e621.opensearch.host" -}}
{{- if .Values.opensearch.enabled -}}
{{- printf "%s-opensearch" (include "e621.fullname" .) -}}
{{- else -}}
{{- required "opensearch.external.host is required when opensearch.enabled is false" .Values.opensearch.external.host -}}
{{- end -}}
{{- end -}}

{{- define "e621.memcached.servers" -}}
{{- if .Values.memcached.enabled -}}
{{- printf "%s-memcached:11211" (include "e621.fullname" .) -}}
{{- else -}}
{{- required "memcached.external.servers is required when memcached.enabled is false" .Values.memcached.external.servers -}}
{{- end -}}
{{- end -}}

{{/*
Environment shared by web, jobs, and the bootstrap/migrate Jobs.

DB_POOL_SIZE and DB_WORKER_POOL_SIZE are both always set. config/database.yml
picks between them with `Sidekiq.server?` and uses ENV.fetch with no default, so
defining only one would crash whichever workload guessed wrong.
*/}}
{{- define "e621.commonEnv" -}}
- name: RAILS_ENV
  value: production
- name: RAILS_LOG_TO_STDOUT
  value: "1"
- name: RAILS_LOG_LEVEL
  value: {{ .Values.app.logLevel | quote }}
# Suppress libvips chatter on corrupt uploads.
- name: VIPS_WARNING
  value: "0"

- name: DANBOORU_HOSTNAME
  value: {{ required "hostname is required" .Values.hostname | quote }}
- name: DANBOORU_REDIS_URL
  value: {{ include "e621.redis.url" . | quote }}
- name: DANBOORU_OPENSEARCH_HOST
  value: {{ include "e621.opensearch.host" . | quote }}
- name: DANBOORU_MEMCACHED_SERVERS
  value: {{ include "e621.memcached.servers" . | quote }}
{{- if .Values.iqdb.enabled }}
- name: DANBOORU_IQDB_SERVER
  value: {{ printf "http://%s-iqdb:5588" (include "e621.fullname" .) | quote }}
{{- end }}

- name: DB_HOST
  value: {{ include "e621.postgres.host" . | quote }}
- name: DB_PORT
  value: {{ include "e621.postgres.port" . | quote }}
- name: DB_POOL_SIZE
  value: {{ .Values.web.dbPoolSize | quote }}
- name: DB_WORKER_POOL_SIZE
  value: {{ .Values.jobs.dbWorkerPoolSize | quote }}

# Drain file lives on a per-pod emptyDir so `bin/drain true` takes a single
# replica out of the Service without affecting the others.
- name: DANBOORU_DRAIN_FILE
  value: /drain/out_of_rotation
- name: DANBOORU_SERVER_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name

{{ include "e621.secretEnv" . }}
{{- range $key, $value := .Values.danbooru.config }}
- name: DANBOORU_{{ $key | upper }}
  value: {{ $value | quote }}
{{- end }}
{{- with .Values.app.extraEnv }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end -}}

{{/*
Secret-backed environment. Split out because the nginx sidecar needs the three
file-signing secrets (and nothing else) to render its secure_link directives.
*/}}
{{- define "e621.secretEnv" -}}
{{- $secret := .Values.existingSecret -}}
- name: SECRET_TOKEN
  valueFrom:
    secretKeyRef: { name: {{ $secret }}, key: secret-token }
- name: SESSION_SECRET_KEY
  valueFrom:
    secretKeyRef: { name: {{ $secret }}, key: session-secret-key }
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef: { name: {{ $secret }}, key: db-password }
- name: DANBOORU_TOTP_ENCRYPTION_KEY
  valueFrom:
    secretKeyRef: { name: {{ $secret }}, key: totp-encryption-key }
- name: DANBOORU_REMEMBER_KEY
  valueFrom:
    secretKeyRef: { name: {{ $secret }}, key: remember-key }
- name: DANBOORU_EMAIL_KEY
  valueFrom:
    secretKeyRef: { name: {{ $secret }}, key: email-key }
- name: DANBOORU_MAILGUN_API_KEY
  valueFrom:
    secretKeyRef: { name: {{ $secret }}, key: mailgun-api-key, optional: true }
- name: DANBOORU_MAILGUN_DOMAIN
  valueFrom:
    secretKeyRef: { name: {{ $secret }}, key: mailgun-domain, optional: true }
{{ include "e621.fileSecretEnv" . }}
{{- end -}}

{{/*
The three secure_link secrets. Rails generates the HMAC and nginx validates it,
so both sides must read the exact same values.
*/}}
{{- define "e621.fileSecretEnv" -}}
{{- $secret := .Values.existingSecret -}}
- name: DANBOORU_PROTECTED_FILE_SECRET
  valueFrom:
    secretKeyRef: { name: {{ $secret }}, key: protected-file-secret }
- name: DANBOORU_REPLACEMENT_FILE_SECRET
  valueFrom:
    secretKeyRef: { name: {{ $secret }}, key: replacement-file-secret }
- name: DANBOORU_STAFF_FILE_SECRET
  valueFrom:
    secretKeyRef: { name: {{ $secret }}, key: staff-file-secret }
{{- end -}}

{{/*
Volumes and mounts shared by every app container.

config/application.rb requires config/danbooru_local_config.rb unconditionally.
The image ships an empty stub, which the ConfigMap replaces via subPath.
*/}}
{{- define "e621.appVolumes" -}}
- name: data
  persistentVolumeClaim:
    claimName: {{ .Values.storage.data.existingClaim | default (printf "%s-data" (include "e621.fullname" .)) }}
- name: local-config
  configMap:
    name: {{ include "e621.fullname" . }}-local-config
- name: drain
  emptyDir: {}
- name: tmp
  emptyDir:
    sizeLimit: {{ .Values.web.tmpSizeLimit }}
{{- end -}}

{{- define "e621.appVolumeMounts" -}}
- name: data
  mountPath: /app/public/data
- name: local-config
  mountPath: /app/config/danbooru_local_config.rb
  subPath: danbooru_local_config.rb
  readOnly: true
{{- if .Values.sitemap.enabled }}
- name: local-config
  mountPath: /app/config/initializers/zz_sitemap_path.rb
  subPath: zz_sitemap_path.rb
  readOnly: true
{{- end }}
- name: drain
  mountPath: /drain
# Downloads, video transcodes and image sampling all stage through Tempfile.
- name: tmp
  mountPath: /tmp
{{- end -}}

{{/*
Blocks the pod until Postgres and OpenSearch answer. Sidekiq and pitchfork both
crash on boot rather than retry if their dependencies are missing.
*/}}
{{- define "e621.waitForDeps" -}}
- name: wait-for-deps
  image: {{ include "e621.image" . }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  command:
    - /bin/sh
    - -c
    - |
      set -e
      echo "waiting for postgres at {{ include "e621.postgres.host" . }}:{{ include "e621.postgres.port" . }}"
      until pg_isready -h {{ include "e621.postgres.host" . }} -p {{ include "e621.postgres.port" . }} -U e621 >/dev/null 2>&1; do
        sleep 2
      done
      echo "waiting for opensearch at {{ include "e621.opensearch.host" . }}:9200"
      # busybox sh has no /dev/tcp and the production image ships no curl, so
      # use the ruby that is guaranteed to be present.
      until ruby -rsocket -e 'TCPSocket.new(ARGV[0], 9200).close' {{ include "e621.opensearch.host" . }} >/dev/null 2>&1; do
        sleep 2
      done
      echo "dependencies ready"
{{- end -}}
