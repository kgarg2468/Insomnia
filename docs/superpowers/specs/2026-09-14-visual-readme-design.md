# Insomnia visual README

Approved in conversation on September 14, 2026.

## Outcome

A product-first README inspired by TokenStash: centered introduction, short
install instructions, three original diagrams, and expandable technical detail.
Use warm coffee accents and diagrams that work in GitHub light and dark mode.

## Content and visuals

1. Session overview: choose a duration, keep the Mac awake during the session,
   then attempt restoration at expiry or when ended. Do not promise guaranteed
   recovery or unattended safety.
2. Lid behavior: during an active session, apply configured freeze/audio actions;
   reopening attempts to undo lid actions while the timed session continues.
   No active session means no lid actions. Explain defaults separately.
3. Recovery: normal app cleanup and an independent polling backstop share a
   recovery journal; failed restoration retains evidence. Audio and unconfirmed
   process ownership can need the app or manual inspection.

Keep the experimental source-build status and ventilation warning visible.
Retain permissions, privacy, uninstall, and failure-path limitations, with deep
detail in expandable sections. No invented download, distribution, or safety claims.

## Boundaries and verification

Only README, SVG assets, and these design/plan records change. No application,
installer, CI, icon-PR, or installed-system changes. SVGs use local text and
shapes, descriptive titles and alt text, and no scripts or external assets.
Review SVG XML, local links, factual claims, and rendered layout at desktop and
narrow widths. Publish through a documentation PR with CI and Greptile review.
