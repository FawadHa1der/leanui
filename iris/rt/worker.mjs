// A pool thread under Node's worker_threads (launch.mjs starts it).
import { workerData, parentPort } from 'node:worker_threads';
import { poolThread } from './pool.mjs';

await poolThread(workerData.sab, workerData.progUrl, (m) => parentPort.postMessage(m));
