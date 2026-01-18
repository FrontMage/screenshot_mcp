# Screenshot MCP (macOS)

Minimal MCP server for macOS screenshots with a Swift CLI backend. Supports:
- display screenshots
- window screenshots
- window recording (duration or start/stop)
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
- `record_window_duration` `{ window_id, duration_seconds, fps?, output_path? }`
- `record_window_start` `{ window_id, fps?, output_path? }`
- `record_window_stop` `{ recording_id }`

## CLI Usage
```bash
swift run screenshot_mcp list-displays
swift run screenshot_mcp list-windows
swift run screenshot_mcp screenshot-display <display_id> ./captures/display.png
swift run screenshot_mcp screenshot-window <window_id> ./captures/window.png
swift run screenshot_mcp record-window-duration <window_id> ./captures/window.mp4 5 10
swift run screenshot_mcp record-window-start <window_id> ./captures/window.mp4 10
# stop with Ctrl+C or SIGINT
```

## Configuration
- `SCREENSHOT_MCP_BIN`: path to the compiled Swift binary
- `SCREENSHOT_MCP_OUTPUT_DIR`: default output directory for screenshots

## Notes
- The Swift CLI uses `CGDisplayCreateImage` and `CGWindowListCreateImage`.
- Window recording samples window frames (default 10 fps) and writes MP4 via `AVAssetWriter`.
- If screenshots are blank, ensure Screen Recording permission is granted.
