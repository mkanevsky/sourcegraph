#!/usr/bin/env bash
# =============================================================================
# Sourcegraph precise-code-intel — local, from-source runbook
# =============================================================================
#
# Brings up the minimum set of Sourcegraph services, BUILT FROM THIS SOURCE
# TREE with plain `go build` (no Bazel, no `sg`, no dev-private repo, no license
# key), that is required to demonstrate PRECISE CODE NAVIGATION end-to-end:
#
#     SCIP upload (REST)  ->  precise-code-intel-worker  ->  codeintel Postgres
#                                                                |
#     GraphQL query (definitions / references / hover)  <--------+
#
# It also (optionally) builds the standalone `zoekt` search engine, which is a
# separate concern — see `search` subcommand notes at the bottom.
#
# -----------------------------------------------------------------------------
# THE MOVING PARTS (what each process is responsible for)
# -----------------------------------------------------------------------------
#
#   frontend                  The hub. Serves the GraphQL API, the REST SCIP
#     (cmd/frontend)          upload endpoint, the web UI, AND acts as the
#                             central CONFIGURATION SERVER that every other
#                             service reads its site config from.
#                             Ports: 3082 = external app/API (auth required)
#                                    3090 = internal API   (service-to-service,
#                                           NO auth -> we use this for the demo)
#
#   gitserver                 Stores git repositories on local disk and answers
#     (cmd/gitserver)         "give me file X at commit Y". Everything that needs
#                             source bytes (incl. the SCIP processor, which
#                             validates that indexed paths actually exist) talks
#                             to gitserver.  Port 3178.
#
#   repo-updater             Reads the configured code-host connections
#     (cmd/repo-updater)      (external services), discovers repositories, and
#                             schedules clones/fetches on gitserver. Without it,
#                             a configured repo never gets cloned.  Port 3182.
#
#   precise-code-intel-worker Polls the upload queue, pulls the raw SCIP blob
#     (cmd/precise-code-intel-worker)  from blobstore, parses + correlates it,
#                             validates paths against gitserver, and writes the
#                             documents/symbols/occurrences into the codeintel
#                             Postgres database. THIS is the precise-nav engine.
#
#   worker                   Runs assorted background jobs. The one that matters
#     (cmd/worker)            here is the codeintel "commit graph updater", which
#                             computes which uploads are VISIBLE at which commits.
#                             Until it runs, a freshly-processed upload is not yet
#                             queryable.
#
#   blobstore                S3-compatible object store for the raw uploaded SCIP
#     (cmd/blobstore)         files.  Port 9000.
#
#   Postgres (Docker)        Two logical databases in one server:
#                               - frontend     : repos, external services, the
#                                                upload queue/metadata, etc.
#                               - codeintel    : the processed SCIP graph data.
#                             (In real dev these can even share one DB; we keep
#                              them separate for clarity.)  Host port 5433.
#
#   Redis (Docker)           Caches + simple queues used by frontend/worker.
#                             Host port 6380.
#
#   git daemon               NOT a Sourcegraph component. A throwaway `git://`
#                             server for the DEMO repo, because the "OTHER" code
#                             host kind only accepts git/ssh/http(s) URLs, not
#                             file://. Serves /tmp over git://127.0.0.1:9418.
#
#   migrator                 One-shot: applies the SQL schema migrations to both
#     (cmd/migrator)          databases before the services start. (frontend can
#                             also self-migrate, but we do it explicitly.)
#
# -----------------------------------------------------------------------------
# NON-OBVIOUS GOTCHAS baked into this script (none are documented upstream)
# -----------------------------------------------------------------------------
#   1. Build with the SYSTEM Go (>= 1.23), NOT the repo-pinned 1.22.4. On recent
#      macOS (Darwin 25+), 1.22.4-linked binaries fail to run with
#      "missing LC_UUID load command". 1.25 builds run fine.
#   2. frontend needs CONFIGURATION_MODE=server; all other services use =client.
#   3. SRC_PROF_HTTP must be empty, else every process fights over debug :6060.
#   4. worker needs SRC_OOBMIGRATION_CURRENT_VERSION set, because this snapshot
#      has NO git version tags and worker otherwise can't infer its version.
#   5. blobstore needs BLOBSTORE_DATA_DIR (defaults to read-only /data).
#   6. SCIP uploads MUST use Content-Type: application/x-protobuf+scip.
#   7. The "OTHER" external service URL must be git://, ssh:// or http(s)://.
#   8. Web UI (optional, `web` subcommand): build with Node 20, and start frontend
#      with WEB_BUILDER_DEV_SERVER=1 so it serves HTML from client/web/dist
#      instead of the production /assets-dist path. `up` sets this automatically
#      once the bundle exists.
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   ./run-stack.sh build      # go build all service binaries into .bin/
#   ./run-stack.sh infra      # start Postgres + Redis (Docker) and migrate
#   ./run-stack.sh up         # start all Sourcegraph services + git daemon
#   ./run-stack.sh web        # (optional) build + serve the web UI at :3080 (needs Node 20)
#                             #   then re-run `up` so frontend serves with the web manifest
#   ./run-stack.sh search     # (optional) start zoekt indexed search (webserver :3070
#                             #   + indexserver); makes web-UI search work, silences the
#                             #   worker's :3070 errors
#   ./run-stack.sh demo       # create demo repo, index it, upload SCIP, QUERY
#   ./run-stack.sh status     # show what's listening / alive
#   ./run-stack.sh logs <svc> # tail a service log (frontend|gitserver|...)
#   ./run-stack.sh query <file> <line> <char>   # ad-hoc definitions query
#   ./run-stack.sh down        # stop services (keeps Docker DBs + built bins)
#   ./run-stack.sh nuke        # down + remove Docker DBs + repos/blobstore data
#   ./run-stack.sh all         # build + infra + up + demo  (one shot)
#
# All ports / names are overridable via the env block right below.
# =============================================================================

