# Pasty — macOS App Icon Generation Prompts

> Generation target: **GPT-Image-2** (`gpt-image-2`) at 1024×1024.
> Final delivery: 16/32/64/128/256/512/1024 PNG ICNS set for `Assets.xcassets/AppIcon.appiconset`.

---

## 0. Design intent (read this before tweaking the prompt)

Pasty is **the upper-compatible successor to Paste, free under MIT**. The icon has to deliver three messages in one glance:

1. **Clipboard / paste** — instantly readable as a clipboard manager.
2. **Liquid Glass, Jony-Ive minimal** — at home next to native macOS Tahoe (15/16) icons.
3. **Notch-hover signature** — Pasty's killer interaction; one tiny visual nod to "things slide down from the top."

The palette is fixed by the landing page: **indigo → purple → cyan diagonal**, the same hues the brand mark and `MenuBarExtra` glyph use. The icon must feel inevitable — like Apple could have shipped it.

---

## 1. Primary prompt (canonical — use this first)

```
A macOS Big Sur / Tahoe style app icon, 1024×1024, centered squircle composition with Apple's standard 23.7% superellipse corner radius and the standard macOS isometric shadow set. No background — render on a fully transparent canvas — the squircle itself is the icon body.

The squircle is a flawless polished Liquid Glass tile: a deep indigo-to-violet-to-cyan diagonal gradient (start #4F46E5 top-left, transition through #8B5CF6, end #06B6D4 bottom-right), with a soft inner highlight at top, a subtle inner shadow at bottom-right, and a faint specular sweep across the upper third — as if light just rolled off a glass marble.

Floating in the exact optical center, slightly tilted forward as if held mid-air, is a single stylized clipboard: a thick, glossy, frosted-white clipboard frame with a small clip at the top. The clipboard surface is translucent Liquid Glass with a 4–6% inner blur of the gradient behind it; behind the surface, three soft horizontal lines suggest a "history" of stacked clipboard items receding into the depth — only the top one is fully crisp, the second slightly desaturated, the third blurred — communicating "clipboard with infinite memory" without text.

At the very top of the clipboard's clip, a soft warm-white horizontal glow protrudes upward by ~4% of the icon height — like a subtle exhale of light "coming down from above" — a quiet signature of Pasty's notch-hover interaction. This glow must be tasteful, not gimmicky.

Lighting: top-key 30° front-left, soft ambient fill, faint contact shadow under the clipboard against the squircle floor. Materials: physically-correct refraction at the clipboard edges, very subtle chromatic aberration on the squircle rim only.

No text. No logo. No letters. No grid. No drop-shadow on the squircle (Apple manages that systemically). No skeuomorphic paper, no folds, no pencil — keep it digital and serene. Match the design language of Apple's own native macOS app icons such as Notes, Reminders, and Freeform.

Final image is razor-sharp at 1024×1024, fully transparent outside the squircle silhouette, suitable for `icon_1024x1024.png` in an Xcode AppIcon set.
```

---

## 2. Alternate prompt — "geometry over object" (use if v1 reads too literal)

```
A macOS Big Sur / Tahoe style app icon, 1024×1024, centered squircle, transparent background, 23.7% superellipse corner radius.

The squircle is a single Liquid Glass slab in an indigo-to-violet-to-cyan diagonal gradient (top-left #4F46E5 → middle #8B5CF6 → bottom-right #06B6D4). Polished. Soft inner highlight upper edge; faint inner shadow lower edge.

On top of the slab, dead center, render exactly three softly stacked translucent rounded rectangles in pure white at 12% / 22% / 36% opacity (back to front). Each rectangle is the same aspect ratio (3:4), the back two peek out slightly above and to the right, suggesting a deck of stacked cards or clipboard pages held mid-air. The frontmost card has a subtle bright edge highlight and a faint inner gradient picking up the slab's hue at 6% opacity.

Above the topmost card, a faint warm-white horizontal beam descends from the top edge of the squircle by ~5% of icon height — Pasty's signature "something comes down from the notch" cue. The beam fades to nothing before it touches the card.

No text, no letters, no symbols, no clipboard clip, no paper texture. Geometry only. Polished. Inevitable. Like an Apple-made icon.

Render with crisp anti-aliasing at 1024×1024 with full alpha. Suitable for Xcode AppIcon set.
```

