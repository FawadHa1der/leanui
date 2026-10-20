// Every request goes to the one site container, which renders the pages (SSR), serves the wasm
// build, and runs server-driven sessions for browsers without Memory64.
import { Container } from "@cloudflare/containers";

export class SiteServer extends Container {
  defaultPort = 8080;
  // Asleep after 15 idle minutes; the next request starts it again. Sessions do not survive that:
  // a page whose session is gone gets 410 and reloads once (docs/SERVER.md).
  sleepAfter = "15m";
  // The site needs no outbound network.
  enableInternet = false;

  // The container sends precompressed bodies (brotli quality 11, gzip -9). The library pipes each
  // response through an IdentityTransformStream (to count requests in flight), which makes the
  // runtime decode the body and compress it again at brotli quality 5: about 20% larger, and
  // chunked. "manual" keeps the container's bytes as they are.
  async fetch(request) {
    return this.containerFetch(new Request(request, { encodeResponseBody: "manual" }), this.defaultPort);
  }
}

export default {
  async fetch(request, env) {
    return env.SITE.getByName("site").fetch(request);
  },
};
