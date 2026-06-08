'use strict';

// Agentic Sandbox — minimal runnable example
//
// Demonstrates safe execution of user-supplied code inside an isolated
// Worker thread (primary isolation) backed by a vm.createContext sandbox
// (secondary isolation). No external dependencies — only Node.js built-ins.
//
// Run with:  node examples/agentic-sandbox/run.js

const { Worker } = require('worker_threads');
const path = require('path');

// ---------------------------------------------------------------------------
// runInSandbox — spawns a Worker thread and executes `code` inside it.
//   code       : string of JavaScript to run (top-level `return` is allowed)
//   context    : plain object injected as globals (e.g. { $input: [...] })
//   timeoutMs  : wall-clock limit before the Worker is force-terminated
// ---------------------------------------------------------------------------
function runInSandbox(code, context = {}, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const worker = new Worker(
      path.join(__dirname, 'sandbox-worker.js'),
      {
        // workerData is the only channel into the Worker — no shared memory
        workerData: { code, context },
        // V8 heap cap: OOM kills the worker, not the host process
        resourceLimits: {
          maxOldGenerationSizeMb: 64,
          maxYoungGenerationSizeMb: 16,
        },
      },
    );

    const logs = [];

    // Wall-clock timeout: terminates the Worker if code runs too long
    const timer = setTimeout(() => {
      void worker.terminate();
      reject(new Error(`Sandbox timed out after ${timeoutMs}ms`));
    }, timeoutMs);

    worker.on('message', (msg) => {
      if (msg.type === 'log') {
        logs.push(msg.data);
      } else if (msg.type === 'result') {
        clearTimeout(timer);
        resolve({ result: msg.data, logs });
      } else if (msg.type === 'error') {
        clearTimeout(timer);
        reject(new Error(msg.data));
      }
    });

    worker.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });

    worker.on('exit', (code) => {
      // exit event fires after 'message' (result/error), so only reject here
      // if nothing was already resolved/rejected by a prior message.
      clearTimeout(timer);
      if (code !== 0) {
        reject(new Error(`Sandbox worker exited with code ${code}`));
      }
    });
  });
}

// ---------------------------------------------------------------------------
// Examples
// ---------------------------------------------------------------------------

async function main() {
  // ── 1. Hello World ────────────────────────────────────────────────────────
  console.log('=== Example 1: Hello World ===');
  {
    const code = `
      console.log('Hello, World! (from inside the sandbox)');
      return { message: 'Hello, World!', timestamp: new Date().toISOString() };
    `;

    const { result, logs } = await runInSandbox(code);

    console.log('sandbox console output :', logs);
    console.log('returned value         :', result);
  }

  console.log();

  // ── 2. Input/output round-trip ────────────────────────────────────────────
  console.log('=== Example 2: Input/output with $input ===');
  {
    const code = `
      const doubled = $input.numbers.map(n => n * 2);
      console.log('doubled:', JSON.stringify(doubled));
      return { doubled, sum: doubled.reduce((a, b) => a + b, 0) };
    `;

    const { result, logs } = await runInSandbox(code, { $input: { numbers: [1, 2, 3, 4, 5] } });

    console.log('sandbox console output :', logs);
    console.log('returned value         :', result);
  }

  console.log();

  // ── 3. Isolation proof — require is not available inside the sandbox ───────
  console.log('=== Example 3: Isolation (require is blocked) ===');
  {
    const code = `
      // This will throw because require is not in the sandbox context
      const fs = require('fs');
      return fs.readFileSync('/etc/passwd', 'utf8');
    `;

    try {
      await runInSandbox(code);
    } catch (err) {
      console.log('sandbox correctly blocked the escape attempt:');
      console.log(' ', err.message);
    }
  }
}

main().catch((err) => {
  console.error('Fatal:', err);
  process.exit(1);
});
