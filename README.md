# Neovlet

Open files from Finder in one Neovim session, hosted in Ghostty.

Neovlet is a native macOS background app. It creates an editing session on the first
open, sends later files to that session, and reconnects to it after the manager
restarts. It manages only the session it created; manually started editors stay outside its control.

## Using Neovlet

Install Ghostty and Neovim before running Neovlet. On first use, the app discovers
common installation locations and asks you to choose a path if discovery is ambiguous
or validation fails. macOS also asks for permission to control Ghostty through Automation.
The permission prompt has its own wait, separate from the editor startup deadline.

The first file opens in a dedicated tab in the frontmost Ghostty window. If Ghostty
has no window, Neovlet creates one. Later files open in the same editor. Opening the
app without files focuses that session, or starts an empty editor if none exists.

Neovlet accepts readable local regular files, including symbolic links to regular
files and paths containing special characters. Directories, app bundles, remote URLs,
and unreadable or missing files are rejected. If any item in a batch is invalid,
the whole batch is rejected before anything is opened.

Multiple files use Neovim's native `:drop` behavior. Your Neovim configuration controls
layout and unsaved changes. A new session starts in the first file's parent directory;
an empty session starts in your home directory. Later opens preserve the editor's current directory.

The menu bar provides Settings, Session Recovery, and Quit Manager:

- **Settings** pauses requests that have not started. Save to resume them in order;
  close without saving to cancel them. An operation already authorizing, creating,
  or delivering continues. Error reports also hold later requests until acknowledged.
- **Session Recovery** verifies the registered editor and terminal. Uncertain state
  stays available for inspection. Recheck follows activation without files; it may
  create an empty editor once the old session is confirmed finished.
- **Quit Manager** leaves the editor and registration intact for the next launch.
  During an active operation, the app asks you to retry later.

When Neovim exits, Neovlet verifies and closes its finished terminal, then quits if
no work remains. If closing the last ordinary Ghostty window could also end Quick
Terminal, it keeps the finished pane and registration for explicit recovery instead.

## Startup and recovery guarantees

Initial files are passed directly in Neovim's startup argv, preserving startup
commands, `argc()`, and native swap recovery choices. Before executing Neovim,
Neovlet waits for Ghostty's creation reply, verifies the terminal TTY, and requires
100 milliseconds without a size change. This is a bounded layout wait, not a
platform guarantee that layout is complete.

After that wait, a login shell initializes the tool environment, restores the
requested working directory, and executes the editor command. Put paths for Homebrew
and other tools in your shell's login configuration; the GUI process's initial
`PATH` may be minimal. A timeout or cancellation before release starts neither the
login environment nor the editor.

Recovery uses a saved registration to verify the original processes and terminal.
If identity, delivery, or a registration write is uncertain, the app retains the
evidence and stops dependent work. It does not automatically create a replacement
editor or replay files whose receipt was not confirmed. Inspect the editor and
explicitly reopen files when needed. See the [design](docs/native-swift-design.md)
for the persistence and cleanup rules.

## Build a candidate

Development requires a Swift 6 toolchain and Ghostty's scripting dictionary.
End users need Ghostty and Neovim, but no development tools.

```sh
bash scripts/build.sh
# Select Ghostty's dictionary from another installation:
bash scripts/build.sh --ghostty '/path/to/Ghostty.app'
# Keep one candidate identity when testing recovery across rebuilds:
bash scripts/build.sh --candidate-id local.finder-neovim.candidate.manual
```

The build prints the path to a fresh `Neovlet.app` in the system temporary directory.
It verifies the native entry point, compiled AppleScript resource, Hardened Runtime,
and strict signature. The self-check calls only a local version handler; it sends
no events to Ghostty. Building does not install or launch the app or set file associations.

By default, each candidate has a fresh bundle identifier and isolated settings,
registration, lock, and endpoint namespace. Runtime dependency choices live in
`settings.json`, and the owned session is recorded in `session.json`, both outside
the signed bundle in the app's Application Support namespace.

The initial build targets Apple Silicon `arm64` with a macOS 15 deployment target.
The deployment target alone does not establish desktop compatibility with macOS 15.
Intel support and other platform combinations require their own validation.

## Verify changes

```sh
swift test
xcrun swift-format lint --strict --recursive Sources tests scripts/build.swift Package.swift
bash -n scripts/build.sh
bash -n scripts/release.sh
```

Tests cover the session interface, request ordering, settings, registration failures,
process identity, subprocess handling, and launch coordination with real pseudoterminals.
They use isolated storage and test adapters without contacting daily Ghostty or
Neovim sessions. The [design document](docs/native-swift-design.md#verification-strategy)
explains the important scenarios and fault-injection boundaries.

Real desktop acceptance uses isolated candidates and designated test terminals.
The [validation baseline](docs/native-swift-acceptance.md) defines the functional
matrix and outstanding release gates. Ghostty pixel appearance, minimum-system
compatibility, and production distribution require separate acceptance.

## Application identity and state

The package, target, executable, and bundle use `Neovlet`. Persistent identity uses
`local.finder-neovim` for production and `local.finder-neovim.candidate.*` for candidates.
These identifiers select settings, registration, locks, and endpoint namespaces and
must stay stable independently of the display name.

Production state lives in `Application Support/local.finder-neovim/`, with
`settings.json` and `session.json` both using version 1. Compatible existing state
requires no migration. Rebuilding with the same `--candidate-id` reuses that
candidate's state, including its saved dependency snapshot.

## Prepare a release

Public distribution uses GitHub Releases, Developer ID Application signing,
Hardened Runtime, and Apple notarization. Complete the distribution checks in the
[design document](docs/native-swift-design.md#distribution-acceptance) before publishing.

```sh
bash scripts/release.sh --help
# Requires a clean Git working tree with HEAD tagged v0.1.0,
# a Developer ID identity, and a notarytool profile in the local Keychain:
bash scripts/release.sh 0.1.0 1 'Developer ID Application: Your Name (TEAMID)' your-notary-profile
```

The script tests and builds the app, signs and notarizes it, staples the ticket,
and produces `Neovlet-<version>-macos-arm64.zip` and `SHA256SUMS`. It stores no
credentials and stops if production signing or notarization fails.

Validate installation from the final ZIP, attach those same artifacts to a GitHub
Release draft, and publish separately. The script does not upload or publish.
A successful local candidate build does not establish Developer ID, notarization,
or offline Gatekeeper acceptance. Updates initially use manual downloads; replacing
the app preserves user settings and session registration.

[Architecture and behavior](docs/native-swift-design.md) ·
[Acceptance evidence](docs/native-swift-acceptance.md) ·
[Terminology](GLOSSARY.md)
