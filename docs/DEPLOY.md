# Continuous integration and deployment

`.github/workflows/ci.yml` builds and tests everything on every push and pull request. On `main`
(a push, or a manual run of the workflow on `main`), it then deploys the LeanUI site (`examples/Site.lean`) to Cloudflare, served by a native Lean
server in a Cloudflare container.

## The test job

One `ubuntu-24.04` job does all of it in order. Each step depends on the one before it:

1. **Lean**: elan installs the toolchains named in `lean-toolchain` and `vir/lean-toolchain`
   (lean-vir's release, for the benchmark builds in `vir/`; cached).
2. **Native**: `lake build` (the `.lake/build` cache makes it incremental; after a `lakefile.toml`
   change it starts from the newest build of the same toolchain), then every test
   executable: `leanui-tests`, `leanui-props`, `leanui-syntax-tests`, `leanui-kit-tests`,
   `leanui-server-tests`, `leanui-todomvc-tests`, `leanui-notes-tests`, `leanui-editor-tests`.
3. **wasm64**: `toolchain/image.sh` builds the emsdk image from the fork's
   `docker-wasm64/Dockerfile` at the pinned commit. `toolchain/build-archives.sh` builds the
   single-threaded runtime archives (about half an hour on a hosted runner, then cached until
   `toolchain/fork.lock`, the patch or the script changes). `tests/browser/run-all.sh
   --build-only` builds the apps the browser suites load: the wasm64 builds, then the lean-vir
   builds of the benchmarked apps (`vir/build.sh`, its `vir/.lake` cached like `.lake/build`), the
   QED64 lane (`qed64/build.sh`, its downloads and builds in `qed64/.cache`), the race page
   (`bench/race/build.sh`, into `dist/race`) and the Roster demo's verify page
   (`roster/verify/build.sh`, with Rust's `wasm32-wasip1` target and Lean 4.35).
4. **Browsers**: Playwright 1.62.1 is installed outside the checkout (`LEANUI_PLAYWRIGHT_FROM`
   points the tests at it; see `tests/browser/playwright.mjs`), then `tests/browser/run-all.sh`
   runs every suite in Chromium and Firefox: todomvc, site, counter, keyed-dom, fuzz, templates,
   apply-semantics, server, effects, bench-smoke, pixels, editor, video, depth, race, and the
   Roster demo's (the app against `leanui-roster`, which notarizes, and the receipt it makes on the
   verify page).
5. **Container**: `deploy/cloudflare/stage.sh` stages the site server and its files (`dist/site`,
   `dist/editor`, `dist/race`, `dist/roster` with the Roster demo's one receipt, notarized then),
   and writes brotli (quality 11) and gzip siblings of every `.wasm`, `.js`, `.mjs`, `.irpkg` and
   `.ndjson` file. The image is built for `linux/amd64` and started, and `/`, the wasm, the
   stylesheet, the editor, the video lab, the race page (with a wasm64 and a lean-vir file of it)
   and the Roster demo must answer, the wasm and the receipt brotli-encoded to a client that
   accepts it; the Roster demo's app and verify page are tested in Chromium against it. On `main`
   the staged files are uploaded for the deploy job.

`tests/browser/run-all.sh` is also the local entry point (`--build` builds the apps first). On a
shared machine, run it under the host browser lock.

## The deployment

```
browser ──HTTPS──▶ Worker (deploy/cloudflare/src/worker.js)
                     └─▶ Durable Object "site" ─▶ container: leanui-site --host 0.0.0.0 --port 8080
```

- The **container** runs `leanui-site` (examples/SiteServer.lean, built on the runner) from
  `ubuntu:24.04`, as `nobody`, with no outbound network. It renders every page (SSR), serves the
  wasm build, and runs server-driven sessions for browsers without Memory64 (Safari). It also
  serves the photo editor as its own page, `/editor/` (`dist/editor`, a client-side wasm app with
  no server rendering: browsers without Memory64 get a message instead), its video lab,
  `/editor/video/` (`dist/editor/video`), and the race page, `/race/` (`dist/race`, static files:
  the same apps in vanilla JavaScript, wasm64 and lean-vir side by side; `bench/race/`). lean-vir
  runs only there: the site and the editor are the wasm64 builds. And the Roster demo, `/roster/`
  (`dist/roster`: the app and its verify page, with one receipt made when the site was staged;
  no notary, which needs Lean 4.35; `roster/README.md`).
- **Compression**: the server sends the precompressed `.br`/`.gz` siblings to clients that
  accept them (`Content-Encoding`, `Vary: Accept-Encoding`). Brotli at quality 11 is smaller than
  compression on the fly: the site's wasm is 194 KB. The container's response does not reach the
  visitor as is, though: `@cloudflare/containers` (since 0.2.1) pipes every response through an
  `IdentityTransformStream` to count requests in flight, and the Workers runtime decodes the body
  in that pipe and compresses it again on the way out, at brotli quality 5 (the site's wasm became
  236 KB, chunked). `SiteServer.fetch` in `src/worker.js` therefore fetches the container with
  `encodeResponseBody: "manual"`, which keeps its bytes as they are (still chunked, without
  `Content-Length`). Cloudflare also adds br to the request's `Accept-Encoding` before it reaches
  the container, so the server always picks the `.br` sibling, and a client without brotli gets
  the edge's transcode of it. After each deploy the deploy job checks that the served wasm is the
  file the server sent: its size, which the server puts in the ETag, and that it decodes.
- **One instance** (`max_instances: 1`, one Durable Object name): a server-driven session lives in
  that process's memory, so every request must reach the same process. The site's traffic fits
  one `basic` instance (1/4 vCPU, 1 GiB). The more sessions are live at once, the more memory it
  takes; `docs/SERVER.md` lists the session caps.
- **Sleep**: the container stops after 15 idle minutes (`sleepAfter`), and the next request
  starts it again, which takes a few seconds. Live sessions end with it. A page whose session is
  gone gets `410` and reloads once (`docs/SERVER.md`), and pages running in wasm are not
  affected. On `SIGTERM` the server closes its sessions and exits.
- **Updates**: `wrangler deploy` builds the image locally, uploads the Worker, then pushes the
  image and rolls the container out (stop with `SIGTERM`, start on the new image). A failed image
  build changes nothing; a failed push leaves the new Worker version live on the old image. Right
  after the first deploy, requests can fail for a few minutes until the container is ready.

## Setup (once, by the repository owner)

1. A Cloudflare account on the **Workers Paid** plan (Containers are not on the free plan; the
   $5/month plan includes 25 GiB-hours of memory, 375 vCPU-minutes and 200 GB-hours of disk a
   month, and usage beyond that is billed).
2. An API token: Cloudflare dashboard → My Profile → API Tokens → Create Token → the **Edit
   Cloudflare Workers** template, limited to your account, plus **Account → Containers → Edit**
   (the template does not include it). Without it the deploy fails after "Uploaded leanui-site",
   on the `.../containers/...` API calls, and the site stays unreachable.
3. The account ID, from the dashboard's Workers & Pages overview.
4. Both as repository secrets (Settings → Secrets and variables → Actions), or with the GitHub CLI:

   ```bash
   gh secret set CLOUDFLARE_API_TOKEN --repo FawadHa1der/leanui
   ```

   ```bash
   gh secret set CLOUDFLARE_ACCOUNT_ID --repo FawadHa1der/leanui
   ```

Until both secrets exist, the deploy job prints a notice and skips the deploy. Everything else
still runs. To redeploy without a new commit, run the workflow on `main` by hand (Actions → CI →
Run workflow). After the deploy it fetches the site's and the editor's wasm with brotli and fails
if a body is not the precompressed file the server sent (see "Compression" above). When
`wrangler deploy` fails, the job prints wrangler's own log
(`~/.config/.wrangler/logs`). The site appears at `https://leanui-site.<your-subdomain>.workers.dev`. `wrangler.jsonc` sets `workers_dev: true` (that URL) and `preview_urls: false` (no extra
preview URL per uploaded version). A custom domain is a `routes` entry in `deploy/cloudflare/wrangler.jsonc` (or the dashboard's Domains &
Routes).

## Deploying by hand

The image needs a Linux x86-64 `leanui-site`, so deploy from Linux (or let CI do it), with the
wasm64 archives built once (`toolchain/build-archives.sh`, needs Docker):

```bash
lake build leanui-site leanui-roster && tools/build-app.sh SiteApp site && tools/build-app.sh EditorApp editor &&
  tools/build-app.sh VideoApp editor/video && tools/build-app.sh LifeApp life &&
  tools/build-app.sh BenchApp bench && vir/build.sh && bench/race/build.sh &&
  tools/build-app.sh RosterApp roster && roster/verify/build.sh && deploy/cloudflare/stage.sh
```

```bash
cd deploy/cloudflare && npm install && npx wrangler deploy
```

`wrangler deploy` needs Docker running and `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` in the
environment (or `npx wrangler login`). The versions are pinned in `deploy/cloudflare/package.json`
(no lockfile; CI installs it fresh).
