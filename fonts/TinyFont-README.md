# TinyFont — 16 pixel fonts traced from your sprite sheet

Every glyph in these fonts is the *exact* pixel art from your sheet — traced to vector
outlines, not redrawn. Verified: **2192 / 2192 glyphs render pixel-identical to the source**
through FreeType (the same rasteriser Godot uses), with hinting both on and off.

## The 7 families

| Family | Styles | Design size | Cap height | Notes |
|---|---|---|---|---|
| TinyFont 12 | Regular, Bold, Italic | 12 px | 7 | sheet row 1 |
| TinyFont Mono 12 | Regular, Bold | 12 px | 7 | fixed pitch |
| TinyFont Narrow 12 | Regular, Bold | 12 px | 7 | condensed |
| TinyFont 10 | Regular, Bold | 10 px | 6 | smallest |
| TinyFont 15 | Regular, Bold, Italic | 15 px | 9 | |
| TinyFont 17 | Regular, Bold | 17 px | 11 | largest |
| TinyFont Caps 17 | Regular, Bold | 17 px | 11 | small caps (lowercase = small capitals) |

Regular / Bold / Italic inside a family are style-linked, so Godot's **bold** and *italic*
toggles pick the right file automatically once all files in a family are imported.

## Godot import settings — important

Select the `.ttf` in the FileSystem dock → **Import** tab → set:

```
Antialiasing ................. Disabled
Hinting ...................... None
Subpixel Positioning ......... Disabled
Multichannel Signed Distance Field (MSDF) ... off
Generate Mipmaps ............. off
```

then press **Reimport**. Without this Godot blurs pixel fonts by default.

### Font size

Use the **design size** from the table, or an exact integer multiple of it (12, 24, 36, 48 …).
At those sizes one design pixel = a whole number of screen pixels and the glyphs are perfectly
crisp. In-between sizes will look soft.

Also set your project to an integer-scaled viewport
(*Project Settings → Display → Window → Stretch → Mode: `viewport`, Scale Mode: `integer`*)
so the whole game scales in whole pixels.

## What's in each font (173 characters)

- `A–Z` `a–z` `0–9`
- Accented Latin: `ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÑÒÓÔÕÖŒÙÚÛÜŸß` and lowercase, plus `ẞ`
- From the sheet: `! ¡ ? ¿ # & @ % $ ¢ € £ ¥ © ® * ~`
- **Added by me** (the sheet had none): space `. , : ; ' " - – — _ ( ) [ ] { } / \ | + = < > ^ \` « » · ° … × ÷ ' ' " "`
  Each is drawn on the same pixel grid at the same stroke weight as its font. Where the sheet
  contained an authentic source I reused it rather than inventing: the period is the tittle
  from `i`, the comma is the cedilla from `Ç`, the dashes are the en-dash from the specimen
  captions, and the grave is the accent lifted off `À`.

## Notes

- **Space width** was measured from the gap in each specimen caption, so it matches the
  original designer's spacing (3 px for most, 6–7 px for the monospaced family).
- **Italics** are true-drawn in the source, not obliques — they're traced as such.
- The fonts carry a `prep` program that turns off dropout control and a no-op glyph
  instruction that keeps FreeType's autohinter away, so they stay pixel-exact even if
  something forgets to disable hinting.
- If these glyphs came from a purchased or licensed asset pack, that pack's licence still
  governs how you use them — converting the format doesn't change that.

## Files

```
fonts/                  16 .ttf files
TinyFont-tester.html    open in any browser: live text, all 16 fonts, 1×–6× scale
specimen_all.png        every font rendered at its design size
```
