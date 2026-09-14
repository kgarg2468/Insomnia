# Insomnia night identity

Approved by the user on 2026-09-14 after a visual preview.

## Visual contract

Replace coffee branding with a simple almond-shaped eye outline containing only
a solid crescent moon. The moon's convex spine is on the left; its opening and
both tips face right. No lashes, stars, iris, lettering inside the eye, or glow.
The app icon uses a midnight-blue rounded tile; the menu-bar mark remains legible
at 17–20 points, with a recognizable active state and native light/dark support.

Palette: midnight indigo #06012C, charcoal #11151F, moon-white #EEF0F7,
restrained violet #9691D9. Preserve semantic warning/error colors and native
settings appearance; do not force dark mode globally.

## README illustrations

Keep the existing clean vector-diagram style, replacing generic session cards
with the exposed UX: inline Days/Hours/Minutes fields, live countdown, and
hold-to-end control. Lid/recovery diagrams should connect explanations to
faithful Settings/status-menu excerpts, clearly illustrative rather than fake
screenshots. Keep recovery attempts, failures, defaults and safety limits accurate.

## Scope and release

Update app/menu-bar artwork, narrowly scoped branding accents, icon packaging,
README and its graphics, and the existing UI mockup. No session, power, recovery,
network, permission, or automation behavior changes. No live installation or
running a real awake session. Reuse the existing PR5 worktree and update PR5;
the old coffee-icon PR1 stays unmerged. No merge authorized by this approval.

Fable-high writes code/SVG and generated-asset tooling. The chat model owns prose,
spec/quality reviews and verification. CI/Greptile review; Luna-low monitors.