set -uo pipefail   # deliberately NOT -e: poll loops and pkill are expected to
                   # "fail" routinely; we check what matters explicitly.

# ----------------------------- configuration ---------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$REPO_ROOT/.bin"

# Postgres / Redis (Docker containers)
PG_CONTAINER=sg-testpg
PG_PORT=5433
PG_USER=sourcegraph
PG_PASS=sourcegraph
PG_DB=sourcegraph                 # frontend database
PG_CODEINTEL_DB=sourcegraph_codeintel
REDIS_CONTAINER=sg-redis
REDIS_PORT=6380

# Service ports
FRONTEND_EXT=3082                 # external app/API
FRONTEND_INT=3090                 # internal API (no auth) -> used by demo/query
GITSERVER_PORT=3178
REPOUPDATER_PORT=3182
BLOBSTORE_PORT=9000
GIT_DAEMON_PORT=9418

# Data / log dirs (throwaway)
REPOS_DIR=/tmp/sg-repos
BLOBSTORE_DIR=/tmp/sg-blobstore
LOG_DIR=/tmp/sg-logs
ZOEKT_BIN="$BIN/zoekt"                       # zoekt search binaries live here
ZOEKT_INDEX="$HOME/.sourcegraph/zoekt/index-0"  # shared by webserver + indexserver
DEMO_REPO=/tmp/sg-demo-repo
DEMO_REPO_NAME=sg-demo-repo
EXTSVC_FILE=/tmp/sg-extsvc.json

GQL="http://127.0.0.1:${FRONTEND_INT}/.internal/graphql"
SCIP_UPLOAD="http://127.0.0.1:${FRONTEND_INT}/.internal/scip/upload"

# ----------------------------- helpers ---------------------------------------
c_blue='\033[34m'; c_grn='\033[32m'; c_red='\033[31m'; c_yel='\033[33m'; c_off='\033[0m'
log()  { printf "${c_blue}==>${c_off} %s\n" "$*"; }
ok()   { printf "${c_grn}  ok${c_off} %s\n" "$*"; }
warn() { printf "${c_yel}  ! ${c_off} %s\n" "$*"; }
die()  { printf "${c_red}ERROR:${c_off} %s\n" "$*" >&2; exit 1; }

# Block until a TCP port is accepting connections (or time out).
wait_for_port() { # host port seconds label
  local host=$1 port=$2 secs=${3:-30} label=${4:-$2} i
  for ((i=1;i<=secs;i++)); do
    if nc -z "$host" "$port" >/dev/null 2>&1; then ok "$label listening on $host:$port (${i}s)"; return 0; fi
    sleep 1
  done
  warn "$label NOT listening on $host:$port after ${secs}s"; return 1
}

