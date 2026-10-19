# Continuous integration and deployment

`.github/workflows/ci.yml` builds and tests everything on every push and pull request. On `main`,
it then deploys the LeanUI site (`examples/Site.lean`) to Cloudflare, served by a native Lean
server in a Cloudflare container.

## The test job

One `ubuntu-24.04` job does all of it in order. Each step depends on the one before it:

1. **Lean**: elan installs the toolchain named in `lean-toolchain` (cached).
2. **Native**: `lake build` (the `.lake/build` cache makes it incremental), then every test
   executable: `leanui-tests`, `leanui-props`, `leanui-syntax-tests`, `leanui-kit-tests`,
   `leanui-server-tests`, `leanui-todomvc-tests`, `leanui-notes-tests`.
3. **wasm64**: `toolchain/image.sh` builds the emsdk image from the fork's
   `docker-wasm64/Dockerfile` at the pinned commit. `toolchain/build-archives.sh` builds the
   single-threaded runtime archives (about half an hour on a hosted runner, then cached until
   `toolchain/fork.lock`, the patch or the script changes). `tests/browser/run-all.sh
   --build-only` builds the apps the browser suites load.
4. **Browsers**: Playwright 1.62.1 is installed outside the checkout (`LEANUI_PLAYWRIGHT_FROM`
   points the tests at it; see `tests/browser/playwright.mjs`), then `tests/browser/run-all.sh`
   runs every suite in Chromium and Firefox: todomvc, site, counter, keyed-dom, fuzz, templates,
   apply-semantics, server, effects, bench-smoke, depth.
5. **Container**: `deploy/cloudflare/stage.sh` stages the site server and its files. The image is
   built for `linux/amd64` and started, and `/`, the wasm and the stylesheet must answer. On
   `main` the staged files are uploaded for the deploy job.

`tests/browser/run-all.sh` is also the local entry point (`--build` builds the apps first). On a
shared machine, run it under the host browser lock.

## The deployment

```
browser ──HTTPS──▶ Worker (deploy/cloudflare/src/worker.js)
                     └─▶ Durable Object "site" ─▶ container: leanui-site --host 0.0.0.0 --port 8080
```

- The **container** runs `leanui-site` (examples/SiteServer.lean, built on the runner) from
  `ubuntu:24.04`, as `nobody`, with no outbound network. It renders every page (SSR), serves the
  wasm build, and runs server-driven sessions for browsers without Memory64 (Safari).
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
still runs. The site appears at `https://leanui-site.<your-subdomain>.workers.dev`. A custom
domain is a `routes` entry in `deploy/cloudflare/wrangler.jsonc` (or the dashboard's Domains &
Routes).

## Deploying by hand

The image needs a Linux x86-64 `leanui-site`, so deploy from Linux (or let CI do it), with the
wasm64 archives built once (`toolchain/build-archives.sh`, needs Docker):

```bash
lake build leanui-site && tools/build-app.sh SiteApp site && deploy/cloudflare/stage.sh
```

```bash
cd deploy/cloudflare && npm install && npx wrangler deploy
```

`wrangler deploy` needs Docker running and `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` in the
environment (or `npx wrangler login`). The versions are pinned in `deploy/cloudflare/package.json`
(no lockfile; CI installs it fresh).
