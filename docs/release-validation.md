# Release validation

This record separates automated evidence from real-machine safety validation.
It is not a certification that unattended or lid-closed use is safe.

## September 14, 2026 baseline

The pre-fix audit found lifecycle races, incomplete recovery reporting,
uninstall recovery loss, Docker daemon-selection ambiguity, and tmux work
continuing after session end. The main-branch baseline passed 178 Swift tests;
the separate icon PR added one packaging test. Seven audit-only failure-path
tests reproduced bugs despite that green baseline. A historical secret scan
reported no detected secrets across 175 locally available commits.

## Remediation evidence

- [CI PR #2](https://github.com/kgarg2468/Insomnia/pull/2), commit
  `f20a860`: hosted macOS tests/release build, ShellCheck, and Greptile check
  succeeded. No unresolved review threads were present at verification.
- [Automation PR #3](https://github.com/kgarg2468/Insomnia/pull/3), commit
  `52a3b29`: after addressing three Greptile findings and a timeout-reporting
  defect, an independent snapshot passed 206 tests, release compilation, and
  ShellCheck. The three review threads are resolved. Follow-up `ba82712`
  installs tmux on the hosted runner: CI now executes the pane tests instead
  of skipping them. Hosted CI reports 206 tests with one animation-dependent
  UI test skipped, zero failures, and a successful release build and ShellCheck.
  The Greptile check also passed. These tests include
  private tmux-server tests and a fake Docker executable against a temporary
  Unix socket. Removing cancellation and endpoint guards caused regression
  tests to fail. Additional cases cover cancelling a queued command before
  launch, retaining the checked tmux pane across an active-pane change, and
  stopping during a suspended hotspot join. This is not a live Docker-freeze
  or hotspot validation.
- Recovery/lifecycle remediation: an independent snapshot of the final source,
  test, and script tree passed 315 tests with zero failures, zero skips, and no
  compiler warnings. Release compilation and ShellCheck passed. A redacted
  source secret scan detected no findings. Tests exercise injected power/audio
  failures, lifecycle races, process identity, launchd sequencing, and temporary
  recovery/install/uninstall fixtures; they do not mutate live power settings or
  install/remove the working app. Hosted CI and automated review must also be
  checked on the resulting PR's latest head.

Check each PR's latest commit and check results; this record does not make an
earlier green run evidence for subsequent changes.

## Hardware validation still required

None of the cases below is certified by the automated regression suite. Record
the tested commit, hardware, macOS version, date, and actual evidence when each
is performed. Do not replace "not run" with "passed" based on source review.

| Scenario | Status |
| --- | --- |
| Normal end, deadline expiry, and repeated Quit restore live power state | Not run for release fixes |
| Force-quit followed by launchd deadline recovery and retry after failure | Not run |
| Reboot/login with active or dirty journals | Not run |
| Lid-close/open and safe recovery of explicitly selected test processes | Not run |
| Existing Low Power Mode preference and saved audio restoration | Not run |
| Docker Desktop idle/busy behavior with another Docker context selected | Not run |
| Hotspot permission, association, cancellation, and reconnect | Not run |
| tmux cancellation with a dedicated disposable pane | Not run |
| Headed-browser throttling with the lid closed | Not run |
| Battery/thermal event behavior on supported hardware | Not run |
| Install/upgrade/uninstall with recoverable failure conditions | Not run |

Hardware tests must be supervised and must not endanger active user work. Use
a stable, ventilated surface, not an enclosure. Do not intentionally overheat a
machine to validate thermal handling; exercise injected thermal events first.

Launchd sequencing tests use a fake command runner. Actual bootstrap of the
private candidate plist, login loading, and crash recovery must still be
checked on the supported macOS release. Installer quit refusal is checked in
source; its full build/install path has not been exercised on a working Mac.

## Distribution boundary

Local source builds use ad-hoc signing. Developer ID signing, notarization,
download packaging, and a consumer installation/recovery walkthrough have not
been completed. Open-source availability and a passing PR are not equivalent
to readiness for a signed public binary release.
