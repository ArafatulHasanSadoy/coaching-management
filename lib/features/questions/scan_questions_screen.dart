import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/bootstrap.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';
import '../../data/db/tables.dart';
import '../../data/questions/ocr_service.dart';

/// Photograph a page of questions and turn it into editable text.
///
/// The design point is that OCR is a *draft*, never an answer. Google's
/// on-device model reads Latin script well and does not read Bangla at all, and
/// even on English a phone photograph of a photocopy will get things wrong. So
/// every result lands in an editable box beside the photograph it came from,
/// nothing is saved until the teacher has looked at it, and the image stays
/// attached to the question as the fallback for anything the text lost.
class ScanQuestionsScreen extends ConsumerStatefulWidget {
  const ScanQuestionsScreen({required this.subjectId, super.key});

  final String subjectId;

  @override
  ConsumerState<ScanQuestionsScreen> createState() =>
      _ScanQuestionsScreenState();
}

class _ScanQuestionsScreenState extends ConsumerState<ScanQuestionsScreen> {
  final _ocr = OcrService();
  File? _image;
  List<TextEditingController> _drafts = [];
  final _keep = <int>{};
  bool _busy = false;
  bool _unsupportedScript = false;
  bool _scanned = false;

  @override
  void dispose() {
    for (final c in _drafts) {
      c.dispose();
    }
    _ocr.dispose();
    super.dispose();
  }

  Future<void> _capture(ImageSource source) async {
    final picked = await ImagePicker().pickImage(
      source: source,
      // Big enough for the recogniser to read small print, small enough that
      // the image does not bloat every backup it appears in.
      maxWidth: 2000,
      imageQuality: 90,
    );
    if (picked == null) return;

    setState(() {
      _busy = true;
      _scanned = false;
      _image = File(picked.path);
    });

    try {
      final result = await _ocr.scan(_image!);
      final questions = OcrService.splitQuestions(result);

      if (!mounted) return;
      for (final c in _drafts) {
        c.dispose();
      }
      setState(() {
        _drafts = [
          for (final q in questions)
            TextEditingController(text: OcrService.withoutLeadingNumber(q)),
        ];
        _keep
          ..clear()
          ..addAll(List.generate(_drafts.length, (i) => i));
        _unsupportedScript = OcrService.looksUnsupported(result.fullText) ||
            (result.isEmpty && _image != null);
        _scanned = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final db = ref.read(databaseProvider);
      final deviceId = ref.read(deviceIdProvider);
      final paths = await ref.read(appPathsProvider.future);

      // The photograph is copied into the app so it survives the camera roll
      // being tidied, and so it travels inside the backup.
      String? storedImage;
      if (_image != null) {
        final dir = Directory('${paths.mediaDir.path}/questions');
        await dir.create(recursive: true);
        final target = File(
          '${dir.path}/${DateTime.now().millisecondsSinceEpoch}.jpg',
        );
        await target.writeAsBytes(await _image!.readAsBytes());
        storedImage = target.path;
      }

      var saved = 0;
      await db.transaction(() async {
        for (var i = 0; i < _drafts.length; i++) {
          if (!_keep.contains(i)) continue;
          final text = _drafts[i].text.trim();
          if (text.isEmpty) continue;

          await db.into(db.questions).insert(
                QuestionsCompanion.insert(
                  subjectId: widget.subjectId,
                  type: QuestionType.short,
                  difficulty: Difficulty.medium,
                  bodyHtml: text.replaceAll('\n', '<br>'),
                  deviceId: deviceId,
                  imagePath: Value(storedImage),
                  sourceTag: const Value('Scanned'),
                ),
              );
          saved++;
        }
      });

      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$saved question(s) added to the bank')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const section = Section.questions;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: SectionAppBar(
        section: section,
        title: 'Scan questions',
        actions: [
          if (_scanned)
            TextButton(
              onPressed: _busy || _keep.isEmpty ? null : _save,
              child: Text('Save ${_keep.length}'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            elevation: 0,
            color: section.tint(context),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Photograph a printed page',
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Text(
                    'Reads English and numbers. It cannot read Bangla — type '
                    'those, or keep the photo and write the question yourself. '
                    'Whatever it reads is a draft for you to correct.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _capture(ImageSource.camera),
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Camera'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _capture(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Gallery'),
                ),
              ),
            ],
          ),

          if (_busy) ...[
            const SizedBox(height: 20),
            const Center(child: CircularProgressIndicator()),
          ],

          if (_image != null) ...[
            const SizedBox(height: 18),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.file(_image!, height: 200, fit: BoxFit.cover),
            ),
          ],

          if (_unsupportedScript) ...[
            const SizedBox(height: 16),
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(
                  'Little or nothing could be read from this page. If it is in '
                  'Bangla that is expected — the photo is still kept with the '
                  'question, so you can type the text and print the picture '
                  'alongside it.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          ],

          if (_scanned && _drafts.isNotEmpty) ...[
            const SectionHeading('Found on the page', section: section),
            Text(
              'Correct anything that came out wrong, and untick what you do not '
              'want.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            for (var i = 0; i < _drafts.length; i++)
              Card(
                elevation: 0,
                margin: const EdgeInsets.only(bottom: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: _keep.contains(i)
                        ? section.colour.withValues(alpha: 0.4)
                        : theme.colorScheme.outlineVariant,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Checkbox(
                            value: _keep.contains(i),
                            onChanged: (on) => setState(() {
                              on ?? false ? _keep.add(i) : _keep.remove(i);
                            }),
                          ),
                          Text('Question ${i + 1}',
                              style: theme.textTheme.labelLarge),
                        ],
                      ),
                      TextField(
                        controller: _drafts[i],
                        maxLines: null,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