# Build the environment shared by every Sourcegraph service. The single argument
# selects the configuration role: "server" (frontend) or "client" (all others).
service_env() { # role
  local role=$1
  # --- dev-mode switches: 127.0.0.1 bindings, relaxed behaviour ---
  export DEPLOY_TYPE=dev INSECURE_DEV=true SRC_DEVELOPMENT=true
  export SRC_LOG_LEVEL=info SRC_LOG_FORMAT=condensed
  export SRC_PROF_HTTP=                         # gotcha #3: disable the :6060 debug server
  export CONFIGURATION_MODE="$role"             # gotcha #2

  # --- frontend (main) database ---
  export PGHOST=127.0.0.1 PGPORT=$PG_PORT PGUSER=$PG_USER PGPASSWORD=$PG_PASS PGDATABASE=$PG_DB PGSSLMODE=disable
  # --- codeintel database (separate logical DB, same server) ---
  export CODEINTEL_PGHOST=127.0.0.1 CODEINTEL_PGPORT=$PG_PORT CODEINTEL_PGUSER=$PG_USER \
         CODEINTEL_PGPASSWORD=$PG_PASS CODEINTEL_PGDATABASE=$PG_CODEINTEL_DB CODEINTEL_PGSSLMODE=disable

  export REDIS_ENDPOINT=127.0.0.1:$REDIS_PORT   # fallback for both cache+store

  # --- service discovery: where each service finds the others ---
  export SRC_GIT_SERVERS=127.0.0.1:$GITSERVER_PORT
  export GITSERVER_ADDR=127.0.0.1:$GITSERVER_PORT GITSERVER_EXTERNAL_ADDR=127.0.0.1:$GITSERVER_PORT
  export SRC_FRONTEND_INTERNAL=127.0.0.1:$FRONTEND_INT
  export REPO_UPDATER_URL=http://127.0.0.1:$REPOUPDATER_PORT
  # We do not run searcher/symbols/zoekt for precise nav; point them somewhere
  # harmless so startup doesn't block (errors about these are non-fatal).
  export SEARCHER_URL=http://127.0.0.1:3181 SYMBOLS_URL=http://127.0.0.1:3184
  export INDEXED_SEARCH_SERVERS=127.0.0.1:3070

  # --- object storage for SCIP uploads (blobstore, S3-compatible) ---
  export PRECISE_CODE_INTEL_UPLOAD_BACKEND=blobstore
  export PRECISE_CODE_INTEL_UPLOAD_AWS_ENDPOINT=http://127.0.0.1:$BLOBSTORE_PORT
  export BLOBSTORE_DATA_DIR=$BLOBSTORE_DIR      # gotcha #5

  # --- repos + config files ---
  export SRC_REPOS_DIR=$REPOS_DIR
  export SITE_CONFIG_FILE=$REPO_ROOT/dev/site-config.json
  export GLOBAL_SETTINGS_FILE=$REPO_ROOT/dev/global-settings.json
  export SG_DEV_MIGRATE_ON_APPLICATION_STARTUP=true
  export DISABLE_CODE_INSIGHTS=true

  # --- worker: version inference fix (gotcha #4) ---
  export SRC_OOBMIGRATION_CURRENT_VERSION=5.5.0
}

# Start a service binary in the background with the right config role.
start_svc() { # name role [extra env "KEY=VAL" ...]
  local name=$1 role=$2; shift 2
  ( service_env "$role"; for kv in "$@"; do export "$kv"; done
    exec "$BIN/$name" ) >"$LOG_DIR/$name.log" 2>&1 &
  echo $! >"$LOG_DIR/$name.pid"
  log "started $name (role=$role) pid $(cat "$LOG_DIR/$name.pid")"
}

