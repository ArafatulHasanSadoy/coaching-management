import 'package:characters/characters.dart';
import 'package:flutter/services.dart';

import '../db/database.dart';

/// Paper the engine knows how to lay out.
enum PaperSize {
  a4('A4', '12mm'),

  /// Half an A4 sheet, the usual size for a money receipt.
  a5('A5', '8mm');

  const PaperSize(this.css, this.margin);
  final String css;
  final String margin;
}

/// The one place that turns content into a printable document.
///
/// Every printed thing in this app — receipts, question papers, routines,
/// report cards — comes through here rather than each module building its own
/// PDF. That is what keeps a centre's branding, margins and typography
/// consistent, and it means the Bengali shaping problem was solved once
/// (Stage 0) instead of five times.
///
/// Documents are HTML because the hard part of a question paper is layout —
/// two-column MCQ, page breaks that do not split a question, running headers —
/// and CSS does that far better than drawing commands. Android's print
/// framework then shapes the Bengali correctly and offers both a WiFi printer
/// and Save-as-PDF.
class DocumentEngine {
  const DocumentEngine({this.institution});

  final Institution? institution;

  static const _channel = MethodChannel('coaching_ops/print');

  /// Wraps [body] in the centre's branding and paper setup.
  String page({
    required String title,
    required String body,
    PaperSize paper = PaperSize.a4,
    bool showLetterhead = true,
    String extraCss = '',
  }) {
    final centre = institution;
    return '''
<!doctype html>
<html lang="bn">
<head>
<meta charset="utf-8">
<title>${escape(title)}</title>
<style>
  @page { size: ${paper.css}; margin: ${paper.margin}; }

  /* Noto covers Bangla and Latin with the same metrics. The stack falls back
     to the platform's own Bengali face rather than to a Latin font, which
     would render Bangla as boxes. */
  body {
    font-family: "Noto Sans Bengali", "Noto Sans", "SolaimanLipi", sans-serif;
    font-size: 11pt;
    line-height: 1.7;
    color: #000;
    margin: 0;
    padding: ${paper.margin};
  }
  .letterhead { display: flex; align-items: center; gap: 8mm;
                border-bottom: 2px solid #000; padding-bottom: 3mm; }
  .letterhead .name { font-size: 17pt; font-weight: 700; }
  .letterhead .meta { font-size: 9pt; color: #333; }
  .doc-title { text-align: center; font-size: 13pt; font-weight: 700;
               letter-spacing: .5px; margin: 5mm 0 3mm; }
  table { border-collapse: collapse; width: 100%; }
  td, th { padding: 1.5mm 2mm; vertical-align: top; }
  .kv td:first-child { color: #444; width: 34%; }
  .totals { margin-top: 4mm; border-top: 1px solid #000; }
  .totals td { padding-top: 2mm; }
  .totals .grand { font-weight: 700; font-size: 12pt; }
  .sign { margin-top: 14mm; display: flex; justify-content: space-between; }
  .sign div { border-top: 1px solid #000; padding-top: 1.5mm;
              font-size: 9pt; width: 45mm; text-align: center; }
  .footer { margin-top: 6mm; font-size: 8.5pt; color: #555; text-align: center; }
  .stamp { position: fixed; top: 40%; left: 50%;
           transform: translate(-50%, -50%) rotate(-24deg);
           font-size: 42pt; font-weight: 700; color: rgba(0,0,0,.10);
           letter-spacing: 6px; pointer-events: none; }
  $extraCss
</style>
</head>
<body>
${showLetterhead ? _letterhead(centre) : ''}
$body
${centre != null && centre.receiptFooter.isNotEmpty ? '<div class="footer">${escape(centre.receiptFooter)}</div>' : ''}
</body>
</html>''';
  }

  /// The centre's letterhead block, for documents that repeat it per page.
  String letterheadHtml() => _letterhead(institution);

  String _letterhead(Institution? centre) {
    if (centre == null) return '';
    final initials = centre.name
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w.characters.first)
        .join();

    return '''
<div class="letterhead">
  <svg width="46" height="46" viewBox="0 0 54 54" aria-hidden="true">
    <circle cx="27" cy="27" r="25" fill="none" stroke="#000" stroke-width="2.5"/>
    <text x="27" y="35" font-size="19" font-weight="700" text-anchor="middle"
          font-family="serif">${escape(initials)}</text>
  </svg>
  <div>
    <div class="name">${escape(centre.name)}</div>
    <div class="meta">${escape([
          if (centre.address.isNotEmpty) centre.address,
          if (centre.phone.isNotEmpty) centre.phone,
        ].join('  •  '))}</div>
  </div>
</div>''';
  }

  /// Hands [html] to Android's print framework.
  ///
  /// The dialog it opens lists WiFi printers and offers Save-as-PDF, so one
  /// call covers both ways a centre gets something onto paper.
  Future<void> printDocument(
    String html, {
    required String jobName,
    PaperSize paper = PaperSize.a4,
  }) =>
      _channel.invokeMethod<bool>('printHtml', {
        'html': html,
        'jobName': jobName,
        // Sent separately from the CSS: @page cannot change the sheet the
        // printer feeds, so the job has to ask for the right one.
        'mediaSize': paper.css,
      });

  /// Escapes text for inclusion in a document body.
  ///
  /// Public because every module that builds a body needs it, and a
  /// student named `A & B` must not break the page.
  /// Prints a PDF the centre already has, unchanged.
  ///
  /// Separate from [printDocument] because a WebView cannot render PDF: the
  /// fixed forms an owner uploads go straight to the print system as they are.
  Future<void> printPdfFile(String path, {required String jobName}) =>
      _channel.invokeMethod<bool>('printPdf', {
        'path': path,
        'jobName': jobName,
      });

  static String escape(String raw) => raw
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
