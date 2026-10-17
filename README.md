# Coffee

A tiny macOS menu bar app that keeps your Mac awake while you work.

Left-click the cup to toggle. Right-click for the menu. Option-Command-K does the same as a left-click.

## What it does

- **Hold Mac awake** — prevents idle sleep (the display may still turn off)
- **When an agent is working** — stays awake while coding agents are running (Cursor, ChatGPT/Codex, Claude Code, Windsurf/Devin, and common CLIs such as `claude`, `codex`, `gemini`, `aider`)
- **Power adapter only** — on by default; also stops below 20% battery
- **Open at login**

It does **not** keep a MacBook awake with the lid closed and no external display. That is a macOS limit.

Requires macOS 14 or later. Works on Apple Silicon and Intel (build a universal binary if you need both).

## Build

You need Xcode (for `swiftc`, `sips`, `iconutil`, and Icon Composer’s `ictool`).

```bash
./build.sh
```

That writes `Coffee.app` in this folder. Drag it to `/Applications` and open it. Gatekeeper may ask you to right-click → Open the first time.

## Privacy

No accounts, no network, no analytics. Settings stay in the standard macOS defaults for `local.coffee`.

## License

MIT
