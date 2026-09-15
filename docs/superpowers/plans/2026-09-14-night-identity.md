# Night Identity Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development, with user-directed Fable-high implementation and chat-model review.

**Goal:** Apply the approved eye/crescent identity consistently to the app and product documentation.

**Architecture:** Native vector mark plus reproducible app-icon assets, followed by matching UX-led SVG documentation. Keep existing behavioral code unchanged.

**Tech Stack:** SwiftUI, CoreGraphics/AppKit, shell packaging, GitHub Markdown, SVG.

## Global Constraints

- Approved spec: docs/superpowers/specs/2026-09-14-night-identity-design.md.
- Eye outline, only crescent inside, opening/tips right; no coffee, lashes or glow.
- #06012C midnight, #11151F charcoal, #EEF0F7 moon-white, #9691D9 violet.
- Preserve native light/dark support and semantic warnings; no new dependencies.
- Fable-high writes all code, tests, SVG and generators via apply_patch.
- No live install, app session, power/network changes, git commits or external writes by workers.
- Manager owns human prose, git/PR and final verification. User routing overrides additional reviewer-model dispatch.

### Task 1: Native identity and icon packaging

Files: Sources/Insomnia/UI/CupMark.swift (replace/remove), EyeMoonMark.swift,
EyeMoonGeometry.swift, BrandPalette.swift, StatusRootView.swift, PillView.swift,
HoldToEndButton.swift, StatusItemController.swift and MenuBarModel.swift (comments
only in last two); Resources/Info.plist, AppIcon-1024.png, AppIcon.icns;
scripts/generate-app-icon.swift, generate-app-icon.sh; scripts/install.sh;
Tests/InsomniaTests/BrandingTests.swift and PackagingTests.swift;
Tests/InsomniaTests/RecoveryScriptTests.swift (icon fixture and bundle assertions only).

Interfaces: preserve existing callbacks/animation semantics. EyeMoonMarkView takes
isRunning/reduceMotion and optional size, matching CupMarkView's consumer contract.
Share pure geometry between native mark and generated icon if practical; avoid
frameworks or duplicated pixel art. Generated resources consumed by installer.

- [ ] Add focused failing tests for crescent orientation/rendering and packaged icon resolution; run filtered tests and record failures.
- [ ] Implement native eye/crescent; neutral idle and restrained violet active, without flooding the eye interior. Retain countdown-based active indication.
- [ ] Generate deterministic 1024 PNG and complete multi-resolution ICNS from vector geometry with checked-in reproducible tooling; no image-model output as production asset.
- [ ] Add CFBundleIconFile and copy the icon in the existing installer bundle section. Preserve every recovery/quit check; avoid refactoring installer or importing stale PR1 script.
- [ ] Run focused tests, Swift build, ShellCheck. Render mark at menu-bar sizes in light/dark and icon at app sizes to temporary files for manager inspection.

### Task 2: UX-led documentation assets

Files: docs/assets/session-flow.svg, lid-actions.svg, recovery-flow.svg,
eye-moon.svg, docs/mockups/menubar-ux.html. Manager separately owns README.md.

Interfaces: existing three README image paths remain stable. Reuse Task1 mark
geometry and palette. Source UI labels from actual SettingsView/StatusMenu; do not
invent a dashboard or unsupported controls. Mockup remains explicitly a mockup.

- [ ] Rebuild session visual with actual inline duration fields, countdown and hold-to-end control, with concise callouts and caveat.
- [ ] Rework lid/recovery visuals with faithful selected Settings/status excerpts and explanatory arrows. Keep attempts, shared lock, due-only polling, retained failure evidence and audio/manual recovery caveats.
- [ ] Replace coffee symbols/colors in the existing mockup, preserving its interactions; update displayed copy as needed.
- [ ] Provide title/desc/alt-compatible SVGs, light/dark styles and legible labels; no external resources/scripts in SVGs. Validate XML and render visuals locally without installing packages.

### Task 3: Integration and PR verification

Files: README.md and this task ledger (manager prose).

- [ ] Change cup wording and brown badges, add the new mark to the header, preserve all safety/default/recovery disclosures.
- [ ] Review each worker's scope, spec compliance and quality. Fix findings through original Fable worker.
- [ ] Run full swift test, release build, ShellCheck, plist/SVG checks and link validation; inspect app icon and small/light/dark marks. Do not install.
- [ ] Commit and push to PR5, update its title/body to branding scope, monitor CI and actual Greptile feedback with Luna-low. No merge.
