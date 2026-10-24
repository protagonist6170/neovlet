# Validation and release readiness

This is the validation baseline for the current Neovlet implementation. It describes
what automated tests establish, what requires a real desktop, and what must pass
before public distribution. Build and run instructions are in the [README](../README.md);
behavioral contracts are in the [architecture document](native-swift-design.md).

## Current scope

The app manifest identifies Neovlet as version `0.1.0`, build `1`. The build produces
an Apple Silicon `arm64` app; SwiftPM declares a macOS 15 deployment target. Neither
the target nor a successful local build establishes desktop support on macOS 15 or Intel.

The desktop evidence available for the implemented workflows comes from macOS 27.2
(26B118), Apple Silicon, Ghostty `48dde97e0` (build 18369), and Neovim 0.12.6.
It covers file delivery and lifecycle behavior in isolated sessions. It is not
production distribution acceptance or proof that every dependency combination works.

The current launch path requires 100 milliseconds of stable TTY dimensions and
initializes a login shell before executing Neovim. Automated pseudoterminal coverage
checks this path. A complete desktop pass of the current build, including pixel
appearance, remains a separate acceptance step.

## Automated coverage

The current source passed all 81 tests across seven suites on 2026-10-23, including
parameterized cases. Strict Swift formatting, syntax checks for both shell scripts,
and plist validation also passed. Documentation links, anchors, and source references
were checked as part of this baseline update.

Tests run against the production request interface with isolated storage, controlled
platform adapters, and real subprocesses or pseudoterminals where those boundaries
matter. They do not contact the user's daily Ghostty or Neovim sessions.

| Area | Required assertions |
| --- | --- |
| Request ordering | Requests arriving during creation share one editor and retain their order. Invalid batches have no creation or delivery effects. |
| Settings | Save resumes pending work; cancel discards it. Late resolution cannot revive canceled requests or show stale errors. Active operations keep their dependency snapshot. |
| Presentation and quit | Reports hold later requests until acknowledged. Reentrant callbacks do not nest notifications or bypass operation exclusion. Automatic quit rechecks current state. |
| Authorization | Human decision time is outside startup budgets. Denial creates no registration. Existing sessions receive no files until an explicit permitted retry. |
| Identity | Recovery uses recorded process instances and matching TTY devices, including separate server/TUI processes and login wrappers. Unknown liveness is never treated as exit. |
| Registration | Failed saves retain baseline and candidate evidence. Conflicts, missing disk state, and corrupt records cannot erase known live identities. |
| Cleanup | All retained identity clues are checked. A generation change invalidates old cleanup authority. Failed directory synchronization keeps state unresolved. |
| Startup | Neovim waits for the creation reply and stable nonzero TTY dimensions. Initial argv, cwd, and login environment survive launch. |
| Interrupted startup | An orphaned waiting branch exits and removes its handshake without executing the editor. Recovery does not replay old files or create a second surviving editor. |
| Subprocesses | Literal arguments survive quoting, large simultaneous output does not deadlock, and timed-out children are reaped. |
| State compatibility | Version 1 settings and registration restore the same editor, endpoint, generation, and dependency snapshot in an isolated namespace. |

Registration fault injection checks actual file contents around replacement,
file synchronization, unlink, and directory synchronization. Tests select semantic
stages rather than counting writes, including saves of identical `ready` snapshots.
They establish behavior at those boundaries, not resilience to every possible power failure.

The launch tests use real pseudoterminals and paths containing spaces, Chinese
characters, quotes, newlines, `$()`, semicolons, and brackets. Login initialization
must supply a tool through `PATH`; the test profile also changes directory, forcing
the launcher to restore the requested cwd. Timeout, cancellation, unstable dimensions,
and a mismatched TTY must execute neither the profile nor the editor.

Run the repository checks with:

```sh
swift test
xcrun swift-format lint --strict --recursive Sources tests scripts/build.swift Package.swift
bash -n scripts/build.sh
bash -n scripts/release.sh
```

For candidate assembly, `bash scripts/build.sh` additionally compiles the adapter,
checks the native entry and local version handler, signs with Hardened Runtime,
and verifies the signature strictly. The self-check sends no Ghostty events.

