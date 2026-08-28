import net from "node:net";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const shimPath = process.argv[2];
if (!shimPath) throw new Error("usage: copilot-shim-process-survival.mjs SHIM_PATH");

async function listen(server) {
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  return server.address().port;
}

async function reservePort() {
  const server = net.createServer();
  const port = await listen(server);
  await new Promise((resolve) => server.close(resolve));
  return port;
}

function chunk(value) {
  return `${Buffer.byteLength(value).toString(16)}\r\n${value}\r\n`;
}

function responseSummary(response) {
  const headerEnd = response.indexOf("\r\n\r\n");
  const headers = response.slice(0, headerEnd);
  return {
    status: Number(response.match(/^HTTP\/1\.1 (\d{3})/i)?.[1] ?? 0),
    events: [...response.matchAll(/^event: ([^\r\n]+)/gm)].map((match) => match[1]),
    connection: headers.match(/^connection:\s*([^\r\n]+)/im)?.[1] ?? null,
    transferEncoding: headers.match(/^transfer-encoding:\s*([^\r\n]+)/im)?.[1] ?? null,
    contentLength: Number(headers.match(/^content-length:\s*(\d+)/im)?.[1] ?? 0),
    bodyBytes: headerEnd < 0 ? 0 : Buffer.byteLength(response.slice(headerEnd + 4)),
  };
}

function responseIsComplete(response) {
  const framing = responseSummary(response);
  if (framing.contentLength > 0) return framing.bodyBytes >= framing.contentLength;
  if (framing.transferEncoding?.toLowerCase().includes("chunked")) {
    return response.includes("\r\n0\r\n\r\n");
  }
  return false;
}

async function createUpstream({ delayMs = 0, truncate = false, complete = false, marker }) {
  const sockets = new Set();
  const server = net.createServer((socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    let request = Buffer.alloc(0);
    let answered = false;
    socket.on("data", (part) => {
      if (answered) return;
      request = Buffer.concat([request, part]);
      const headerEnd = request.indexOf("\r\n\r\n");
      if (headerEnd < 0) return;
      const headers = request.subarray(0, headerEnd).toString("latin1");
      const length = Number(headers.match(/\r\ncontent-length:\s*(\d+)/i)?.[1] ?? 0);
      if (request.length < headerEnd + 4 + length) return;
      answered = true;
      setTimeout(() => {
        if (socket.destroyed) return;
        socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n");
        socket.write(chunk(`event: response.output_text.delta\ndata: ${marker}\n\n`), () => {
          if (truncate) setTimeout(() => socket.resetAndDestroy(), 25);
          else if (complete) {
            socket.write("0\r\n\r\n", () => {
              answered = false;
              request = Buffer.alloc(0);
            });
          }
        });
      }, delayMs);
    });
  });
  const port = await listen(server);
  return {
    port,
    async close() {
      for (const socket of sockets) socket.destroy();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}

async function waitForHealth(port, child, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) return false;
    try {
      const response = await fetch(`http://127.0.0.1:${port}/_shim/health`);
      if (response.ok && (await response.json()).ok === true) return true;
    } catch {}
    await sleep(25);
  }
  return false;
}

async function resetAfterMarker(port, marker) {
  const body = JSON.stringify({ model: "fixture", stream: true, input: "fixture" });
  return await new Promise((resolve, reject) => {
    const socket = net.connect(port, "127.0.0.1");
    let response = "";
    let settled = false;
    const timeout = setTimeout(() => finish(new Error(`timed out waiting for ${marker}`)), 5000);
    const finish = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      if (!socket.destroyed) socket.destroy();
      if (error) reject(error);
      else resolve({ sawKeepalive: response.includes(": copilot-shim keepalive") });
    };
    socket.on("connect", () => {
      socket.write([
        "POST /v1/responses HTTP/1.1",
        `Host: 127.0.0.1:${port}`,
        "Content-Type: application/json",
        `Content-Length: ${Buffer.byteLength(body)}`,
        "Connection: keep-alive",
        "",
        body,
      ].join("\r\n"));
    });
    socket.on("data", (part) => {
      response += part.toString("utf8");
      if (!response.includes(marker)) return;
      const result = { sawKeepalive: response.includes(": copilot-shim keepalive") };
      settled = true;
      clearTimeout(timeout);
      socket.resetAndDestroy();
      resolve(result);
    });
    socket.on("error", (error) => {
      if (!settled) finish(error);
    });
    socket.on("close", () => {
      if (!settled) finish(new Error(`connection closed before ${marker}`));
    });
  });
}

