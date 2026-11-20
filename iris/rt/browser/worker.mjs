// A pool thread in a module Web Worker (index.html starts it through launch.mjs).
import { poolThread } from '../pool.mjs';

self.onmessage = (e) => poolThread(e.data.sab, e.data.progUrl, (m) => self.postMessage(m));
