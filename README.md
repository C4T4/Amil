# Amil

Amil is a small macOS terminal for working with coding agents. It is not an editor. One window holds workspaces, tabs, and panes. Each pane is a real PTY.

The on-disk name is still `ATerminal` so existing sessions keep working. The app you see is Amil.

## Build

macOS 13 or newer. [Zig 0.16.0](https://ziglang.org/download/).

```sh
git clone --recurse-submodules <this-repo>
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

Claude, Grok, ChatGPT, and Gemini are the command-line tools Amil can launch. Those names belong to their owners. The marks in `resources/agents/` are original stand-ins, not their logos.

## License

MIT. See [LICENSE](LICENSE). Ghostty is MIT; see [vendor/ghostty/LICENSE](vendor/ghostty/LICENSE) after the submodule is checked out.
