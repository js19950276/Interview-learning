#!/usr/bin/env node
// genius-coder Claude host — bridges the Swift side to the pinned
// @anthropic-ai/claude-agent-sdk via a line-JSON stdio protocol (spec:
// Claude). Stdout carries ONLY protocol frames; SDK logs go to stderr and
// are truncated to 1 KiB by the Swift side.

import { createInterface } from "node:readline";
import { randomUUID } from "node:crypto";

// Frames: { v: 1, type: "req"|"res"|"event", id?, method?, body? }
const VERSION = 1;

let sdk = null;
let query = null;
let userMessagePush = null;
let sessionId = null;
let pendingFrames = [];
let nextId = 0;
const pendingRequests = new Map();

function send(frame) {
  process.stdout.write(JSON.stringify(frame) + "\n");
}

function sendEvent(method, body) {
  send({ v: VERSION, type: "event", method, body });
}

function fail(id, code, message) {
  send({ v: VERSION, type: "res", id, ok: false, error: { code, message } });
}

async function importSDK() {
  // The package must be pinned next to this script (see package.json).
  try {
    return await import("@anthropic-ai/claude-agent-sdk");
  } catch (error) {
    throw new Error("claude-agent-sdk not installed: " + error.message);
  }
}

async function openSession(body) {
  const { query: sdkQuery } = await importSDK();
  const claudeBinary = body.claudeBinary;
  if (!claudeBinary) throw new Error("claudeBinary required");
  const resumeId = body.sessionId && body.sessionId.length > 0 ? body.sessionId : null;

  // Long-lived streaming input: the user message source is an async
  // iterable we control (spec: session.open 建立长生命周期的 streaming input).
  const queue = [];
  let notify = null;
  function makeSource() {
    return {
      [Symbol.asyncIterator]() {
        return {
          async next() {
            if (queue.length > 0) return { value: queue.shift(), done: false };
            await new Promise((resolve) => { notify = resolve; });
            return { value: queue.shift(), done: false };
          },
          return() {
            return { done: true };
          },
        };
      },
    };
  }
  function push(message) {
    queue.push(message);
    if (notify) { const n = notify; notify = null; n(); }
  }
  userMessagePush = push;

  const options = {
    cwd: body.cwd,
    permissionMode: "default",
    settingSources: ["user", "project"],
    pathToClaudeCodeExecutable: claudeBinary,
    canUseTool: async (input) => {
      // Ask the phone; bridge denial is fail-closed with interrupt: true
      // (spec: 断线失败关闭). The request id routes the answer back.
      const requestId = "perm_" + (++nextId);
      sendEvent("session.permission", {
        sessionId: sessionId ?? resumeId ?? "",
        requestId,
        toolName: input.tool_name ?? "tool",
        inputPreview: JSON.stringify(input.input ?? {}).slice(0, 400),
        truncated: false,
      });
      const answer = await waitForPermission(requestId);
      if (answer && answer.behavior === "allow") {
        return {
          behavior: "allow",
          updatedInput: input.input,
        };
      }
      return {
        behavior: "deny",
        message: "Denied from the phone",
        interrupt: answer && answer.interrupt === true,
      };
    },
  };
  if (resumeId) options.resume = resumeId;

  sdkQuery = sdkQuery;
  query = sdkQuery({ prompt: makeSource(), options });
  (async () => {
    try {
      for await (const message of query) {
        emitMessage(message);
      }
      sendEvent("session.event", { sessionId: sessionId ?? "", body: { kind: "turn_completed", stopReason: "end_turn" } });
    } catch (error) {
      sendEvent("session.event", { sessionId: sessionId ?? "", body: { kind: "error", message: String(error.message || error).slice(0, 400) } });
    }
  })();
  return { sessionId: resumeId ?? "(pending)" };
}

function emitMessage(message) {
  const sid = sessionId ?? "";
  switch (message.type) {
    case "system":
      if (message.subtype === "init" && message.session_id) {
        sessionId = message.session_id;
        sendEvent("session.ready", { sessionId });
      }
      break;
    case "assistant":
      for (const block of message.message?.content ?? []) {
        if (block.type === "text") {
          sendEvent("session.event", { sessionId: sid, body: { kind: "assistant_text_delta", text: block.text } });
        } else if (block.type === "thinking") {
          sendEvent("session.event", { sessionId: sid, body: { kind: "thinking_delta", text: block.thinking } });
        } else if (block.type === "tool_use") {
          sendEvent("session.event", {
            sessionId: sid,
            body: {
              kind: "tool_call",
              toolName: block.name,
              toolUseId: block.id,
              preview: JSON.stringify(block.input ?? {}).slice(0, 400),
            },
          });
        }
      }
      break;
    case "user":
      for (const block of message.message?.content ?? []) {
        if (block.type === "tool_result") {
          sendEvent("session.event", {
            sessionId: sid,
            body: {
              kind: "tool_result",
              toolUseId: block.tool_use_id ?? "",
              preview: String(block.content ?? "").slice(0, 400),
            },
          });
        }
      }
      break;
    case "result":
      sendEvent("session.event", {
        sessionId: sid,
        body: { kind: "turn_completed", stopReason: message.subtype ?? "end_turn" },
      });
      break;
    default:
      break;
  }
}

const permissionWaiters = new Map();
function waitForPermission(requestId) {
  return new Promise((resolve) => {
    permissionWaiters.set(requestId, resolve);
    // Default fail-closed timeout: 15 s monotonic-ish (setTimeout).
    setTimeout(() => {
      if (permissionWaiters.has(requestId)) {
        permissionWaiters.delete(requestId);
        resolve({ behavior: "deny", interrupt: true, message: "phone disconnected" });
      }
    }, 15000);
  });
}

async function handleFrame(frame) {
  if (frame.v !== VERSION) return;
  if (frame.type !== "req") return;
  const { id, method } = frame;
  try {
    switch (method) {
      case "session.open": {
        const result = await openSession(frame.body ?? {});
        send({ v: VERSION, type: "res", id, ok: true, body: result });
        break;
      }
      case "session.prompt": {
        if (!userMessagePush) throw new Error("session not open");
        userMessagePush({ type: "text", text: frame.body?.text ?? "" });
        send({ v: VERSION, type: "res", id, ok: true, body: {} });
        break;
      }
      case "session.interrupt": {
        if (query && typeof query.interrupt === "function") {
          query.interrupt();
        }
        send({ v: VERSION, type: "res", id, ok: true, body: {} });
        break;
      }
      case "session.permission": {
        const waiter = permissionWaiters.get(frame.body?.requestId);
        if (waiter) {
          permissionWaiters.delete(frame.body?.requestId);
          waiter(frame.body ?? {});
        }
        send({ v: VERSION, type: "res", id, ok: true, body: {} });
        break;
      }
      case "session.close": {
        if (userMessagePush) {
          // Ending the iterable lets the SDK finish; the process exits.
          userMessagePush = null;
        }
        send({ v: VERSION, type: "res", id, ok: true, body: {} });
        setTimeout(() => process.exit(0), 100);
        break;
      }
      default:
        fail(id, -32601, "unknown method " + method);
    }
  } catch (error) {
    fail(id, -32000, String(error.message || error).slice(0, 400));
  }
}

const readline = createInterface({ input: process.stdin });
readline.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  try {
    const frame = JSON.parse(trimmed);
    handleFrame(frame);
  } catch (error) {
    process.stderr.write("bad frame: " + String(error.message || error).slice(0, 200) + "\n");
  }
});
readline.on("close", () => {
  process.exit(0);
});