# The web UI build needs Node 20 (the repo's pinned version). The system Node may
# be newer and will break the 2024-era esbuild/ts-node toolchain. Find a Node 20:
#   - honour $NODE20_BIN if set (a directory containing `node`)
#   - use the system node if it is already v20.x
#   - else pick the highest nvm-installed v20.x
node20_bin() {
  if [ -n "${NODE20_BIN:-}" ]; then echo "$NODE20_BIN"; return 0; fi
  if command -v node >/dev/null 2>&1 && node --version 2>/dev/null | grep -q '^v20\.'; then
    dirname "$(command -v node)"; return 0
  fi
  local d; d=$(ls -d "$HOME"/.nvm/versions/node/v20.* 2>/dev/null | sort -V | tail -1)
  [ -n "$d" ] && { echo "$d/bin"; return 0; }
  return 1
}

# ----------------------------- subcommands -----------------------------------

cmd_build() {
  command -v go >/dev/null || die "go not found"
  local gv; gv=$(go env GOVERSION)
  log "building service binaries from source with $gv (system Go, NOT pinned 1.22.4 — see gotcha #1)"
  mkdir -p "$BIN"
  # GOFLAGS=-mod=mod lets the build update go.sum entries from the module cache
  # as needed; GOTOOLCHAIN=local forces the system Go so we get LC_UUID.
  ( cd "$REPO_ROOT"
    GOTOOLCHAIN=local GOFLAGS=-mod=mod go build -o "$BIN/" \
      ./cmd/frontend \
      ./cmd/gitserver \
      ./cmd/repo-updater \
      ./cmd/precise-code-intel-worker \
      ./cmd/worker \
      ./cmd/blobstore \
      ./cmd/migrator ) || die "build failed"
  ok "built: $(cd "$BIN" && echo frontend gitserver repo-updater precise-code-intel-worker worker blobstore migrator)"
}

cmd_infra() {
  command -v docker >/dev/null || die "docker not found"
  mkdir -p "$REPOS_DIR" "$BLOBSTORE_DIR" "$LOG_DIR"

  log "starting Postgres ($PG_CONTAINER) on :$PG_PORT"
  if ! docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
    docker rm -f "$PG_CONTAINER" >/dev/null 2>&1
    docker run -d --name "$PG_CONTAINER" \
      -e POSTGRES_HOST_AUTH_METHOD=trust -e POSTGRES_USER=$PG_USER -e POSTGRES_DB=$PG_DB \
      -p $PG_PORT:5432 postgres:12-alpine >/dev/null || die "failed to start postgres"
  fi
  for i in $(seq 1 30); do docker exec "$PG_CONTAINER" pg_isready -U $PG_USER >/dev/null 2>&1 && break; sleep 1; done
  ok "postgres ready"
  docker exec "$PG_CONTAINER" psql -U $PG_USER -d $PG_DB \
    -c "CREATE DATABASE $PG_CODEINTEL_DB;" >/dev/null 2>&1 && ok "created $PG_CODEINTEL_DB" || true

  log "starting Redis ($REDIS_CONTAINER) on :$REDIS_PORT"
  if ! docker ps --format '{{.Names}}' | grep -qx "$REDIS_CONTAINER"; then
    docker rm -f "$REDIS_CONTAINER" >/dev/null 2>&1
    docker run -d --name "$REDIS_CONTAINER" -p $REDIS_PORT:6379 redis:7-alpine >/dev/null || die "failed to start redis"
  fi
  ok "redis ready"

  log "applying schema migrations to frontend + codeintel databases"
  ( service_env client
    "$BIN/migrator" up --db=frontend,codeintel ) || die "migrations failed"
  ok "databases migrated"
}

