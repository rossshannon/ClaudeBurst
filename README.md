# ClaudeBurst

A macOS menubar app that notifies you when your Claude Code session allowance refreshes.

## Features

- Menubar-only app (doesn't appear in Dock by default)
- Shows current session and next session time in the menu
- Plays a sound effect when the Claude Code allowance window rolls over
- Shows a local notification: "A new Claude Code session has begun!" with time range subtitle
- Settings window to choose notification sound from dropdown
- Preview button to test selected sound
- Option to show/hide from Dock (instant toggle)

## Building

### Using Xcode

1. Open `ClaudeBurst.xcodeproj` in Xcode
2. Select "ClaudeBurst" scheme
3. Build (Cmd+B) or Run (Cmd+R)
4. The built app will be in `~/Library/Developer/Xcode/DerivedData/ClaudeBurst-*/Build/Products/Release/ClaudeBurst.app`

### Using Command Line

```bash
cd ClaudeBurst
xcodebuild -project ClaudeBurst.xcodeproj -scheme ClaudeBurst -configuration Release build
```

## Installation

1. Build the app
2. Copy `ClaudeBurst.app` to `/Applications`
3. Launch the app - it will appear in your menubar with the ClaudeBurst icon
4. Grant notification permissions when prompted

## Usage

- Click the menubar icon to see:
  - **Current session** - e.g., "Current: 5pm–10pm"
  - **Next session** - e.g., "Next session at 10pm"
  - **Settings...** - Configure notification sound and dock visibility
  - **Test Notification** - Preview the notification and sound
  - **Quit** - Exit the app

## Adding Custom Sounds

This app combines two sources at runtime:

1) **Baked-in sounds (build time)** — place `.mp3`, `.wav`, `.m4a`, or `.mp4` files in `./sounds` (repo root) before building. The folder is bundled as `sounds` inside the app.
2) **User sounds (runtime)** — add files to `~/Library/Application Support/ClaudeBurst/Sounds`. These are merged with the baked-in sounds; if names clash, the runtime file wins.

Notes:
- Invalid files in Application Support are ignored (e.g., empty files or unsupported audio).
- Use the "Open Sounds Folder" button in Settings to jump to the runtime folder.
- The app watches the Application Support folder and refreshes the Settings list automatically.
- Sounds in `./sounds` are bundled at build time; move files there and rebuild to update the baked-in list.

## Updating Icons

Run the icon regeneration script after replacing `icons/claudeburst-appicon.png`:

```bash
cd ClaudeBurst
./scripts/generate-icons.sh
```

The script reads `./icons/claudeburst-appicon.png` relative to the project root.

## Session Timing Source

ClaudeBurst reads Claude Code's JSONL log files from:

```
~/.claude/projects/**/*.jsonl
```

It parses timestamps from these files to calculate 5-hour session windows. The session calculation logic is adapted from [Claude-Code-Usage-Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor) (MIT licensed).

### How Session Windows Work

- **Window duration**: 5 hours (matching Claude Code's rolling limit)
- **Window start**: Rounded to the nearest hour in UTC (e.g., 10:35 → 11:00, 10:25 → 10:00)
- **New window triggers**: When the previous window expires, or after a 5+ hour gap in activity
- **Lookback period**: 8 days of logs are scanned for recent activity

The app watches the projects directory for changes and updates the display when new activity is logged.

## Security Note

The app runs without App Sandbox because it needs to read Claude Code's log files at `~/.claude/projects/`, which is outside the sandbox container.

## License

MIT License
