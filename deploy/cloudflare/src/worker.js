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
}

export default {
  async fetch(request, env) {
    return env.SITE.getByName("site").fetch(request);
  },
};
