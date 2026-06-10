# Session handoff — Sourcegraph public-snapshot: local code indexing/nav/retrieval

## Goal
Evaluate this repo (last public Sourcegraph snapshot, ~v5.x, Aug 2024) for
**code indexing, navigation, and retrieval** usable by an external "code dev
orchestration" app; run it **from source** (modifiable/rebuildable), with minimal
changes, and prove minimal capability with verifiable steps.

## What was accomplished (all proven, from source, no Bazel / no `sg` / no dev-private / no license)
1. **Evaluated** the repo: core = `frontend`, `gitserver`, `searcher`, `symbols`,
   zoekt, `worker`, `precise-code-intel-worker`. Not needed: Cody/embeddings,
   batch changes/executors, code insights, observability, appliance, etc.
2. **Search (standalone zoekt):** built `zoekt-git-index`/`zoekt-webserver`/`zoekt`
   from the `github.com/sourcegraph/zoekt` dependency; indexed this repo (~15.7k
   files) and served the JSON search API on **:6070**. (This was the first proof;
   may or may not still be running.)
3. **Precise code intel:** built `frontend gitserver repo-updater worker
   precise-code-intel-worker blobstore migrator` from source and ran the full
   pipeline. Proved **REST SCIP upload → processing → GraphQL definitions /
   references / hover** end-to-end against real Postgres.
4. **Web UI:** built `client/web` (Node 20 + pnpm) and serve it on **:3080**
   (esbuild dev server proxying API to frontend); sign-in/site-init works.
5. **Integrated search:** `zoekt-webserver` (:3070) + `zoekt-sourcegraph-indexserver`
   wired to frontend; `sg-demo-repo` indexed; `search repo:sg-demo-repo Greet`
   returns matches; `worker`'s :3070 errors stopped.
6. **Runbook authored** in `local-codeintel-runbook/` (script + docs + integration
   guide) and validated.

## Deliverables (in `local-codeintel-runbook/`)
- `run-stack.sh` — subcommands: `build | infra | up | web | search | demo | query | status | logs | down | nuke | all`.
- `scipgen/main.go` — hand-builds a valid demo SCIP index (scip-go uninstallable here).
- `README.md` — architecture, data flow, topology, gotchas (#1–#9).
- `integration.md` — integration points, DTOs, API considerations for external apps.

## Current running state (as of handoff)
- Services UP (binaries in `.bin/`): frontend, gitserver, repo-updater, worker,
  precise-code-intel-worker, blobstore; zoekt-webserver(:3070) + zoekt-indexserver.
- Web UI UP on **:3080** (Node 20 dev server). Frontend started with
  `WEB_BUILDER_DEV_SERVER=1`.
- Docker: `sg-testpg` (Postgres 12, :5433), `sg-redis` (:6380).
- Ports: frontend 3082(ext)/3090(internal,no-auth), gitserver 3178, repo-updater
  3182, blobstore 9000, git-daemon 9418, web 3080, zoekt 3070.
- Demo repo `sg-demo-repo` registered (OTHER via git daemon serving /tmp), cloned,
  SCIP uploaded + visible. Latest commit sha in `/tmp/sg-demo-sha.txt`.
- Logs in `/tmp/sg-logs/`. Env snapshot in `/tmp/sg-env.sh`. Index `~/.sourcegraph/zoekt/index-0`.

## Restart / continue
```bash
cd /Users/michaelk/Development/moniq_ai/sourcegraph
./local-codeintel-runbook/run-stack.sh status      # what's up
./local-codeintel-runbook/run-stack.sh all         # build+infra+up+demo from scratch
# web + search are separate optional steps:
./local-codeintel-runbook/run-stack.sh web         # then re-run `up`
./local-codeintel-runbook/run-stack.sh search
./local-codeintel-runbook/run-stack.sh down        # stop services (keep DBs)
./local-codeintel-runbook/run-stack.sh nuke        # + remove DBs/scratch data
```
Browser: http://localhost:3080 (create initial admin) →
http://localhost:3080/sg-demo-repo/-/blob/caller.go (hover `Greet`).

## Hard-won gotchas (full list in README.md)
1. Build service binaries with **system Go ≥1.23**, not pinned 1.22.4 — 1.22.4
   binaries fail on Darwin 25 with `missing LC_UUID`. (But codenav `lsifstore`/
   `graphql` **test** packages need 1.22.4 due to old `golang.org/x/tools`.)
2. frontend `CONFIGURATION_MODE=server`, all others `client`.
3. `SRC_PROF_HTTP=` empty (else :6060 debug-port clash).
4. `SRC_OOBMIGRATION_CURRENT_VERSION=5.5.0` for worker (snapshot has no git tags).
5. `BLOBSTORE_DATA_DIR` (defaults to read-only /data).
6. SCIP upload Content-Type = `application/x-protobuf+scip`, gzip body.
7. OTHER external service URL must be git/ssh/http(s), not file:// (used git daemon).
8. Web UI: Node 20 + frontend `WEB_BUILDER_DEV_SERVER=1` (serves from client/web/dist).
9. zoekt indexserver `-hostname` must match `INDEXED_SEARCH_SERVERS` exactly
   (`127.0.0.1:3070`, not `localhost`); symbol indexing needs ctags.

## PENDING TASKS
- [ ] **Symbol search** (DEFERRED by user): install `universal-ctags` + `scip-ctags`,
      drop `SKIP_SYMBOLS_REPOS_ALLOWLIST=sg-demo-repo` in `run-stack.sh search`
      → enables symbol search. Currently search is **text-only**.
- [ ] **Close the precise-nav test gap**: 2 codenav test packages
      (`internal/codeintel/codenav/internal/lsifstore`, `.../transport/graphql`)
      fail to *build under Go 1.25* (old `golang.org/x/tools`). Rerun under
      `GOTOOLCHAIN=go1.22.4` to make the precise-nav test proof 100% green.
      (Service binaries are unaffected — they build fine on 1.25.)
- [ ] **Repo hygiene decision** (offered, unanswered): add `.gitignore` for
      `local-codeintel-runbook/` and `.bin/`, or move the runbook outside the
      sourcegraph tree. Currently untracked inside the repo.
- [ ] (Optional) Wire `web` + `search` into a single `up`/`all` flow if desired
      (currently separate optional subcommands).

## Notes
- Internal API `:3090/.internal/{graphql,scip/upload}` is unauthenticated — used
  for all demo/query calls. Public `:3082/.api/...` needs `Authorization: token`.
- Positions are 0-based; SCIP upload→queryable is eventually consistent.
