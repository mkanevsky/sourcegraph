# Local from-source runbook: Sourcegraph precise code intelligence

This directory stands up the **minimum** set of Sourcegraph services — **built
from this source tree with plain `go build`** (no Bazel, no `sg`, no `dev-private`
repo, no license key) — to prove **precise code navigation** end-to-end:

```
  SCIP index  ──upload (REST)──▶  blobstore ──▶ precise-code-intel-worker
                                                          │ parse + correlate
                                                          ▼
                                              codeintel Postgres (SCIP graph)
                                                          ▲
   your app  ◀──definitions/references/hover (GraphQL)── frontend
```

Search (zoekt) is a *separate* concern and is intentionally **not** required
here — see [Relationship to search](#relationship-to-search).

## TL;DR

```bash
./run-stack.sh all      # build + start Docker DBs + start services + run the demo
# ...or step by step:
./run-stack.sh build    # go build the 7 service binaries into ../.bin/
./run-stack.sh infra    # Postgres + Redis (Docker) + schema migrations
./run-stack.sh up       # start frontend + workers + gitserver + blobstore + git daemon
./run-stack.sh demo     # create a demo repo, index it to SCIP, upload, and QUERY
./run-stack.sh status   # health
./run-stack.sh down     # stop services (keep DBs + binaries)
./run-stack.sh nuke     # stop + remove Docker DBs + scratch data
```

A successful `demo` ends by printing three GraphQL responses:
- **definitions** from a function *call* resolve to the function *definition* in another file,
- **references** from the *definition* resolve to the *call site*,
- **hover** returns the rendered signature + doc comment.

## The moving parts

| Process | Source | Responsibility | Port |
|---|---|---|---|
| **frontend** | `cmd/frontend` | GraphQL API, REST SCIP upload, web UI, **and the central config server** every other service reads from | 3082 ext (auth) / **3090 internal (no auth)** |
| **gitserver** | `cmd/gitserver` | Stores git repos on disk; answers "file X at commit Y" | 3178 |
| **repo-updater** | `cmd/repo-updater` | Reads code-host (external service) config, schedules clones on gitserver | 3182 |
| **precise-code-intel-worker** | `cmd/precise-code-intel-worker` | The precise-nav engine: pulls the raw SCIP blob, parses/correlates, writes the SCIP graph to the codeintel DB | — |
| **worker** | `cmd/worker` | Background jobs; here the **commit-graph updater** that makes uploads *visible* at commits | — |
| **blobstore** | `cmd/blobstore` | S3-compatible store for raw uploaded SCIP files | 9000 |
| **migrator** | `cmd/migrator` | One-shot schema migrations for both DBs | — |
| Postgres | Docker | Two DBs: `sourcegraph` (frontend) + `sourcegraph_codeintel` (SCIP graph) | 5433 |
| Redis | Docker | Cache + simple queues | 6380 |
| git daemon | system `git` | Throwaway `git://` host for the demo repo (OTHER code host can't use `file://`) | 9418 |

### Data flow, in words

1. `repo-updater` reads the **OTHER external service** (`EXTSVC_CONFIG_FILE`) and
   tells `gitserver` to clone the demo repo from the `git daemon`.
2. A SCIP index is `POST`ed to `frontend` at `/.internal/scip/upload`; frontend
   stores the blob in `blobstore` and enqueues a row in the frontend DB.
3. `precise-code-intel-worker` dequeues it, downloads the blob, parses the SCIP,
   validates document paths against `gitserver`, and writes
   documents/symbols/occurrences into the **codeintel DB**.
4. `worker` recomputes the commit graph so the upload becomes *visible*.
5. A GraphQL query `repository.commit.blob.lsif.{definitions,references,hover}`
   reads the codeintel DB and returns cross-file results.

## How the integration surface works (for your app)

Precise nav is **REST (ingest) + GraphQL (query)** — there is no standalone gRPC
service for it.

**Ingest** (REST):
```bash
curl -X POST -H 'Content-Type: application/x-protobuf+scip' \
  --data-binary @index.scip.gz \
  'http://127.0.0.1:3090/.internal/scip/upload?repository=<name>&commit=<sha>&root=&indexerName=<tool>&indexerVersion=<v>'
```

**Query** (GraphQL):
```graphql
{ repository(name:"<name>") { commit(rev:"<sha>") {
    blob(path:"caller.go") { lsif {
      definitions(line:4, character:10) {        # 0-based line/char
        nodes { resource { path } range { start { line character } end { line character } } }
      } } } } }
```

- **Internal API** `http://127.0.0.1:3090/.internal/{graphql,scip/upload}` — no
  auth, intended for service-to-service; what this runbook uses.
- **Public API** `http://127.0.0.1:3082/.api/{graphql,scip/upload}` — same
  shapes, but requires `Authorization: token <sourcegraph-access-token>`.

## Configuration knobs

All ports, container names, and data dirs are variables at the top of
`run-stack.sh`. The service environment is assembled in one place —
`service_env()` — which takes a single role argument:

- `server` → **frontend only** (it serves configuration), and
- `client` → every other service (they fetch configuration from frontend).

To point at an existing Postgres/Redis instead of the Docker ones, edit the
`PG_*` / `REDIS_*` vars (or the `PGHOST`/`CODEINTEL_PGHOST`/`REDIS_ENDPOINT`
exports in `service_env`).

## Gotchas this runbook encodes (none are documented upstream)

1. **Build with the system Go (≥1.23), not the pinned 1.22.4.** On recent macOS
   (Darwin 25+), 1.22.4-linked binaries fail at runtime with
   `missing LC_UUID load command`. The script forces `GOTOOLCHAIN=local`.
2. `CONFIGURATION_MODE=server` for frontend; `=client` for everyone else
   (frontend otherwise panics: *"cannot call this function while in client mode"*).
3. `SRC_PROF_HTTP=` (empty) on every process, else they all collide on the
   debug port `:6060`.
4. `SRC_OOBMIGRATION_CURRENT_VERSION=5.5.0` for `worker` — this public snapshot
   has **no git version tags**, so worker can't infer its version and dies.
5. `BLOBSTORE_DATA_DIR` — blobstore defaults to the read-only `/data`.
6. SCIP upload **must** use `Content-Type: application/x-protobuf+scip`.
7. The OTHER external service URL must be `git://`, `ssh://`, or `http(s)://`
   (not `file://`) — hence the local `git daemon`.
8. **Web UI:** build it with **Node 20** (not the system default), and start
   `frontend` with **`WEB_BUILDER_DEV_SERVER=1`** so it serves HTML from the
   `client/web/dist` manifest instead of the production `/assets-dist` path.
9. **Search:** the zoekt indexserver's `-hostname` must exactly match an entry in
   `INDEXED_SEARCH_SERVERS` (`127.0.0.1:3070`, not `localhost:3070`), and symbol
   indexing requires `universal-ctags`/`scip-ctags` (skipped for the demo repo).

## The demo SCIP index

`scipgen/main.go` hand-builds a valid SCIP index using the in-repo `scip` Go
bindings, because `scip-go` can't be installed (its older releases depend on the
now-private `github.com/sourcegraph/sourcegraph/lib`). It encodes one definition
(`Greet` in `greeter.go`) and one reference (the `Greet(...)` call in
`caller.go`) sharing a single SCIP symbol — see the comments in that file. Swap
in a real `scip-go`/`scip-typescript` index for non-demo use.

## Web UI (optional)

The Go services serve the GraphQL/REST API but **not** the rendered React app. To
get search + precise navigation in a browser:

```bash
./run-stack.sh web      # pnpm install + codegen + serve the SPA on :3080
./run-stack.sh up       # re-run so frontend serves with WEB_BUILDER_DEV_SERVER=1
```

Then open **http://localhost:3080** → create the initial admin account → browse,
e.g. **http://localhost:3080/sg-demo-repo/-/blob/caller.go** and hover over
`Greet` to see hover / go-to-definition / find-references in the page.

**Requires Node 20** (the repo's pinned version). The system Node is often newer
and breaks the 2024-era esbuild/ts-node build; the script auto-detects an
nvm-installed `v20.x` or honours `NODE20_BIN`. (`nvm install 20` if you have none.)

### How the web topology works (and the asset gotcha)

```
browser ──▶ web dev server :3080 ──proxies app+API routes──▶ frontend :3082
              (serves the SPA index.html + JS/CSS assets)        (renders the
                                                                  HTML shell +
                                                                  window.context)
```

The web dev server serves the SPA shell locally **but still proxies navigations
to `frontend`** to obtain `window.context`. So `frontend` must render valid HTML,
which means it must load the **web asset manifest** (`client/web/dist/web.manifest.json`).
`frontend` only uses that dev manifest when started with **`WEB_BUILDER_DEV_SERVER=1`**
(see `cmd/frontend/shared/service.go` → `assets.UseDevAssetsProvider()`); otherwise
it looks in the production path `/assets-dist` and 500s on every HTML page.
`run-stack.sh up` sets this env automatically once the bundle exists. Gotcha #8.

## Search (optional)

Indexed code search uses **zoekt**, wired to the stack as two cooperating
processes (run `./run-stack.sh search`):

| Process | Source | Responsibility | Port |
|---|---|---|---|
| **zoekt-webserver** | `github.com/sourcegraph/zoekt` | Answers indexed-search queries from a shared index dir. This is what `INDEXED_SEARCH_SERVERS=127.0.0.1:3070` points at. | 3070 |
| **zoekt-sourcegraph-indexserver** | same | Polls `frontend` (`-sourcegraph_url`) for the repo list, fetches archives from `gitserver`, and writes the index. | debug 6072 |

They share `~/.sourcegraph/zoekt/index-0`. The indexserver's `-hostname` **must
equal** an entry in `INDEXED_SEARCH_SERVERS` (we use `127.0.0.1:3070`; a
`localhost` vs `127.0.0.1` mismatch makes frontend reject it — Gotcha #9).

Without this running, precise nav still works fine, but web-UI search is empty
and `worker` logs `dial tcp 127.0.0.1:3070: connect: connection refused`.

**Symbol search needs ctags.** `zoekt-git-index` is invoked with `-require_ctags`
and a language map that routes Go/TS/etc. to `scip-ctags`. Since neither
`universal-ctags` nor `scip-ctags` ships here, the runbook sets
`SKIP_SYMBOLS_REPOS_ALLOWLIST=sg-demo-repo` so the demo repo indexes **text-only**.
Install `universal-ctags` + `scip-ctags` and drop that env to enable symbol search.

> Note: this is different from using zoekt **standalone** (`zoekt-git-index` a
> local folder + `zoekt-webserver` serving it directly), which needs no
> Postgres/gitserver/frontend at all. An orchestration app that only wants search
> can use that standalone mode and skip this entire stack.
