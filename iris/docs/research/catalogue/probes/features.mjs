// P0: which concurrency features this Node exposes (and Atomics.wait on the main thread).
import * as wt from 'node:worker_threads';
const f = {};
f.node = process.version; f.v8 = process.versions.v8;
f.AtomicsPause = typeof Atomics.pause; f.AtomicsWaitAsync = typeof Atomics.waitAsync;
f.growableSAB = (() => { try { const s = new SharedArrayBuffer(8, { maxByteLength: 64 }); s.grow(16); return s.byteLength === 16 && s.growable; } catch (e) { return String(e); } })();
f.ArrayBufferTransfer = typeof ArrayBuffer.prototype.transfer;
f.structuredClone = typeof structuredClone;
f.BroadcastChannel = typeof BroadcastChannel; f.MessageChannel = typeof MessageChannel;
f.receiveMessageOnPort = typeof wt.receiveMessageOnPort; f.markAsUntransferable = typeof wt.markAsUntransferable;
f.navigatorLocks = typeof globalThis.navigator?.locks; f.hardwareConcurrency = globalThis.navigator?.hardwareConcurrency;
f.Float16Array = typeof globalThis.Float16Array;
f.wasmThreadsValidate = (() => { // (module (memory 1 1 shared) (func (result i32) i32.const 0 i32.const 1 i32.atomic.rmw.add))
  try { return WebAssembly.validate(new Uint8Array([0,97,115,109,1,0,0,0,1,5,1,96,0,1,127,3,2,1,0,5,4,1,3,1,1,10,12,1,10,0,65,0,65,1,254,30,2,0,11])); } catch (e) { return String(e); } })();
f.mainThreadAtomicsWait = (() => { const i = new Int32Array(new SharedArrayBuffer(4)); try { return Atomics.wait(i, 0, 0, 1); } catch (e) { return 'throws: ' + e.message; } })();
f.waitNotEqual = Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 1, 1);
// Atomics.waitAsync result shape
if (Atomics.waitAsync) { const r = Atomics.waitAsync(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5); f.waitAsyncShape = { async: r.async, value: String(r.value) }; const keep = setInterval(() => {}, 1000); const t0 = performance.now(); f.waitAsyncResolved = await r.value; f.waitAsyncMs = +(performance.now() - t0).toFixed(1); clearInterval(keep); }
// transfer detaches
{ const { port1, port2 } = new MessageChannel(); const b = new ArrayBuffer(1024); port1.postMessage(b, [b]); f.detachedAfterTransfer = b.byteLength === 0 && b.detached; port1.close(); port2.close(); }
// SAB is shared, not copied, by postMessage
{ const { port1, port2 } = new MessageChannel(); const s = new SharedArrayBuffer(4); const got = new Promise(r => port2.once('message', r)); port1.postMessage(s); const s2 = await got; new Int32Array(s2)[0] = 42; f.sabSharedByPostMessage = new Int32Array(s)[0] === 42; port1.close(); port2.close(); }
console.log(JSON.stringify(f, null, 1));
