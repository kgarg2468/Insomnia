# Warm Ceramic App Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate the approved Warm Ceramic artwork and make every locally installed Insomnia app bundle use it.

**Architecture:** Keep one reviewable 1024×1024 PNG master in `Resources` and derive a standard multi-resolution ICNS file from it. The existing installer remains the sole bundle assembler and copies the ICNS resource before ad-hoc signing.

**Tech Stack:** OpenAI built-in image generation, macOS `sips`, `iconutil`, shell, Property List XML, Swift Package Manager

## Global Constraints

- Preserve Insomnia as a menu-bar-only `LSUIElement` application.
- Do not change the existing monochrome menu-bar cup.
- Use the approved warm ivory, white ceramic, and espresso-brown design with no text or third-party branding.
- Keep the mark legible at 16 px and 32 px.
- Do not add runtime dependencies.

---

### Task 1: Create the icon assets

**Files:**
- Create: `Resources/AppIcon-1024.png`
- Create: `Resources/AppIcon.icns`

**Interfaces:**
- Consumes: approved Warm Ceramic visual specification
- Produces: a 1024×1024 PNG master and a valid macOS ICNS file named `AppIcon.icns`

- [x] **Step 1: Record the missing-asset failure**

Run:

```bash
test -f Resources/AppIcon-1024.png && test -f Resources/AppIcon.icns
```

Expected: FAIL because neither icon asset exists.

- [x] **Step 2: Generate the approved master artwork**

Use the built-in image-generation tool with this production prompt:

```text
Use case: logo-brand
Asset type: macOS application icon master, 1024 by 1024 pixels
Primary request: a simple, polished coffee-cup app icon for an app named Insomnia
Scene/backdrop: a warm ivory macOS-style rounded-square icon field with genuinely transparent exterior corners
Subject: one centered white ceramic coffee cup, espresso-brown outline, two soft curls of steam, and a restrained saucer line
Style/medium: minimal premium 3D/vector hybrid, tactile ceramic, Apple-like restraint without copying any Apple logo or product icon
Composition/framing: centered, large simple silhouette, generous optical padding, readable at 16 px
Lighting/mood: soft diffuse studio light, calm and warm
Color palette: warm ivory, cream white, espresso brown
Constraints: no text, no letters, no Apple marks, no extra objects, no watermark; preserve real alpha outside the rounded-square field; crisp edges and strong small-size contrast
Avoid: photorealistic scene, busy texture, thin fragile lines, harsh shadows, gradients that muddy the silhouette
```

Inspect the output, copy the selected artifact into `Resources/AppIcon-1024.png`, and confirm it is exactly 1024×1024 pixels.

- [x] **Step 3: Derive the standard iconset and ICNS**

Create temporary PNG renditions at 16, 32, 64, 128, 256, 512, and 1024 px using `sips`, with standard `icon_16x16.png` through `icon_512x512@2x.png` names. Run `iconutil -c icns` and save the result as `Resources/AppIcon.icns`.

- [x] **Step 4: Validate both assets**

Run:

```bash
test "$(sips -g pixelWidth -g pixelHeight Resources/AppIcon-1024.png | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w "x" h}')" = "1024x1024"
file Resources/AppIcon.icns | grep -q 'Mac OS X icon'
iconutil -c iconset Resources/AppIcon.icns -o /tmp/insomnia-app-icon.iconset
```

Expected: all commands exit 0 and the extracted iconset contains all standard representations.

- [x] **Step 5: Commit the artwork**

```bash
git add Resources/AppIcon-1024.png Resources/AppIcon.icns
git commit -m "feat: add warm ceramic app icon"
```

### Task 2: Wire the icon into installed bundles

**Files:**
- Modify: `Resources/Info.plist`
- Modify: `scripts/install.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: `Resources/AppIcon.icns` from Task 1
- Produces: app bundles declaring `CFBundleIconFile=AppIcon` with the corresponding ICNS copied to `Contents/Resources/AppIcon.icns`

- [x] **Step 1: Verify bundle metadata and resource wiring are absent**

Run:

```bash
test "$(plutil -extract CFBundleIconFile raw Resources/Info.plist 2>/dev/null)" = "AppIcon"
grep -Fq 'Resources/AppIcon.icns' scripts/install.sh
```

Expected: FAIL because the plist key and installer copy step do not exist.

- [x] **Step 2: Add the icon metadata and bundle copy**

Add this property to `Resources/Info.plist`:

```xml
<key>CFBundleIconFile</key>
<string>AppIcon</string>
```

During bundle assembly, create `Insomnia.app/Contents/Resources` and copy `Resources/AppIcon.icns` into it before code signing.

- [x] **Step 3: Document the branded icon**

Add a short README note that the installer bundles the Warm Ceramic icon while the menu bar continues to use its monochrome status mark.

- [x] **Step 4: Verify packaging without privileged installation**

Run a temporary bundle assembly using the release binary, `Resources/Info.plist`, and `Resources/AppIcon.icns`; then run:

```bash
ICON_TEST_ROOT="$(mktemp -d)"
TEST_APP="$ICON_TEST_ROOT/Insomnia.app"
mkdir -p "$TEST_APP/Contents/MacOS" "$TEST_APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Insomnia" "$TEST_APP/Contents/MacOS/Insomnia"
cp Resources/Info.plist "$TEST_APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$TEST_APP/Contents/Resources/AppIcon.icns"
plutil -lint "$TEST_APP/Contents/Info.plist"
test "$(plutil -extract CFBundleIconFile raw "$TEST_APP/Contents/Info.plist")" = "AppIcon"
test -f "$TEST_APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --deep "$TEST_APP"
codesign --verify --deep --strict "$TEST_APP"
rm -rf "$ICON_TEST_ROOT"
```

Expected: all commands exit 0.

- [x] **Step 5: Run the complete test suite**

Run:

```bash
swift test
```

Expected: 178 tests pass with 0 failures.

- [x] **Step 6: Commit the integration**

```bash
git add Resources/Info.plist scripts/install.sh README.md
git commit -m "feat: bundle the Insomnia app icon"
```

### Task 3: Add automated packaging regression coverage

**Files:**
- Create: `scripts/assemble-app.sh`
- Create: `Tests/InsomniaTests/PackagingTests.swift`
- Modify: `scripts/install.sh`

**Interfaces:**
- Consumes: a destination ending in `Insomnia.app` and an executable binary path
- Produces: a signed app bundle whose declared icon exists at `Contents/Resources/AppIcon.icns`

- [x] **Step 1: Add a packaging test and verify it fails without the assembler**

- [x] **Step 2: Extract app assembly into `scripts/assemble-app.sh` and call it from the installer**

- [x] **Step 3: Run the packaging test and complete suite**

- [x] **Step 4: Commit and push the review fix**
