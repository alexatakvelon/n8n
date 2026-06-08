# Agentic Sandbox — Node.js built-in example

Run user-supplied JavaScript in a fully isolated environment with no external dependencies — only Node.js built-ins.

## What this example does

User code runs inside two nested isolation layers:

```
Host process (run.js)
   │ spawns Worker thread  ← primary isolation
   │   resourceLimits: maxOldGenerationSizeMb=64
   │   wall-clock timeout enforced by host timer
   ▼
Worker thread (sandbox-worker.js)
   │ vm.createContext(sandbox)  ← secondary isolation
   │   no require, no process, no fs
   │   only allowlisted pure globals (JSON, Math, Date, …)
   ▼
User code runs here
   │ console.log → parentPort.postMessage({ type: 'log' })
   │ return value → parentPort.postMessage({ type: 'result' })
   └ any throw → parentPort.postMessage({ type: 'error' })
```

**Worker thread** (`worker_threads`) gives OS-level process isolation and a hard V8 heap cap — an OOM in user code kills the worker, not the host.

**`vm.createContext`** strips dangerous globals. `require`, `process`, `__dirname`, `Buffer`, and all I/O APIs are absent. Only safe, pure built-ins are available.

## Prerequisites

Node.js ≥ 16 (worker_threads and vm are built-in — no `npm install` needed).

## Run

```bash
node examples/agentic-sandbox/run.js
```

Expected output:

```
=== Example 1: Hello World ===
sandbox console output : [ 'Hello, World! (from inside the sandbox)' ]
returned value         : { message: 'Hello, World!', timestamp: '...' }

=== Example 2: Input/output with $input ===
sandbox console output : [ 'doubled: [2,4,6,8,10]' ]
returned value         : { doubled: [ 2, 4, 6, 8, 10 ], sum: 30 }

=== Example 3: Isolation (require is blocked) ===
sandbox correctly blocked the escape attempt:
  require is not defined
```

## File layout

```
examples/agentic-sandbox/
├── run.js             — entry point: spawns workers, runs three demo cases
└── sandbox-worker.js  — isolated worker: builds vm context, executes user code
```

## API

### `runInSandbox(code, context?, timeoutMs?)` — `run.js`

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `code` | `string` | — | JavaScript source. Top-level `return` and `await` work. |
| `context` | `object` | `{}` | Plain object injected as globals (e.g. `{ $input: [...] }`). |
| `timeoutMs` | `number` | `5000` | Wall-clock limit. Worker is force-terminated if exceeded. |

Returns a `Promise<{ result: unknown, logs: string[] }>`.

```js
const { result, logs } = await runInSandbox(
  `return { doubled: $input.map(n => n * 2) }`,
  { $input: [1, 2, 3] },
);
// result → { doubled: [2, 4, 6] }
// logs   → []
```

## Globals available inside the sandbox

| Global | Notes |
|--------|-------|
| `console.log/error/warn` | Output is captured and returned in `logs` |
| `JSON`, `Math`, `Date` | Standard built-ins |
| `Array`, `Object`, `String`, `Number`, `Boolean` | Standard built-ins |
| `Promise`, `Error`, `TypeError`, `RangeError` | Standard built-ins |
| `parseInt`, `parseFloat`, `isNaN`, `isFinite` | Standard built-ins |
| `encodeURIComponent`, `decodeURIComponent` | Standard built-ins |
| anything in `context` | Caller-supplied data (e.g. `$input`) |

Everything else (`require`, `process`, `fs`, `fetch`, `Buffer`, `global`, `__dirname`, …) is **not present** and will throw `ReferenceError`.

## Timeout behaviour

Two independent timeouts protect the host:

| Layer | Mechanism | What it catches |
|-------|-----------|-----------------|
| vm-level | `vm.Script.runInContext({ timeout: 4500 })` | Synchronous infinite loops |
| Worker-level | `setTimeout` + `worker.terminate()` | Async runaway code, `Promise` that never settles |

The vm timeout (4.5 s) is set slightly below the Worker timeout (5 s default) so synchronous loops are caught first with a cleaner error message.

## Adapting this example

**Expose more globals** — add entries to the `sandbox` object in `sandbox-worker.js`.

**Restrict further** — remove entries you don't need (e.g. remove `Date` if determinism matters).

**Use in an n8n node** — call `runInSandbox` from an `INodeType.execute()` method, passing `this.getInputData()` as `context.$input`.

**Swap for Kubernetes-backed isolation** — see the [`../n8n-sandbox`](../n8n-sandbox) example, which runs the same idea using real pod-level isolation via the Agent Sandbox Kubernetes operator.
