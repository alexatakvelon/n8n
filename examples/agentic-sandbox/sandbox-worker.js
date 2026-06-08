'use strict';

// This file runs inside an isolated Worker thread.
// It provides a second isolation layer via Node's built-in vm module:
// user code sees only the explicitly allowlisted globals below —
// require, process, fs, child_process, etc. are intentionally absent.

const { workerData, parentPort } = require('worker_threads');
const vm = require('vm');

const { code, context } = workerData;

// Build a restricted sandbox context. Only safe, pure globals are exposed.
const sandbox = vm.createContext({
  // Caller-supplied data (e.g. $input)
  ...context,

  // Redirect console output through the message channel so the host can
  // capture and display it without the worker writing directly to stdout.
  console: {
    log: (...args) => parentPort.postMessage({ type: 'log', data: args.join(' ') }),
    error: (...args) => parentPort.postMessage({ type: 'log', data: '[error] ' + args.join(' ') }),
    warn: (...args) => parentPort.postMessage({ type: 'log', data: '[warn] ' + args.join(' ') }),
  },

  // Safe built-ins only — no I/O, no network, no process
  JSON,
  Math,
  Date,
  Array,
  Object,
  String,
  Number,
  Boolean,
  Promise,
  Error,
  TypeError,
  RangeError,
  parseInt,
  parseFloat,
  isNaN,
  isFinite,
  encodeURIComponent,
  decodeURIComponent,
});

async function run() {
  // Wrap user code in an async IIFE so top-level `return` and `await` work.
  const wrapped = `(async function __sandbox__() {\n${code}\n})()`;

  // vm-level timeout (4.5 s) catches synchronous infinite loops.
  // The Worker-level timer in run.js catches async runaway code.
  const script = new vm.Script(wrapped, { filename: 'user-code.js' });
  const result = await script.runInContext(sandbox, { timeout: 4500 });

  parentPort.postMessage({ type: 'result', data: result });
}

run().catch((err) => {
  // Surface the error back to the host; worker exits non-zero automatically.
  parentPort.postMessage({ type: 'error', data: err.message ?? String(err) });
  process.exit(1);
});
