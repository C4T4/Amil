# Amil

Amil is a small macOS terminal for working with coding agents. It is not an editor. One window holds workspaces, tabs, and panes. Each pane is a real PTY.

The on-disk name is still `ATerminal` so existing sessions keep working. The app you see is Amil.

The pictures below are examples. The project, path, and transcript are made up.

![A session in a sample workspace](docs/screenshots/session.png)

![Settings, with Yolo off](docs/screenshots/settings.png)

![A workflow with its own steps](docs/screenshots/queue.png)

## Build

macOS 13 or newer. [Zig 0.16.0](https://ziglang.org/download/).

```sh
git clone --recurse-submodules https://github.com/C4T4/Amil.git
cd Amil
zig build
open zig-out/ATerminal.app
```

If `vendor/ghostty` is empty after clone:

```sh
git submodule update --init vendor/ghostty
```

`zig build` produces `zig-out/ATerminal.app`. The binary inside is `Contents/MacOS/aterminal`. Ghostty’s terminal library is a submodule (`vendor/ghostty`, MIT). Do not commit a Zig toolchain or `zig-out/`.

Optional extension dylibs:

```sh
zig build plugins
mkdir -p "$HOME/Library/Application Support/ATerminal/plugins"
cp zig-out/plugins/libat-pipeline.dylib zig-out/plugins/libat-mcp.dylib \
  "$HOME/Library/Application Support/ATerminal/plugins/"
```

Pipeline and MCP also install into `ATerminal.app/Contents/PlugIns` on a normal `zig build`.

## Data

State lives in `~/Library/Application Support/ATerminal/` (`state.json`, `control.json`, `queue/`, `workflows/`, `plugins/`, `pty/`). Yolo mode (skip Grok and Claude permission prompts) is off until you turn it on in Settings.

## Names

Claude, Grok, ChatGPT, and Gemini are the command-line tools Amil can launch. Those names and logos belong to their owners. The icons in `resources/agents/` are only there so a tab shows which tool is running.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before you open a pull request. CI on macOS runs `zig build` and `zig build test`. Report a security problem the way [SECURITY.md](SECURITY.md) describes, not in a public issue.

## License

MIT. See [LICENSE](LICENSE). Ghostty is MIT; see [vendor/ghostty/LICENSE](vendor/ghostty/LICENSE) after the submodule is checked out.