---

## 3. Alternate prompt — "P monogram in liquid glass" (use if you want the brand mark)

```
A macOS Big Sur / Tahoe style app icon, 1024×1024, centered squircle, transparent background outside the squircle, Apple-standard 23.7% superellipse radius.

The squircle is a Liquid Glass tile with an indigo-purple-cyan diagonal gradient (top-left #4F46E5 → middle #8B5CF6 → bottom-right #06B6D4), soft inner upper highlight, faint inner lower shadow, single specular sweep across the upper third.

Floating slightly above the surface, in the optical center, a single soft-edged lowercase "p" rendered in San Francisco Display weight-bold, but built entirely out of translucent frosted glass — like a Liquid Glass sculpture of the letter. The "p" is white with 30% transparency, picks up faint indigo from below through internal refraction, and casts a soft contact shadow on the squircle floor. The stem of the "p" extends slightly above the bowl, and at its very top a faint warm-white horizontal glow hovers — a 4% icon-height beam descending from above, a quiet nod to Pasty's notch-hover interaction.

Constraints: no other letters, no numbers, no surrounding text, no clipboard imagery (the letter alone carries the brand), no flat shading, no neon. Materials are deeply realistic. Lighting is restrained.

1024×1024, full alpha, ready for `icon_1024x1024.png` in Xcode AppIcon set.
```

---

## 4. Negative space (avoid in all variants)

Tell GPT-Image-2 to skip these via the prompt's "no/avoid" clauses. The model handles negatives best inline:

- No text, letters, numbers, or watermarks (except prompt 3's intentional "p").
- No drop shadow on the squircle (macOS handles system shadow).
- No skeuomorphic paper, folds, pencils, or wood-grain clipboards.
- No bezel or screen-mockup illusion.
- No neon glow, no synthwave, no chromatic edges except the controlled rim aberration.
- No 3D perspective beyond a single ~5° forward tilt.
- No background gradient outside the squircle — the canvas must be fully transparent.

---

## 5. Generation parameters

```
model:        gpt-image-2
size:         1024x1024
quality:      high
background:   transparent
n:            4               # generate four candidates per prompt
output_format: png
```

---

## 6. Post-generation pipeline

```bash
# 1. Pick the best candidate, save as icon_1024.png
# 2. Generate the full Xcode AppIcon set via sips:

WORK=icons/Pasty.appiconset
mkdir -p "$WORK"
SRC=icon_1024.png

for spec in "16:16" "32:16@2x" "32:32" "64:32@2x" "128:128" "256:128@2x" "256:256" "512:256@2x" "512:512" "1024:512@2x"; do
  size="${spec%%:*}"; name="${spec##*:}"
  sips -Z "$size" "$SRC" --out "$WORK/icon_${name}.png"
done

# 3. Build .icns
iconutil -c icns "$WORK" -o Pasty.icns

# 4. Drop into Sources/Pasty/Resources/AppIcon.appiconset/ and update
#    Info.plist's CFBundleIconFile to "Pasty".
```

---

## 7. Acceptance criteria

A generated icon ships if and only if:

- [ ] Reads as a clipboard manager from 32px without ambiguity.
- [ ] Sits naturally beside macOS Notes / Reminders / Freeform on the Dock.
- [ ] The notch-glow signature is *present but not loud*; if a casual viewer doesn't notice it, that's a feature.
- [ ] The gradient hits the same indigo/purple/cyan the website uses (verify with eyedropper).
- [ ] Renders crisp at 16px (line-up artifacts disqualify a candidate).
- [ ] Alpha is clean — no haloing at the squircle edge against a Dock background.

---

## 8. Iteration tips

- If GPT-Image-2 returns a too-busy clipboard, fall back to prompt 2 (geometry-first).
- If the gradient feels muddy, append: *"the gradient must remain saturated and luminous; do not desaturate beyond the original brand palette."*
- If the squircle reads as a perfect rounded rectangle (telltale non-Apple), append: *"use Apple's specific superellipse curvature, not a circular-corner radius — the curvature must accelerate towards the corners."*
- If the model adds a Pasty wordmark, append: *"absolutely no text or characters anywhere in the image."*
- Generate one candidate per major macOS context: Dock-lit (default), Spotlight-grey, Light-Mode dock, Dark-Mode dock. Best icons survive all four.
