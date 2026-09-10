/// Stage 0 print-pipeline spike.
///
/// This page is the acceptance test from the plan: it deliberately contains the
/// Bengali forms that a renderer without OpenType shaping gets wrong. If any of
/// these render incorrectly, the pipeline is unusable for question papers.
///
/// What to look for, in order of how badly each breaks a naive renderer:
///   * Split vowels (কো, কৌ) place glyph parts on BOTH sides of the consonant.
///   * Pre-base vowels (কি, কে, কৈ) render to the LEFT of a consonant they
///     follow in memory order.
///   * Reph (র্ক) turns a leading র into a hook ABOVE the following consonant.
///   * Conjuncts (ক্ষ, ন্ত্র, জ্ঞ) fuse into single glyphs; a visible hasant (্)
///     or a dotted circle (◌) means shaping did not happen.
library;

const String bengaliSampleHtml = r'''
<!doctype html>
<html lang="bn">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  @page { size: A4; margin: 12mm; }

  html { -webkit-text-size-adjust: 100%; }
  body {
    font-family: "Noto Sans Bengali", "Noto Serif Bengali", sans-serif;
    font-size: 11pt;
    line-height: 1.75;
    color: #000;
    margin: 0;
    padding: 12mm;
  }

  .masthead { display: flex; align-items: center; gap: 10mm;
              border-bottom: 2px solid #000; padding-bottom: 4mm; }
  .masthead .name { font-size: 19pt; font-weight: 700; letter-spacing: .2px; }
  .masthead .meta { font-size: 9.5pt; color: #333; }

  .exam-bar { display: flex; justify-content: space-between;
              margin: 5mm 0 2mm; font-size: 11pt; font-weight: 600; }
  .exam-title { text-align: center; font-size: 13pt; font-weight: 700; margin-top: 3mm; }

  h2.section { font-size: 12pt; margin: 7mm 0 2mm; padding: 1.5mm 3mm;
               background: #f0f0f0; border-left: 3px solid #000; }

  .mcq { column-count: 2; column-gap: 9mm; }
  .mcq .q { break-inside: avoid; page-break-inside: avoid; margin-bottom: 3.5mm; }
  .mcq .opts { display: grid; grid-template-columns: 1fr 1fr; margin-top: .5mm; }

  .cq { break-inside: avoid; page-break-inside: avoid; margin-bottom: 5mm; }
  .cq .stem { font-weight: 600; }
  /* HTML's ol@type has no Bengali value, so sub-question lettering
     (ক, খ, গ, ঘ) needs a custom counter style. */
  @counter-style bn-alpha {
    system: fixed;
    symbols: "ক" "খ" "গ" "ঘ" "ঙ" "চ";
    suffix: ") ";
  }
  .cq ol { margin: 1mm 0 0 8mm; padding: 0; list-style: bn-alpha; }
  .answer-space { border: 1px dashed #999; height: 22mm; margin-top: 2mm; }

  /* Shaping diagnostic -------------------------------------------------- */
  table.diag { border-collapse: collapse; width: 100%; font-size: 10pt; }
  table.diag th, table.diag td { border: 1px solid #bbb; padding: 1.5mm 2mm;
                                 text-align: left; vertical-align: middle; }
  table.diag th { background: #f0f0f0; font-size: 9pt; }
  table.diag .glyph { font-size: 20pt; line-height: 1.3; width: 18%; }
  table.diag .codes { font-family: ui-monospace, Menlo, monospace;
                      font-size: 8pt; color: #444; width: 30%; }
  .verdict { font-size: 9pt; color: #444; margin-top: 1.5mm; }
  .page-break { break-before: page; page-break-before: always; }
</style>
</head>
<body>

<!-- ================= PART 1: shaping diagnostic ================= -->

<div class="masthead">
  <svg width="54" height="54" viewBox="0 0 54 54" aria-hidden="true">
    <circle cx="27" cy="27" r="25" fill="none" stroke="#000" stroke-width="2.5"/>
    <text x="27" y="35" font-size="21" font-weight="700" text-anchor="middle"
          font-family="serif">AE</text>
  </svg>
  <div>
    <div class="name">অ্যাডভান্স এডুকেয়ার</div>
    <div class="meta">১২/ক, মিরপুর রোড, ঢাকা&nbsp;১২০৭ &nbsp;•&nbsp; ০১৭xxxxxxxx</div>
  </div>
</div>

<div class="exam-title">Stage&nbsp;0 — Bengali shaping diagnostic</div>

<table class="diag">
  <tr><th>Rendered</th><th>Sequence</th><th>Correct output means</th></tr>

  <tr><td class="glyph">কি</td><td class="codes">ক + ি</td>
      <td>Vowel sits <b>left</b> of ক, though typed after it.</td></tr>

  <tr><td class="glyph">কে</td><td class="codes">ক + ে</td>
      <td>Vowel sits <b>left</b> of ক.</td></tr>

  <tr><td class="glyph">কৈ</td><td class="codes">ক + ৈ</td>
      <td>Double-stroke vowel, <b>left</b> of ক.</td></tr>

  <tr><td class="glyph">কো</td><td class="codes">ক + ো</td>
      <td><b>Split vowel</b> — one part left of ক, one part right.</td></tr>

  <tr><td class="glyph">কৌ</td><td class="codes">ক + ৌ</td>
      <td><b>Split vowel</b> — parts on both sides. Hardest case.</td></tr>

  <tr><td class="glyph">কু</td><td class="codes">ক + ু</td>
      <td>Vowel tucks <b>below</b> ক.</td></tr>

  <tr><td class="glyph">কৃ</td><td class="codes">ক + ৃ</td>
      <td>Vocalic-r <b>below</b> ক.</td></tr>

  <tr><td class="glyph">ক্ষ</td><td class="codes">ক + ্ + ষ</td>
      <td>One fused glyph. No visible ্ and no dotted circle.</td></tr>

  <tr><td class="glyph">জ্ঞ</td><td class="codes">জ + ্ + ঞ</td>
      <td>Ligature that resembles neither input letter.</td></tr>

  <tr><td class="glyph">ন্ত্র</td><td class="codes">ন + ্ + ত + ্ + র</td>
      <td>Three consonants stacked into one cluster.</td></tr>

  <tr><td class="glyph">স্ট্র</td><td class="codes">স + ্ + ট + ্ + র</td>
      <td>Three-consonant cluster.</td></tr>

  <tr><td class="glyph">র্ক</td><td class="codes">র + ্ + ক</td>
      <td><b>Reph</b> — র becomes a hook <b>above</b> ক.</td></tr>

  <tr><td class="glyph">ক্র</td><td class="codes">ক + ্ + র</td>
      <td>Ra-phala hangs below-right of ক.</td></tr>

  <tr><td class="glyph">ক্য</td><td class="codes">ক + ্ + য</td>
      <td>Ya-phala attaches to the right of ক.</td></tr>
</table>

<p class="verdict">
  Real words combining several of the above —
  <b>শিক্ষার্থী</b> · <b>প্রশ্নপত্র</b> · <b>বিশ্ববিদ্যালয়</b> ·
  <b>পদার্থবিজ্ঞান</b> · <b>সৃজনশীল</b> · <b>সংক্ষিপ্ত উত্তর</b> ·
  <b>বহুনির্বাচনি</b>
</p>
<p class="verdict">
  Bengali digits ০১২৩৪৫৬৭৮৯ &nbsp;•&nbsp; currency ৳২,৫০০ and ৳১২,৭৫০
  &nbsp;•&nbsp; mixed script: Class&nbsp;9 / নবম শ্রেণি, Physics / পদার্থবিজ্ঞান
</p>

<!-- ================= PART 2: realistic question paper ================= -->

<div class="page-break"></div>

<div class="masthead">
  <svg width="54" height="54" viewBox="0 0 54 54" aria-hidden="true">
    <circle cx="27" cy="27" r="25" fill="none" stroke="#000" stroke-width="2.5"/>
    <text x="27" y="35" font-size="21" font-weight="700" text-anchor="middle"
          font-family="serif">AE</text>
  </svg>
  <div>
    <div class="name">অ্যাডভান্স এডুকেয়ার</div>
    <div class="meta">১২/ক, মিরপুর রোড, ঢাকা&nbsp;১২০৭</div>
  </div>
</div>

<div class="exam-title">প্রথম সাময়িক পরীক্ষা — ২০২৬</div>
<div class="exam-bar">
  <span>বিষয়: পদার্থবিজ্ঞান</span>
  <span>শ্রেণি: নবম</span>
  <span>সময়: ২ ঘণ্টা</span>
  <span>পূর্ণমান: ৫০</span>
</div>

<h2 class="section">ক-বিভাগ: বহুনির্বাচনি প্রশ্ন &nbsp;(১০ × ১ = ১০)</h2>

<div class="mcq">
  <div class="q">১। বেগের একক কোনটি?
    <div class="opts"><span>(ক) মিটার</span><span>(খ) মি/সে</span>
                      <span>(গ) নিউটন</span><span>(ঘ) জুল</span></div></div>
  <div class="q">২। ত্বরণের মাত্রা কোনটি?
    <div class="opts"><span>(ক) LT⁻¹</span><span>(খ) LT⁻²</span>
                      <span>(গ) MLT⁻²</span><span>(ঘ) ML²T⁻²</span></div></div>
  <div class="q">৩। কোনটি স্কেলার রাশি?
    <div class="opts"><span>(ক) সরণ</span><span>(খ) বেগ</span>
                      <span>(গ) দূরত্ব</span><span>(ঘ) ত্বরণ</span></div></div>
  <div class="q">৪। মুক্তভাবে পড়ন্ত বস্তুর ক্ষেত্রে প্রাথমিক বেগ কত?
    <div class="opts"><span>(ক) ০</span><span>(খ) ৯.৮</span>
                      <span>(গ) ১০</span><span>(ঘ) অসীম</span></div></div>
  <div class="q">৫। শক্তির একক কোনটি?
    <div class="opts"><span>(ক) ওয়াট</span><span>(খ) জুল</span>
                      <span>(গ) নিউটন</span><span>(ঘ) প্যাসকেল</span></div></div>
  <div class="q">৬। সংক্ষিপ্তভাবে, ভরবেগ = ?
    <div class="opts"><span>(ক) mv</span><span>(খ) ma</span>
                      <span>(গ) mgh</span><span>(ঘ) ½mv²</span></div></div>
</div>

<h2 class="section">খ-বিভাগ: সৃজনশীল প্রশ্ন &nbsp;(২ × ১০ = ২০)</h2>

<div class="cq">
  <div class="stem">৭। একটি বস্তু স্থিরাবস্থা থেকে সমত্বরণে চলতে শুরু করে।
      ৫ সেকেন্ড পর তার বেগ ২০ মি/সে হয়।</div>
  <ol>
    <li>ত্বরণ কাকে বলে? <b>২</b></li>
    <li>সমত্বরণ ও সমবেগের পার্থক্য লেখো। <b>৩</b></li>
    <li>সমীকরণ
        <math xmlns="http://www.w3.org/1998/Math/MathML">
          <mi>v</mi><mo>=</mo><mi>u</mi><mo>+</mo><mi>a</mi><mi>t</mi>
        </math>
        ব্যবহার করে ত্বরণ নির্ণয় করো। <b>২</b></li>
    <li>প্রমাণ করো যে অতিক্রান্ত দূরত্ব
        <math xmlns="http://www.w3.org/1998/Math/MathML">
          <mi>s</mi><mo>=</mo><mi>u</mi><mi>t</mi><mo>+</mo>
          <mfrac><mn>1</mn><mn>2</mn></mfrac>
          <mi>a</mi><msup><mi>t</mi><mn>2</mn></msup>
        </math> <b>৩</b></li>
  </ol>
  <div class="answer-space"></div>
</div>

<div class="cq">
  <div class="stem">৮। ২ কেজি ভরের একটি বস্তুকে ২০ মিটার উঁচু ছাদ থেকে ছেড়ে দেওয়া হলো।</div>
  <ol>
    <li>বিভবশক্তি কী? <b>২</b></li>
    <li>ভূমি স্পর্শের আগমুহূর্তে বেগ
        <math xmlns="http://www.w3.org/1998/Math/MathML">
          <mi>v</mi><mo>=</mo>
          <msqrt><mrow><mn>2</mn><mi>g</mi><mi>h</mi></mrow></msqrt>
        </math>
        — মান নির্ণয় করো। <b>৩</b></li>
    <li>গতিশক্তি ও বিভবশক্তির রূপান্তর ব্যাখ্যা করো। <b>৫</b></li>
  </ol>
  <div class="answer-space"></div>
</div>

</body>
</html>
''';
