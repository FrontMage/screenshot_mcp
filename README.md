# Screenshot MCP (macOS)

Minimal MCP server for macOS screenshots with a Swift CLI backend. Supports:
- display screenshots
- window screenshots
- listing displays/windows

## Requirements
- macOS 12+ (CoreGraphics APIs)
- Swift (Xcode CLI tools)
- Node.js 18+
- Screen Recording permission granted to the terminal or host app

## Quickstart
```bash
npm install
swift build
node server.js
```

## MCP Tools
- `list_displays`
- `list_windows`
- `screenshot_display` `{ display_id, output_path? }`
- `screenshot_window` `{ window_id, output_path? }`

## CLI Usage
```bash
swift run screenshot_mcp list-displays
swift run screenshot_mcp list-windows
swift run screenshot_mcp screenshot-display <display_id> ./captures/display.png
swift run screenshot_mcp screenshot-window <window_id> ./captures/window.png
```

## Configuration
- `SCREENSHOT_MCP_BIN`: path to the compiled Swift binary
- `SCREENSHOT_MCP_OUTPUT_DIR`: default output directory for screenshots

## Notes
- The Swift CLI uses `CGDisplayCreateImage` and `CGWindowListCreateImage`.
- If screenshots are blank, ensure Screen Recording permission is granted.
