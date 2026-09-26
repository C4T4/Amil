# Contributing to Amil

Amil is a macOS app. Changes are reviewed as pull requests against `main`. One pull request is one change.

## Setup

- macOS 13 or newer
- Zig 0.16.0
- Xcode command-line tools (`clang` is used for the AppKit side)

```sh
git clone --recurse-submodules <this-repo>
cd Amil
git submodule update --init vendor/ghostty
zig build
zig build test
open zig-out/ATerminal.app
```

`vendor/ghostty` is a submodule. A clone without `--recurse-submodules` will not build. Do not copy a Zig compiler, `zig-out/`, `zig-pkg/`, or `.aterminal-paste/` into a commit.

## What runs in CI

On every pull request, GitHub Actions on macOS runs:

```sh
zig build
zig build test
```

`zig build test` is the control-plane test (`src/control_test.zig`). It does not launch the app. If you change the window, tab strip, or terminal view, attach a screenshot to the pull request. The test run will not catch that.

## Where code lives

| Path | What it is |
| --- | --- |
| `src/macos/` | AppKit UI. Window, tabs, settings, the terminal view. |
| `src/store.zig` | Workspaces, tabs, and `state.json`. |
| `src/control.zig` and `src/control/` | In-process command bus. Settings and `atctl` talk to this. |
| `src/plugins/` | Optional dylibs (pipeline, MCP). Not linked into the default binary. |
| `include/` | C headers for the bus and the store. |
| `docs/control-plane.md` | Design notes for the bus. Read it before changing the protocol. |

The product name is Amil. The binary is still `aterminal`, the bundle id is `dev.aterminal.app`, and saved state is `~/Library/Application Support/ATerminal/`. Do not rename those in a drive-by change. Existing installs depend on them.

## What we will not merge

- Electron, Tauri, SwiftUI, or a web view for the terminal.
- A background daemon that runs when the app is quit. Agents that should survive a closed window already use the `at-pty` helper, and only when Background is on in Settings.
- Yolo mode turned on by default. The Settings switch stays off unless the user opts in.
- Replacing the agent icons with unrelated art. `resources/agents/` shows which CLI a tab is running.
- Secrets, signing keys, or screenshots from `.aterminal-paste/`.

## Pull requests

- Branch from `main`.
- Describe the behavior change, not the file list.
- Run `zig build` and `zig build test` before you ask for review.
- Keep the diff to the change. Do not reformat unrelated files.
- UI changes need a screenshot of the window after the change.

Signing with an Apple Development certificate is optional and local. CI does not sign the app. A linker-signed build is enough to review a change.