cmd_up() {
  [ -x "$BIN/frontend" ] || die "binaries missing — run '$0 build' first"
  mkdir -p "$LOG_DIR"

  # 1) git daemon: serve the demo repo over git:// (gotcha #7). Harmless if the
  #    demo repo doesn't exist yet; `demo` creates it.
  if ! pgrep -f "git daemon.*$GIT_DAEMON_PORT" >/dev/null; then
    log "starting git daemon on :$GIT_DAEMON_PORT (serves /tmp)"
    nohup git daemon --reuseaddr --base-path=/tmp --export-all \
      --listen=127.0.0.1 --port=$GIT_DAEMON_PORT >"$LOG_DIR/gitdaemon.log" 2>&1 &
  fi

  # 2) frontend FIRST — it is the configuration server every client blocks on.
  #    If the web bundle has been built (see `web` subcommand), tell frontend to
  #    serve HTML using the dev asset manifest in client/web/dist
  #    (cmd/frontend/shared/service.go: WEB_BUILDER_DEV_SERVER=1 -> UseDevAssetsProvider).
  if [ -f "$REPO_ROOT/client/web/dist/web.manifest.json" ]; then
    start_svc frontend server "SRC_HTTP_ADDR=:$FRONTEND_EXT" "EXTSVC_CONFIG_FILE=$EXTSVC_FILE" "WEB_BUILDER_DEV_SERVER=1"
  else
    start_svc frontend server "SRC_HTTP_ADDR=:$FRONTEND_EXT" "EXTSVC_CONFIG_FILE=$EXTSVC_FILE"
  fi
  wait_for_port 127.0.0.1 $FRONTEND_INT 60 frontend || die "frontend did not come up (see $LOG_DIR/frontend.log)"

  # 3) the rest, all as configuration CLIENTS.
  start_svc blobstore                client
  start_svc gitserver                client
  start_svc repo-updater             client
  start_svc precise-code-intel-worker client
  start_svc worker                   client
  sleep 6
  cmd_status
}

# Create the demo repo, generate its SCIP index, register it, upload, and QUERY.
cmd_demo() {
  # --- demo repo: a function defined in one file, used in another ---
  log "creating demo repo at $DEMO_REPO"
  rm -rf "$DEMO_REPO"; mkdir -p "$DEMO_REPO"; ( cd "$DEMO_REPO"
    printf 'module demo\n\ngo 1.21\n' > go.mod
    printf 'package demo\n\n// Greet returns a greeting for the given name.\nfunc Greet(name string) string {\n\treturn "Hello, " + name\n}\n' > greeter.go
    printf 'package demo\n\n// CallIt calls Greet and returns the result.\nfunc CallIt() string {\n\treturn Greet("world")\n}\n' > caller.go
    git init -q && git add -A && git -c user.email=a@b.c -c user.name=demo commit -qm "init demo" )
  local sha; sha=$(git -C "$DEMO_REPO" rev-parse HEAD); echo "$sha" >/tmp/sg-demo-sha.txt
  ok "commit $sha"

  # --- register the repo as an "OTHER" code host pointing at the git daemon ---
  log "writing external service config -> $EXTSVC_FILE"
  cat > "$EXTSVC_FILE" <<EOF
{
  "OTHER": [
    {
      "url": "git://127.0.0.1:$GIT_DAEMON_PORT",
      "repos": ["$DEMO_REPO_NAME"],
      "repositoryPathPattern": "{repo}"
    }
  ]
}
EOF
  warn "frontend must be (re)started with EXTSVC_CONFIG_FILE pointing here — 'up' already does this"

  # --- wait for repo-updater + gitserver to clone it ---
  log "waiting for repo to clone"
  for i in $(seq 1 30); do
    r=$(curl -s --max-time 5 -H 'Content-Type: application/json' \
        -d '{"query":"{repository(name:\"'"$DEMO_REPO_NAME"'\"){mirrorInfo{cloned}}}"}' "$GQL")
    echo "$r" | grep -q '"cloned":true' && { ok "repo cloned"; break; }
    sleep 2
  done

  # --- generate SCIP, gzip, upload (gotcha #6 on Content-Type) ---
  log "generating SCIP index"
  ( cd "$REPO_ROOT" && GOTOOLCHAIN=local GOFLAGS=-mod=mod go run ./local-codeintel-runbook/scipgen /tmp/index.scip ) || die "scipgen failed"
  gzip -kf /tmp/index.scip
  log "uploading SCIP index"
  curl -s --max-time 20 -X POST -H 'Content-Type: application/x-protobuf+scip' \
    --data-binary @/tmp/index.scip.gz \
    "${SCIP_UPLOAD}?repository=${DEMO_REPO_NAME}&commit=${sha}&root=&indexerName=scip-go&indexerVersion=v0.0.0-demo"
  echo

  # --- wait for processing to complete (DB is the source of truth) ---
  log "waiting for precise-code-intel-worker to process upload"
  for i in $(seq 1 30); do
    st=$(docker exec "$PG_CONTAINER" psql -U $PG_USER -d $PG_DB -tA \
         -c "select state from lsif_uploads order by id desc limit 1;" 2>/dev/null | tr -d '[:space:]')
    echo "  upload state: ${st:-?}"
    [ "$st" = completed ] && { ok "upload completed"; break; }
    [ "$st" = failed ] && die "upload failed — see $LOG_DIR/precise-code-intel-worker.log"
    sleep 2
  done

  # A completed upload is not immediately queryable: `worker` must recompute the
  # commit-graph so the upload becomes VISIBLE at the commit. Poll the real query
  # until `lsif` stops being null (or time out).
  log "waiting for commit-graph visibility (worker)"
  for i in $(seq 1 45); do
    v=$(curl -s --max-time 8 -H 'Content-Type: application/json' \
        -d "{\"query\":\"{repository(name:\\\"$DEMO_REPO_NAME\\\"){commit(rev:\\\"$sha\\\"){blob(path:\\\"caller.go\\\"){lsif{definitions(line:4,character:10){nodes{resource{path}}}}}}}}\"}" "$GQL")
    echo "$v" | grep -q '"path"' && { ok "upload is visible / queryable"; break; }
    sleep 2
  done

  # --- THE PROOF: definitions / references / hover across files ---
  _query_block "$sha"
}

