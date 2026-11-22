const r = {};
r.crossOriginIsolated = self.crossOriginIsolated;
r.AtomicsWait = (() => { if (typeof SharedArrayBuffer === 'undefined') return 'no SAB'; try { return Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1); } catch (e) { return 'throws ' + e.message; } })();
r.AtomicsPause = typeof Atomics.pause;
r.navigatorLocks = typeof navigator.locks;
try {
  const root = await navigator.storage.getDirectory();
  const fh = await root.getFileHandle('probe.bin', { create: true });
  const h1 = await fh.createSyncAccessHandle();
  r.opfsSync = 'ok';
  try { await fh.createSyncAccessHandle(); r.opfsSecondHandle = 'allowed'; } catch (e) { r.opfsSecondHandle = 'throws ' + e.name; }
  h1.close();
  try { const h2 = await fh.createSyncAccessHandle({ mode: 'readwrite-unsafe' }); const h3 = await fh.createSyncAccessHandle({ mode: 'readwrite-unsafe' }); r.opfsUnsafeTwoHandles = 'allowed'; h2.close(); h3.close(); } catch (e) { r.opfsUnsafeTwoHandles = 'throws ' + e.name + ' ' + e.message; }
} catch (e) { r.opfsSync = 'throws ' + e.name + ' ' + e.message; }
postMessage(r);