async function resetAfterCompletion(port, marker) {
  const body = JSON.stringify({ model: "fixture", stream: true, input: "fixture" });
  return await new Promise((resolve) => {
    const socket = net.connect(port, "127.0.0.1");
    let response = "";
    let settled = false;
    const finish = (completed, error = null) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      if (!socket.destroyed) socket.destroy();
      resolve({
        completed,
        error: error ? String(error) : null,
        responseBytes: Buffer.byteLength(response),
        sawMarker: response.includes(marker),
        sawTerminator: response.includes("\r\n0\r\n\r\n"),
        ...responseSummary(response),
      });
    };
    const timeout = setTimeout(() => finish(false, "timeout"), 5000);
    socket.on("connect", () => {
      socket.write([
        "POST /v1/responses HTTP/1.1",
        `Host: 127.0.0.1:${port}`,
        "Content-Type: application/json",
        `Content-Length: ${Buffer.byteLength(body)}`,
        "Connection: keep-alive",
        "",
        body,
      ].join("\r\n"));
    });
    socket.on("data", (part) => {
      response += part.toString("utf8");
      if (!response.includes(marker) || !responseIsComplete(response)) return;
      settled = true;
      clearTimeout(timeout);
      setTimeout(() => {
        socket.resetAndDestroy();
        resolve({
          completed: true,
          error: null,
          responseBytes: Buffer.byteLength(response),
          sawMarker: true,
          sawTerminator: response.includes("\r\n0\r\n\r\n"),
          ...responseSummary(response),
        });
      }, 75);
    });
    socket.on("error", (error) => {
      if (!settled) finish(false, error);
    });
    socket.on("close", () => {
      if (!settled) finish(false, "connection closed before the response completed");
    });
  });
}

async function runScenario(name, options) {
  const root = mkdtempSync(join(tmpdir(), `copilot-shim-${name}-`));
  const marker = `fixture-${name}`;
  const upstream = await createUpstream({ ...options, marker });
  const shimPort = await reservePort();
  const child = Bun.spawn({
    cmd: [process.execPath, shimPath],
    env: {
      ...process.env,
      COPILOT_SHIM_PORT: String(shimPort),
      COPILOT_SHIM_UPSTREAM: `http://127.0.0.1:${upstream.port}`,
      COPILOT_SHIM_METRICS_DB: join(root, "metrics.sqlite"),
      COPILOT_API_SQLITE_DB_PATH: join(root, "tokens.sqlite"),
      COPILOT_SHIM_RETRIES: "0",
      COPILOT_SHIM_PING_AFTER_MS: "40",
      COPILOT_SHIM_PING_MS: "20",
      COPILOT_SHIM_STALL_MS: "2000",
    },
    stdout: "pipe",
    stderr: "pipe",
  });

  let observation = {};
  try {
    if (!(await waitForHealth(shimPort, child))) throw new Error("shim did not become healthy");
    if (options.truncate) {
      try {
        const response = await fetch(`http://127.0.0.1:${shimPort}/v1/responses`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ model: "fixture", stream: true, input: "fixture" }),
        });
        await response.text();
      } catch {}
    } else if (options.complete) {
      for (let index = 0; index < options.runs; index++) {
        observation = await resetAfterCompletion(shimPort, marker);
        observation.run = index + 1;
        if (child.exitCode !== null || !observation.completed) break;
      }
    } else {
      observation = await resetAfterMarker(shimPort, marker);
    }

    await sleep(300);
    const exited = await Promise.race([
      child.exited.then((code) => ({ exited: true, code })),
      sleep(300).then(() => ({ exited: false, code: null })),
    ]);
    const healthy = !exited.exited && await waitForHealth(shimPort, child, 1000);
    return { name, healthy, ...exited, ...observation };
  } finally {
    if (child.exitCode === null) child.kill();
    await child.exited;
    await upstream.close();
    rmSync(root, { recursive: true, force: true });
  }
}

const results = [];
results.push(await runScenario("upstream-truncate", { truncate: true }));
results.push(await runScenario("downstream-fast-abort", { delayMs: 0 }));
results.push(await runScenario("downstream-slow-abort", { delayMs: 120 }));
results.push(await runScenario("downstream-post-complete-close", { complete: true, runs: 250 }));
console.log(JSON.stringify({ bun: Bun.version, results }));

if (!results.every((result) => result.healthy && result.completed !== false)) process.exitCode = 1;
if (!results.find((result) => result.name === "downstream-slow-abort")?.sawKeepalive) {
  throw new Error("slow abort scenario did not traverse the early keepalive path");
}