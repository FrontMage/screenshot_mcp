import { execFile, spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const BIN_PATH =
  process.env.SCREENSHOT_MCP_BIN ||
  path.join(__dirname, ".build", "debug", "screenshot_mcp");

const OUTPUT_DIR =
  process.env.SCREENSHOT_MCP_OUTPUT_DIR || path.join(__dirname, "captures");

const server = new Server(
  { name: "screenshot-mcp", version: "0.1.0" },
  { capabilities: { tools: {} } }
);

const activeRecordings = new Map();

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "list_displays",
      description: "List available displays with bounds and pixel sizes.",
      inputSchema: { type: "object", properties: {}, additionalProperties: false },
    },
    {
      name: "list_windows",
      description: "List on-screen windows with bounds and owner metadata.",
      inputSchema: { type: "object", properties: {}, additionalProperties: false },
    },
    {
      name: "screenshot_display",
      description: "Capture a PNG/JPG of a display by display_id.",
      inputSchema: {
        type: "object",
        properties: {
          display_id: { type: "integer" },
          output_path: { type: "string" },
        },
        required: ["display_id"],
        additionalProperties: false,
      },
    },
    {
      name: "screenshot_window",
      description: "Capture a PNG/JPG of a window by window_id.",
      inputSchema: {
        type: "object",
        properties: {
          window_id: { type: "integer" },
          output_path: { type: "string" },
        },
        required: ["window_id"],
        additionalProperties: false,
      },
    },
    {
      name: "record_window_duration",
      description: "Record a window for a fixed duration (seconds) to an MP4.",
      inputSchema: {
        type: "object",
        properties: {
          window_id: { type: "integer" },
          duration_seconds: { type: "number" },
          output_path: { type: "string" },
        },
        required: ["window_id", "duration_seconds"],
        additionalProperties: false,
      },
    },
    {
      name: "record_window_start",
      description:
        "Start recording a window until record_window_stop is called.",
      inputSchema: {
        type: "object",
        properties: {
          window_id: { type: "integer" },
          output_path: { type: "string" },
        },
        required: ["window_id"],
        additionalProperties: false,
      },
    },
    {
      name: "record_window_stop",
      description: "Stop a recording started with record_window_start.",
      inputSchema: {
        type: "object",
        properties: {
          recording_id: { type: "string" },
        },
        required: ["recording_id"],
        additionalProperties: false,
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    case "list_displays": {
      const output = await runCli(["list-displays"]);
      return { content: [{ type: "text", text: output.trim() }] };
    }
    case "list_windows": {
      const output = await runCli(["list-windows"]);
      return { content: [{ type: "text", text: output.trim() }] };
    }
    case "screenshot_display": {
      const displayId = Number(args?.display_id);
      if (!Number.isInteger(displayId)) {
        throw new Error("display_id must be an integer.");
      }
      const outputPath =
        typeof args?.output_path === "string" && args.output_path.length > 0
          ? args.output_path
          : defaultOutputPath(`display_${displayId}`);
      await ensureOutputDir(outputPath);
      await runCli(["screenshot-display", String(displayId), outputPath]);
      return {
        content: [
          { type: "text", text: JSON.stringify({ output_path: outputPath }) },
        ],
      };
    }
    case "screenshot_window": {
      const windowId = Number(args?.window_id);
      if (!Number.isInteger(windowId)) {
        throw new Error("window_id must be an integer.");
      }
      const outputPath =
        typeof args?.output_path === "string" && args.output_path.length > 0
          ? args.output_path
          : defaultOutputPath(`window_${windowId}`);
      await ensureOutputDir(outputPath);
      await runCli(["screenshot-window", String(windowId), outputPath]);
      return {
        content: [
          { type: "text", text: JSON.stringify({ output_path: outputPath }) },
        ],
      };
    }
    case "record_window_duration": {
      const windowId = Number(args?.window_id);
      if (!Number.isInteger(windowId)) {
        throw new Error("window_id must be an integer.");
      }
      const durationSeconds = Number(args?.duration_seconds);
      if (!Number.isFinite(durationSeconds) || durationSeconds <= 0) {
        throw new Error("duration_seconds must be a positive number.");
      }
      const outputPath =
        typeof args?.output_path === "string" && args.output_path.length > 0
          ? args.output_path
          : defaultOutputPath(`window_${windowId}`, "mp4");
      await ensureOutputDir(outputPath);
      await runCli([
        "record-window-duration",
        String(windowId),
        outputPath,
        String(durationSeconds),
      ]);
      return {
        content: [
          { type: "text", text: JSON.stringify({ output_path: outputPath }) },
        ],
      };
    }
    case "record_window_start": {
      const windowId = Number(args?.window_id);
      if (!Number.isInteger(windowId)) {
        throw new Error("window_id must be an integer.");
      }
      const outputPath =
        typeof args?.output_path === "string" && args.output_path.length > 0
          ? args.output_path
          : defaultOutputPath(`window_${windowId}`, "mp4");
      await ensureOutputDir(outputPath);
      const recordingId = createRecordingId();
      const child = spawn(
        BIN_PATH,
        ["record-window-start", String(windowId), outputPath],
        { stdio: "ignore" }
      );
      activeRecordings.set(recordingId, { child, outputPath });
      child.once("exit", () => {
        activeRecordings.delete(recordingId);
      });
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({
              recording_id: recordingId,
              output_path: outputPath,
            }),
          },
        ],
      };
    }
    case "record_window_stop": {
      const recordingId = String(args?.recording_id || "");
      if (!recordingId) {
        throw new Error("recording_id is required.");
      }
      const recording = activeRecordings.get(recordingId);
      if (!recording) {
        throw new Error(`Recording not found: ${recordingId}`);
      }
      await stopRecording(recording.child);
      activeRecordings.delete(recordingId);
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({
              recording_id: recordingId,
              output_path: recording.outputPath,
            }),
          },
        ],
      };
    }
    default:
      throw new Error(`Unknown tool: ${name}`);
  }
});

async function runCli(args) {
  const { stdout } = await execFileAsync(BIN_PATH, args);
  return stdout;
}

function defaultOutputPath(prefix, extension = "png") {
  const timestamp = new Date()
    .toISOString()
    .replace(/[:.]/g, "-")
    .replace("T", "_")
    .replace("Z", "");
  return path.join(OUTPUT_DIR, `${prefix}_${timestamp}.${extension}`);
}

async function ensureOutputDir(outputPath) {
  const dir = path.dirname(outputPath);
  await fs.mkdir(dir, { recursive: true });
}

function execFileAsync(command, args) {
  return new Promise((resolve, reject) => {
    execFile(command, args, { encoding: "utf8" }, (error, stdout, stderr) => {
      if (error) {
        const message =
          stderr && stderr.trim().length > 0 ? stderr.trim() : error.message;
        return reject(new Error(message));
      }
      resolve({ stdout, stderr });
    });
  });
}

function createRecordingId() {
  return `rec_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
}

function stopRecording(child) {
  return new Promise((resolve) => {
    if (child.exitCode !== null || child.killed) {
      resolve();
      return;
    }

    const timeout = setTimeout(() => {
      child.kill("SIGKILL");
    }, 5000);

    child.once("exit", () => {
      clearTimeout(timeout);
      resolve();
    });

    child.kill("SIGINT");
  });
}

const transport = new StdioServerTransport();
await server.connect(transport);