## Desktop acceptance

Use an isolated candidate identity and designated test files, swap files, and
terminals. State which Ghostty windows and sessions are in scope before operating
on them. Keep the installed app, daily configuration, and default file associations
outside the run unless explicitly authorized.

The following functional behaviors have desktop evidence. Repeat the relevant rows
when their implementation or dependencies change, and run the full matrix for a
release candidate.

| Scenario | Acceptance condition |
| --- | --- |
| Ghostty cold start | One owned terminal and editor appear. Initial files are in startup argv, and cwd is the first file's parent. No extra shell session is left behind. |
| Existing windows | Creation uses a new tab in the frontmost window. Other terminals retain their identity and state. |
| Manual Neovim already running | Neovlet creates its own session without adopting or ending the manual one. |
| Multiple files and special paths | All paths are received literally. Later requests use the same editor and registration generation. |
| Empty activation | Start in the home directory when no session exists; otherwise focus the existing session. |
| Unsaved changes and changed cwd | Later opens preserve both. Layout follows native `:drop` behavior. |
| Invalid mixed batch | No file in the batch is delivered, and the error identifies invalid items. |
| Settings | Real path selection, validation, save/reopen, redetection, cancellation, and standard editing/close shortcuts work. Stable symbolic-link entry points remain stable. |
| Finder entry | The isolated app appears in Open With and receives an explicitly selected test file. Default associations remain unchanged. |
| Automation | First-time permission can be approved. Disabling permission blocks new delivery without destroying the session; reenabling requires an explicit retry and does not replay rejected files. |
| Quit or kill the manager | The next explicit open recovers the same endpoint, generation, editor, and unsaved contents. |
| Unresponsive server | Bounded queries stop work, preserve registration, and create no replacement. Explicit retry can recover after responsiveness returns. |
| Kill before launch release | No late editor starts. The next explicit request retires the finished generation and opens only its own files. |
| Kill after release, before identification | Recover the same live editor and unsaved buffer; do not resend the initial batch. |
| Startup swap prompt | Preserve native recovery choices and initial argv. Waiting at E325 must not create a second editor or be mistaken for failed startup. |
| Normal editor exit | Close only the verified finished owned terminal, clear registration, and let the manager exit. |
| Last ordinary window plus Quick Terminal | Keep the finished pane and registration when closure might end Quick Terminal. Its ID, PID, and TTY stay unchanged, including when hidden. |
| Only Quick Terminal exists | Create an ordinary owned window without replacing or ending Quick Terminal. |

Receipt can become visible in a buffer before Neovlet finishes acknowledgment and
focus. Acceptance scripts must wait for request completion before exiting the editor.
Check both raw startup argv and normalized absolute file paths because Neovim may
represent same-directory arguments relatively. A failed observation or cleanup step
must stop the run instead of allowing later scenarios to mask it.

Completed test sessions should leave no registration, endpoint, launch handshake,
or manager process. Before closing any remaining terminal, verify that it belongs
to the run. Restore candidate settings changed for test wrappers and remove disposable
artifacts without touching unrelated state.

## Remaining release gates

The following are not established by the current automated and functional evidence:

- Actual Ghostty pixel appearance, startup animation, visual focus behavior, and
  Quick Terminal animation. TTY dimensions and offscreen Neovim grids do not prove these.
- A complete current-build desktop pass under the final declared OS and dependency
  requirements, including the current layout wait and login-shell startup together.
- Physical file double-click through a default association, and the full first-time
  authorization experience including delayed approval and denial followed by repair.
- Desktop behavior on the claimed minimum macOS and any additional architecture.
- Developer ID production signing, notarization, offline Gatekeeper, and installation
  from the exact final download ZIP.
- Upgrade, settings retention, and session recovery using the stable production identity.

A public release requires the [distribution acceptance checks](native-swift-design.md#distribution-acceptance),
a final ZIP and checksum, and release notes naming the tested systems and dependencies.
Local ad-hoc signatures, candidate identities, and successful automated tests each
provide useful evidence, but do not satisfy those distribution gates.