# Run the three precise-nav queries and pretty-print them.
_query_block() { # sha
  local sha=$1
  echo; log "DEFINITIONS — from the Greet(...) call in caller.go (line 4, char 10):"
  _gql "{repository(name:\\\"$DEMO_REPO_NAME\\\"){commit(rev:\\\"$sha\\\"){blob(path:\\\"caller.go\\\"){lsif{definitions(line:4,character:10){nodes{resource{path} range{start{line character} end{line character}}}}}}}}}"
  echo; log "REFERENCES — from the Greet definition in greeter.go (line 3, char 7):"
  _gql "{repository(name:\\\"$DEMO_REPO_NAME\\\"){commit(rev:\\\"$sha\\\"){blob(path:\\\"greeter.go\\\"){lsif{references(line:3,character:7){nodes{resource{path} range{start{line character} end{line character}}}}}}}}}"
  echo; log "HOVER — over the Greet call in caller.go (line 4, char 10):"
  _gql "{repository(name:\\\"$DEMO_REPO_NAME\\\"){commit(rev:\\\"$sha\\\"){blob(path:\\\"caller.go\\\"){lsif{hover(line:4,character:10){markdown{text}}}}}}}"
}

_gql() { # graphql-query-string
  curl -s --max-time 10 -H 'Content-Type: application/json' -d "{\"query\":\"$1\"}" "$GQL" \
    | (python3 -m json.tool 2>/dev/null || cat)
}

# Ad-hoc: ./run-stack.sh query <file> <line> <char>
cmd_query() {
  local file=$1 line=$2 char=$3 sha; sha=$(cat /tmp/sg-demo-sha.txt 2>/dev/null) || die "no demo sha; run 'demo' first"
  _gql "{repository(name:\\\"$DEMO_REPO_NAME\\\"){commit(rev:\\\"$sha\\\"){blob(path:\\\"$file\\\"){lsif{definitions(line:$line,character:$char){nodes{resource{path} range{start{line character} end{line character}}}}}}}}}"
}

