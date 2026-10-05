// Codenotch OpenCode interaction plugin.
//
// This plugin only carries actionable permission/question requests. Session
// activity itself is read from opencode.db by Codenotch, which keeps this
// transport small and avoids duplicating unrelated OpenCode lifecycle events.

import { createConnection } from "node:net";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const SOCKET_PATH = `/tmp/codenotch-${typeof process.getuid === "function" ? process.getuid() : 0}.sock`;
const TIMEOUT_MS = 300000;

function askCodenotch(request) {
  return new Promise((resolve) => {
    let settled = false;
    let buffer = "";

    const finish = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      resolve(value);
    };

    const socket = createConnection(SOCKET_PATH);
    const timer = setTimeout(() => finish(null), TIMEOUT_MS);

    socket.setEncoding("utf8");
    socket.on("connect", () => {
      // Deliberately do not call socket.end(). Codenotch uses a newline-framed
      // request so Node can keep the connection open for the response without
      // half-closing the socket on macOS.
      socket.write(JSON.stringify({ version: 1, ...request }) + "\n");
    });
    socket.on("data", (chunk) => {
      buffer += chunk;
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      try {
        finish(JSON.parse(buffer.slice(0, newline)));
      } catch {
        finish(null);
      }
    });
    socket.on("error", () => finish(null));
    socket.on("close", () => {
      if (!settled) finish(null);
    });
  });
}

function prettyToolName(name) {
  const raw = String(name || "Tool");
  return raw.charAt(0).toUpperCase() + raw.slice(1);
}

function permissionFields(action, resources, metadata, message) {
  const patterns = Array.isArray(resources) ? resources.map(String) : [];
  const normalized = String(action || "").toLowerCase();
  return {
    toolName: prettyToolName(action),
    patterns,
    command: (normalized === "bash" || normalized === "shell") && patterns.length
      ? patterns.join(" && ")
      : undefined,
    filePath: (normalized === "edit" || normalized === "write") && patterns.length
      ? patterns[0]
      : undefined,
    description: typeof message === "string"
      ? message
      : (typeof metadata?.description === "string" ? metadata.description : undefined),
  };
}

function mapQuestions(questions) {
  return (questions || []).map((question) => ({
    question: question?.question || question?.description || question?.title || "",
    header: question?.header || question?.title || undefined,
    options: (question?.options || []).map((option) => ({
      label: String(option?.label ?? option?.value ?? ""),
      description: option?.description,
    })),
    multiSelect: Boolean(question?.multiple || question?.multiSelect || question?.type === "multiselect"),
  }));
}

function v2QuestionsFromForm(form) {
  if (!form || form.metadata?.kind !== "question" || !Array.isArray(form.fields)) return null;
  const questions = mapQuestions(form.fields);
  return questions.length ? questions : null;
}

function v2FormAnswer(form, answers) {
  const result = {};
  (form?.fields || []).forEach((field, index) => {
    const picked = answers?.[index] || [];
    if (!picked.length) return;
    result[field.key] = field.type === "multiselect" ? picked : picked.join(", ");
  });
  return result;
}

function v2ServiceEndpoint() {
  try {
    const stateHome = process.env.XDG_STATE_HOME || join(homedir(), ".local", "state");
    const info = JSON.parse(readFileSync(join(stateHome, "opencode", "service.json"), "utf8"));
    if (info?.pid !== process.pid || typeof info.url !== "string") return null;
    return { url: info.url, password: info.password };
  } catch {
    return null;
  }
}

