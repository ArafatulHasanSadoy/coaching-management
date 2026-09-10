# Stage 0 — print pipeline: PASSED

**Path A (HTML → WebView → Android `PrintDocumentAdapter`) is the Document Engine.**
Verified end to end on a physical Realme RMX3612, Android 14 (API 34), WebView 152.

Artifacts: `docs/stage-0-device-output.pdf` (generated on the device),
`lib/spike/bengali_sample.dart` (source page), `docs/spike-preview.html` (browser copy).

## Result

| Check | Result |
|---|---|
| Android WebView renders Bengali correctly | Pass |
| **Shaping survives PDF generation** | **Pass** — this was the real unknown |
| Page size / pagination | Pass — 3 pages, A4 595×841 pt, page break honoured |
| Two-column MCQ, `break-inside: avoid` | Pass — no question split across columns |
| MathML | Pass — natively, no library |
| Print dialog lists WiFi printers | Pass — discovery screen works (none on this network) |
| Save-as-PDF target | Pass |
| Bengali text extraction from PDF | Pass — PDFs are searchable and copy-pasteable |

Producer string on the device output is `Skia/PDF m152`, with
`NotoSansBengali-Regular` embedded and subsetted.

### Shaping cases verified in the generated PDF

Pre-base vowels (কি, কে, কৈ) · **split vowels (কো, কৌ)** with parts correctly on
both sides · below-base vowels (কু, কৃ) · conjuncts (ক্ষ, জ্ঞ, ক্ত) fused with no
hasant and no dotted circles · triple conjuncts (ন্ত্র, স্ট্র) · **reph (র্ক)** as a hook
above · ra-phala and ya-phala (ক্র, ক্য) · real words (শিক্ষার্থী, পদার্থবিজ্ঞান,
বহুনির্বাচনি) · Bengali digits ০১২৩৪৫৬৭৮৯ · currency ৳১২,৭৫০ · mixed Bangla/Latin runs.

## Four findings that change the plan

**1. MathML renders natively — drop KaTeX.**
Fractions, superscripts and radicals with overbars all render correctly with no
library. Removes a bundled JS/CSS/font dependency, and means **JavaScript stays
disabled in the print WebView** — faster and a smaller attack surface.

**2. `<ol type="ক">` silently renders as 1/2/3.**
HTML's `type` accepts only `1, a, A, i, I` — there is no Bengali value, so
Bangladeshi CQ sub-questions came out as Arabic numerals. Fixed with a custom
counter style; every Bengali-numbered list in this app must use one:

```css
@counter-style bn-alpha {
  system: fixed;
  symbols: "ক" "খ" "গ" "ঘ" "ঙ" "চ";
  suffix: ") ";
}
```

**3. Bundle the Bengali font — do not rely on system fallback.**
The same HTML picked `KohinoorBangla` on macOS and `NotoSansBengali` on Android.
Different metrics, different look, different line breaks. A paper printed from
the office PC would not match one printed from the phone. Ship Noto Sans Bengali
as a bundled asset and reference it via `@font-face`, so output is identical on
every device. (Noto is SIL OFL, so bundling and redistribution are fine.)

**4. Chromium embeds shaped Bengali as Type 3 fonts.**
Observed on both macOS and Android, so it is Chromium/Skia behaviour rather than
platform-specific. Visual output and text extraction are both correct, so this is
not a defect — but Type 3 inflates file size, and very old PostScript RIPs handle
it poorly. Worth re-checking if a coaching center ever reports bad output from an
old office printer.

## Consequences for the architecture

- Path B (`pdf` + `bangla_pdf_fixer`) is **not needed** and is dropped from v1.
  Keep it noted only as the likely route if a Windows desktop build happens later,
  since `PrintDocumentAdapter` is Android-only.
- Every document — receipts, question papers, routines, report cards, the Print
  Center's mail-merge templates — is authored as HTML/CSS and rendered through
  the single Kotlin bridge in `MainActivity.kt`.
- The preview a user sees and the page that prints come from the same HTML, so
  WYSIWYG is structural rather than something to maintain.

## Not yet done

Printing to **physical paper on a real WiFi printer** — no printer on this
network. Margins, scaling and duplex behaviour should be confirmed at the pilot
coaching center. Everything upstream of the printer is verified.
