# Visual README Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development for bounded asset work; the manager owns copy and integration.

**Goal:** Make Insomnia understandable at a glance without weakening its safety boundaries.

**Architecture:** README contains the primary narrative and links to three standalone SVG explanations. Detailed operational notes remain available in expandable sections and existing documentation.

**Tech Stack:** GitHub Markdown, HTML disclosure elements, accessible SVG with light/dark styles.

## Global Constraints

- Docs only; application behavior, packaging, and the separate icon PR do not change.
- Fable 5.1 high via Claude Code writes SVG/preview code; current chat model owns prose and verification.
- Experimental source build, macOS 26, Swift tools 6.2 minimum; no signed-download claim.
- Keep ventilation warning, partial recovery, and app-only battery/thermal monitoring visible.
- All file edits use apply_patch. No live installation, power changes, or process freezing.

## Task 1: Narrative and accurate setup

Files: README.md.

- [x] Rewrite the opening around timed awake sessions and the menu-bar workflow.
- [x] Provide clone, install, and open commands, clearly explaining the sudoers grant.
- [x] Explain defaults, optional features, restore limits, uninstall, and developer links.
- [x] Embed session-flow.svg, lid-actions.svg, recovery-flow.svg with descriptive alt text.

## Task 2: Visual explanations

Files: docs/assets/session-flow.svg, docs/assets/lid-actions.svg, docs/assets/recovery-flow.svg.

- [x] Create three original coffee-accented SVGs following the approved design.
- [x] Use readable labels, uncluttered arrows, title/description, and dark-mode styles.
- [x] Parse with xmllint --noout and verify no external resources or executable content.
- [ ] Render the README and inspect diagrams at desktop and narrow widths in light/dark mode.

Render evidence: individual light/dark diagram images inspected; GitHub's Markdown
API renders the README and applies responsive image sizing. Full-page/narrow live
browser inspection remains unverified because the browser connection timed out.

## Task 3: Verification and handoff

- [x] Verify claims against Config.swift, SessionManager.swift, LidActions.swift, Paths.swift, and install/uninstall scripts.
- [x] Check local asset/document links, git diff --check, and the docs-only file allowlist.
- [ ] Commit and open the documentation PR; monitor CI and Greptile with Luna-low.
- [ ] Address verified feedback and report the PR and remaining release limitations.