# Build + serve the Sourcegraph web UI (the React SPA) so search + precise nav are
# usable in a browser. Topology:
#   browser -> web dev server :3080  (serves the SPA index + JS/CSS assets, and
#              PROXIES app/API routes to the frontend on :$FRONTEND_EXT)
#   frontend renders the HTML shell (incl. window.context) using the dev asset
#   manifest in client/web/dist — which is why frontend needs WEB_BUILDER_DEV_SERVER=1
#   (the `up` subcommand sets it automatically once this bundle exists).
cmd_web() {
  local nb; nb=$(node20_bin) || die "Node 20 not found. Install it ('nvm install 20') or set NODE20_BIN=/path/to/node20/bin"
  log "using Node $("$nb/node" --version) from $nb (system default may be newer and won't build this)"
  ( cd "$REPO_ROOT"
    log "pnpm install (first run downloads ~3k packages — a few minutes)"
    PATH="$nb:$PATH" pnpm install || exit 1
    log "pnpm run generate (graphql types, json schema, css module types)"
    PATH="$nb:$PATH" pnpm run generate || exit 1
  ) || die "web dependency install / codegen failed"

  log "starting web dev server on :3080 (API proxied to :$FRONTEND_EXT)"
  ( cd "$REPO_ROOT"
    PATH="$nb:$PATH" \
    WEB_BUILDER_SERVE_INDEX=true \
    SOURCEGRAPH_API_URL=http://localhost:$FRONTEND_EXT \
    SOURCEGRAPH_HTTP_PORT=3080 \
    NODE_OPTIONS=--max_old_space_size=8192 \
    pnpm --filter @sourcegraph/web serve:dev ) >"$LOG_DIR/web.log" 2>&1 &
  echo $! >"$LOG_DIR/web.pid"
  wait_for_port 127.0.0.1 3080 120 web-server || warn "web server slow to start — check $LOG_DIR/web.log"
  warn "If frontend was started BEFORE this bundle existed, re-run '$0 up' so it serves with WEB_BUILDER_DEV_SERVER=1."
  ok "Web UI: http://localhost:3080  (first visit -> create the initial admin account)"
  ok "Demo repo blob (precise nav): http://localhost:3080/$DEMO_REPO_NAME/-/blob/caller.go"
}

