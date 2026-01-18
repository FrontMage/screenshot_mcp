import { execFile } from "node:child_process";
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
    default:
      throw new Error(`Unknown tool: ${name}`);
  }
});

async function runCli(args) {
  const { stdout } = await execFileAsync(BIN_PATH, args);
  return stdout;
}

function defaultOutputPath(prefix) {
  const timestamp = new Date()
    .toISOString()
    .replace(/[:.]/g, "-")
    .replace("T", "_")
    .replace("Z", "");
  return path.join(OUTPUT_DIR, `${prefix}_${timestamp}.png`);
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

const transport = new StdioServerTransport();
await server.connect(transport);