async function v2FormRequest(method, path, body) {
  const endpoint = v2ServiceEndpoint();
  if (!endpoint) return false;

  const headers = { "Content-Type": "application/json" };
  if (endpoint.password) {
    headers.Authorization = "Basic " + Buffer.from(`opencode:${endpoint.password}`).toString("base64");
  }

  try {
    const response = await fetch(new URL(path, endpoint.url), {
      method,
      headers,
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    return response.ok;
  } catch {
    return false;
  }
}

function claimV2Event(eventID) {
  if (!eventID) return true;
  const key = Symbol.for("codenotch.opencode.v2.claimed");
  const claimed = globalThis[key] || (globalThis[key] = new Map());
  if (claimed.has(eventID)) return false;
  claimed.set(eventID, true);
  if (claimed.size > 2000) claimed.delete(claimed.keys().next().value);
  return true;
}

async function handleV2Event(event, ctx) {
  if (!claimV2Event(event?.id)) return;

  const type = event?.type;
  const data = event?.data || {};

  if (type === "permission.asked") {
    const sessionID = data.sessionID;
    const requestID = data.id;
    if (!sessionID || !requestID) return;

    const response = await askCodenotch({
      kind: "permission",
      sessionID,
      requestID,
      cwd: data.cwd || data.directory,
      ...permissionFields(data.action, data.resources, data.metadata, data.message),
    });
    if (!response?.decision) return;

    const decision = ["once", "always", "reject"].includes(response.decision)
      ? response.decision
      : "reject";
    await ctx.permission.reply({
      sessionID,
      requestID,
      decision,
    }).catch(() => {});
    return;
  }

  if (type === "form.created") {
    const form = data.form;
    const questions = v2QuestionsFromForm(form);
    if (!questions || !form?.id || !form?.sessionID) return;

    const response = await askCodenotch({
      kind: "question",
      sessionID: form.sessionID,
      requestID: form.id,
      cwd: data.cwd || data.directory,
      questions,
    });
    if (!response?.decision) return;

    if (response.decision === "reject") {
      await v2FormRequest(
        "DELETE",
        `/api/session/${encodeURIComponent(form.sessionID)}/form/${encodeURIComponent(form.id)}`
      );
      return;
    }

    if (response.decision === "answer" && Array.isArray(response.answers)) {
      await v2FormRequest(
        "POST",
        `/api/session/${encodeURIComponent(form.sessionID)}/form/${encodeURIComponent(form.id)}/reply`,
        { answer: v2FormAnswer(form, response.answers) }
      );
    }
  }
}

function setupV2(ctx) {
  const controller = new AbortController();

  (async () => {
    try {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
        handleV2Event(event, ctx).catch(() => {});
      }
    } catch {}
  })();

  return () => controller.abort();
}

async function v1Request(heyApi, serverPort, method, path, body) {
  try {
    if (typeof heyApi?.request === "function") {
      await heyApi.request({ method, url: path, body });
      return true;
    }
  } catch {}

  try {
    const response = await fetch(`http://localhost:${serverPort}${path}`, {
      method,
      headers: { "Content-Type": "application/json" },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    return response.ok;
  } catch {
    return false;
  }
}

async function handleV1Event(event, heyApi, serverPort) {
  const type = event?.type;
  const properties = event?.properties || {};
  const sessionID = properties.sessionID;
  const requestID = properties.id;

  if ((type === "permission.asked" || type === "permission.v2.asked")
      && sessionID && requestID) {
    const action = properties.permission || properties.action;
    const resources = properties.patterns || properties.resources;
    const response = await askCodenotch({
      kind: "permission",
      sessionID,
      requestID,
      cwd: properties.cwd || properties.directory,
      ...permissionFields(action, resources, properties.metadata, properties.message),
    });
    if (!response?.decision) return;

    const reply = ["once", "always", "reject"].includes(response.decision)
      ? response.decision
      : "reject";
    await v1Request(
      heyApi,
      serverPort,
      "POST",
      `/permission/${encodeURIComponent(requestID)}/reply`,
      { reply }
    );
    return;
  }

  if ((type === "question.asked" || type === "question.v2.asked")
      && sessionID && requestID) {
    const questions = mapQuestions(properties.questions);
    if (!questions.length) return;

    const response = await askCodenotch({
      kind: "question",
      sessionID,
      requestID,
      cwd: properties.cwd || properties.directory,
      questions,
    });
    if (!response?.decision) return;

    if (response.decision === "reject") {
      await v1Request(
        heyApi,
        serverPort,
        "POST",
        `/question/${encodeURIComponent(requestID)}/reject`
      );
      return;
    }

    if (response.decision === "answer" && Array.isArray(response.answers)) {
      await v1Request(
        heyApi,
        serverPort,
        "POST",
        `/question/${encodeURIComponent(requestID)}/reply`,
        { answers: response.answers }
      );
    }
  }
}

export default {
  id: "codenotch",
  setup: setupV2,
  server: async ({ client, serverUrl }) => {
    const serverPort = serverUrl ? parseInt(serverUrl.port) || 4096 : 4096;
    const heyApi = client?._client;

    return {
      event: async ({ event }) => {
        handleV1Event(event, heyApi, serverPort).catch(() => {});
      },
    };
  },
};
