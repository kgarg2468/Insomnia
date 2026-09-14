# Warm Ceramic App Icon Design

## Goal

Replace Insomnia's generic macOS application icon with a distinctive coffee-cup mark that feels native beside Apple's first-party app icons.

## Approved Visual Direction

The icon uses the approved **Warm Ceramic** direction:

- a warm ivory macOS-style rounded-square field with transparent exterior corners;
- a centered white ceramic coffee cup;
- espresso-brown outlines and details;
- two simple curls of steam and a restrained saucer line;
- soft dimensional lighting without visual noise;
- no text, letters, Apple marks, or third-party branding.

The silhouette and contrast must remain legible at 16 px and 32 px. Fine texture, photorealistic backgrounds, extra objects, and thin decorative lines are out of scope.

## Deliverables

- `Resources/AppIcon-1024.png` is the generated 1024×1024 source artwork with an alpha channel around the icon field.
- `Resources/AppIcon.icns` contains the standard macOS icon representations derived from the source artwork.
- `Resources/Info.plist` declares `AppIcon` as `CFBundleIconFile`.
- `scripts/install.sh` copies `AppIcon.icns` into `Insomnia.app/Contents/Resources` before signing.

The app remains a menu-bar-only `LSUIElement`; this change affects Finder, Spotlight, application metadata, and other places that display the app bundle icon. It does not replace the existing monochrome menu-bar cup.

## Verification

- Validate the PNG dimensions and ICNS format.
- Assemble a temporary app bundle without installing privileged helpers and verify that its declared icon exists at `Contents/Resources/AppIcon.icns`.
- Run the complete Swift test suite.
- Inspect the generated master and representative small-size renditions visually.