# Stand up Sourcegraph's INTEGRATED indexed search (zoekt) so search works in the
# web UI and the worker stops erroring on 127.0.0.1:3070. Two cooperating procs:
#   zoekt-webserver               -> answers search queries on :3070 from an index dir
#   zoekt-sourcegraph-indexserver -> polls frontend for the repo list, fetches
#                                    archives from gitserver, writes the index
# They share $ZOEKT_INDEX. The indexserver's -hostname MUST match an entry in
# INDEXED_SEARCH_SERVERS (we use 127.0.0.1:3070, set in service_env).
#
# NOTE: this is NOT the standalone `zoekt-webserver` that indexes a local folder
# directly — that's a different, self-contained use of the same engine.
cmd_search() {
  [ -x "$BIN/frontend" ] || die "run '$0 build && $0 up' first"
  mkdir -p "$ZOEKT_BIN" "$ZOEKT_INDEX" "$LOG_DIR"
  local zv; zv=$(awk '/sourcegraph\/zoekt /{print $2; exit}' "$REPO_ROOT/go.mod")
  if [ ! -x "$ZOEKT_BIN/zoekt-webserver" ] || [ ! -x "$ZOEKT_BIN/zoekt-sourcegraph-indexserver" ]; then
    log "building zoekt search binaries ($zv)"
    ( cd "$REPO_ROOT"; GOBIN="$ZOEKT_BIN" GOTOOLCHAIN=local GOFLAGS=-mod=mod \
        go install "github.com/sourcegraph/zoekt/cmd/zoekt-webserver@$zv" \
                   "github.com/sourcegraph/zoekt/cmd/zoekt-git-index@$zv" \
                   "github.com/sourcegraph/zoekt/cmd/zoekt-sourcegraph-indexserver@$zv" ) || die "zoekt build failed"
  fi

  log "starting zoekt-webserver on :3070"
  pkill -f 'zoekt/zoekt-webserver'; sleep 1
  ( PATH="$ZOEKT_BIN:$PATH" GRPC_ENABLED=true \
    "$ZOEKT_BIN/zoekt-webserver" -index "$ZOEKT_INDEX" -rpc -indexserver_proxy -listen 127.0.0.1:3070 \
  ) >"$LOG_DIR/zoekt-web.log" 2>&1 &
  echo $! >"$LOG_DIR/zoekt-web.pid"
  wait_for_port 127.0.0.1 3070 30 zoekt-webserver

  log "starting zoekt-sourcegraph-indexserver (polls frontend :$FRONTEND_INT, indexes from gitserver)"
  # SKIP_SYMBOLS_REPOS_ALLOWLIST drops the universal-ctags/scip-ctags requirement
  # for the demo repo (text search only). Install universal-ctags + scip-ctags and
  # remove this to get symbol search.
  pkill -f 'zoekt-sourcegraph-indexserver'; sleep 1
  ( PATH="$ZOEKT_BIN:$PATH" GRPC_ENABLED=true SKIP_SYMBOLS_REPOS_ALLOWLIST="$DEMO_REPO_NAME" \
    "$ZOEKT_BIN/zoekt-sourcegraph-indexserver" \
      -sourcegraph_url "http://localhost:$FRONTEND_INT" \
      -index "$ZOEKT_INDEX" -hostname 127.0.0.1:3070 -interval 20s \
      -listen 127.0.0.1:6072 -cpu_fraction 0.25 \
  ) >"$LOG_DIR/zoekt-index.log" 2>&1 &
  echo $! >"$LOG_DIR/zoekt-index.pid"

  log "waiting for $DEMO_REPO_NAME to be indexed"
  for i in $(seq 1 25); do
    sleep 3
    ls "$ZOEKT_INDEX"/*"$DEMO_REPO_NAME"*.zoekt >/dev/null 2>&1 && { ok "indexed — search is live"; break; }
  done
  ok "try in the web UI: search  repo:$DEMO_REPO_NAME Greet"
}

cmd_status() {
  log "service processes:"
  for s in frontend gitserver repo-updater precise-code-intel-worker worker blobstore; do
    # match both absolute ($BIN/x) and relative (./.bin/x) invocations
    if pgrep -f "\.bin/$s" >/dev/null; then ok "$s alive"; else warn "$s DOWN"; fi
  done
  log "listening ports:"
  for p in "$FRONTEND_EXT frontend-ext" "$FRONTEND_INT frontend-int" "$GITSERVER_PORT gitserver" \
           "$REPOUPDATER_PORT repo-updater" "$BLOBSTORE_PORT blobstore" "$GIT_DAEMON_PORT git-daemon" \
           "3080 web-ui" "3070 zoekt-search"; do
    set -- $p; nc -z 127.0.0.1 "$1" >/dev/null 2>&1 && ok "$2 ($1)" || warn "$2 ($1) closed"
  done
  log "docker:"; docker ps --filter "name=$PG_CONTAINER" --filter "name=$REDIS_CONTAINER" --format '  {{.Names}} {{.Status}}'
}

cmd_logs() { tail -f "$LOG_DIR/${1:?usage: logs <service>}.log"; }

cmd_down() {
  log "stopping Sourcegraph services + git daemon (Docker DBs kept)"
  for s in frontend gitserver repo-updater precise-code-intel-worker worker blobstore; do pkill -f "\.bin/$s"; done
  pkill -f "git daemon.*$GIT_DAEMON_PORT"
  pkill -f 'development.server.ts'; pkill -f '@sourcegraph/web serve:dev'  # web dev server
  pkill -f 'zoekt/zoekt-webserver'; pkill -f 'zoekt-sourcegraph-indexserver'  # search
  ok "services stopped"
}

cmd_nuke() {
  cmd_down
  log "removing Docker DBs + throwaway data"
  docker rm -f "$PG_CONTAINER" "$REDIS_CONTAINER" >/dev/null 2>&1
  rm -rf "$REPOS_DIR" "$BLOBSTORE_DIR" "$DEMO_REPO" /tmp/index.scip* /tmp/sg-demo-sha.txt "$EXTSVC_FILE"
  ok "nuked (built binaries in .bin/ kept)"
}

cmd_all() { cmd_build; cmd_infra; cmd_up; cmd_demo; }

# ----------------------------- dispatch --------------------------------------
case "${1:-}" in
  build)  cmd_build ;;
  infra)  cmd_infra ;;
  up)     cmd_up ;;
  web)    cmd_web ;;
  search) cmd_search ;;
  demo)   cmd_demo ;;
  query)  shift; cmd_query "$@" ;;
  status) cmd_status ;;
  logs)   shift; cmd_logs "$@" ;;
  down)   cmd_down ;;
  nuke)   cmd_nuke ;;
  all)    cmd_all ;;
  *) sed -n '1,120p' "$0" | grep -E '^#( |=)' | sed 's/^# \{0,1\}//'; echo
     echo "Run one of: build | infra | up | web | search | demo | query | status | logs | down | nuke | all" ;;
esac
