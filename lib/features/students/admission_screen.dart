import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../core/phone.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';
import '../../data/db/tables.dart';
import '../../data/students/admission_form_service.dart';
import '../../data/students/students_repository.dart';
import 'admission_form_builder.dart';

/// Admits one student, using the form the centre designed.
///
/// Nothing here is hardcoded except the batch: the fields, their order, which
/// are required and what they are called all come from the admission form. That
/// is the point — a centre that asks about bus routes gets a bus route box, and
/// one that does not never sees it.
class AdmissionScreen extends ConsumerStatefulWidget {
  const AdmissionScreen({super.key});

  @override
  ConsumerState<AdmissionScreen> createState() => _AdmissionScreenState();
}

class _AdmissionScreenState extends ConsumerState<AdmissionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _controllers = <String, TextEditingController>{};
  final _dates = <String, DateTime>{};

  List<AdmissionField>? _fields;
  String? _batchId;
  String? _nextCode;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final service = ref.read(admissionFormProvider);
    await service.ensureDefaultForm();
    final fields = await service.fields();
    final code = await ref.read(studentsProvider).nextCode();

    if (!mounted) return;
    setState(() {
      _fields = fields;
      _nextCode = code;
      for (final field in fields) {
        _controllers[field.id] = TextEditingController();
      }
    });
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _valueOf(String key) {
    final field = _fields?.where((f) => f.fieldKey == key).firstOrNull;
    if (field == null) return '';
    if (field.type == FormFieldType.date) {
      final date = _dates[field.id];
      return date == null ? '' : date.toIso8601String();
    }
    return _controllers[field.id]?.text.trim() ?? '';
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _batchId == null) return;
    setState(() => _busy = true);

    try {
      final repo = ref.read(studentsProvider);
      final name = _valueOf(AdmissionFormService.keyName);
      final guardianPhone = _valueOf(AdmissionFormService.keyGuardianPhone);
      final studentPhone = _valueOf(AdmissionFormService.keyStudentPhone);

      // Siblings legitimately share a guardian's number, so this asks rather
      // than refuses.
      final duplicates = await repo.findDuplicates(
        name: name,
        guardianPhone: guardianPhone,
        studentPhone: studentPhone,
      );
      if (duplicates.isNotEmpty && mounted) {
        final proceed = await _confirmDuplicates(duplicates);
        if (proceed != true) {
          setState(() => _busy = false);
          return;
        }
      }

      final session = await ref.read(activeSessionProvider.future);
      final dobRaw = _valueOf(AdmissionFormService.keyDateOfBirth);

      await repo.admit(
        name: name,
        batchId: _batchId!,
        sessionId: session!.id,
        guardianName: _valueOf(AdmissionFormService.keyGuardianName),
        guardianPhone: guardianPhone,
        studentPhone: studentPhone,
        school: _valueOf(AdmissionFormService.keySchool),
        address: _valueOf(AdmissionFormService.keyAddress),
        bloodGroup: _valueOf(AdmissionFormService.keyBloodGroup),
        monthlyFee: int.tryParse(_valueOf(AdmissionFormService.keyMonthlyFee)) ?? 0,
        gender: switch (_valueOf(AdmissionFormService.keyGender).toLowerCase()) {
          'male' => Gender.male,
          'female' => Gender.female,
          '' => null,
          _ => Gender.other,
        },
        dateOfBirth: dobRaw.isEmpty ? null : DateTime.tryParse(dobRaw),
        // Only the centre's own questions go into the answers table; the
        // built-in ones already landed on the student record above.
        customFields: {
          for (final field in _fields!)
            if (!field.isBuiltIn)
              field.id: field.type == FormFieldType.date
                  ? (_dates[field.id]?.toIso8601String() ?? '')
                  : _controllers[field.id]!.text,
        },
      );

      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirmDuplicates(List<DuplicateCandidate> candidates) =>
      showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Already on the register?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('These students look similar:'),
              const SizedBox(height: 12),
              for (final c in candidates)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${c.student.name} (${c.student.code})',
                          style:
                              const TextStyle(fontWeight: FontWeight.bold)),
                      Text(c.reason,
                          style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              const Text(
                'Siblings normally share a guardian’s number, so this may be '
                'fine.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Go back'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Admit anyway'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    const section = Section.students;
    final fields = _fields;

    return Scaffold(
      appBar: SectionAppBar(
        section: section,
        title: 'New admission',
        actions: [
          if (_nextCode != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Chip(
                  label: Text(_nextCode!),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          IconButton(
            tooltip: 'Change the form',
            icon: const Icon(Icons.edit_note),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const AdmissionFormBuilder(),
                ),
              );
              await _load();
            },
          ),
        ],
      ),
      body: fields == null
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  _batchPicker(section),
                  const SizedBox(height: 18),
                  for (final field in fields) ...[
                    _fieldWidget(field),
                    const SizedBox(height: 14),
                  ],
                  const SizedBox(height: 10),
                  FilledButton(
                    onPressed: _busy || _batchId == null ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: section.colour,
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Admit student'),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _batchPicker(Section section) {
    final session = ref.watch(activeSessionProvider).value;
    if (session == null) return const SizedBox.shrink();

    return StreamBuilder<List<StudentBatch>>(
      stream: ref.watch(masterDataProvider).watchBatches(session.id),
      builder: (context, snapshot) {
        final batches = snapshot.data ?? const <StudentBatch>[];
        if (batches.isEmpty) {
          return Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('No batches yet'),
              subtitle: Text(
                'Create a batch first — a student is admitted into one.',
              ),
            ),
          );
        }
        return DropdownButtonFormField<String>(
          initialValue: _batchId,
          items: [
            for (final b in batches)
              DropdownMenuItem(
                value: b.id,
                child: Text(
                  b.monthlyFee > 0 ? '${b.name}  ·  ৳${b.monthlyFee}' : b.name,
                ),
              ),
          ],
          onChanged: (v) {
            setState(() => _batchId = v);
            // The batch fee is a starting point the desk can overwrite, so it
            // is offered rather than imposed.
            final batch = batches.where((b) => b.id == v).firstOrNull;
            final feeField = _fields
                ?.where((f) => f.fieldKey == AdmissionFormService.keyMonthlyFee)
                .firstOrNull;
            if (batch != null &&
                feeField != null &&
                (_controllers[feeField.id]?.text ?? '').isEmpty) {
              _controllers[feeField.id]!.text = '${batch.monthlyFee}';
            }
          },
          decoration: InputDecoration(
            labelText: 'Batch',
            filled: true,
            fillColor: section.tint(context),
            border: const OutlineInputBorder(),
          ),
        );
      },
    );
  }

  Widget _fieldWidget(AdmissionField field) {
    final controller = _controllers[field.id]!;
    final label = field.isRequired ? '${field.label} *' : field.label;

    switch (field.type) {
      case FormFieldType.choice:
        final options = () {
          try {
            final raw = jsonDecode(field.optionsJson);
            return raw is List ? raw.map((o) => '$o').toList() : <String>[];
          } catch (_) {
            return <String>[];
          }
        }();
        return DropdownButtonFormField<String>(
          initialValue: controller.text.isEmpty ? null : controller.text,
          items: [
            for (final o in options) DropdownMenuItem(value: o, child: Text(o)),
          ],
          onChanged: (v) => controller.text = v ?? '',
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
          validator: (v) => field.isRequired && (v == null || v.isEmpty)
              ? 'Please choose one.'
              : null,
        );

      case FormFieldType.date:
        final chosen = _dates[field.id];
        return InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
          child: InkWell(
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: chosen ?? DateTime(2010),
                firstDate: DateTime(1950),
                lastDate: DateTime.now(),
              );
              if (picked != null) setState(() => _dates[field.id] = picked);
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(chosen == null
                    ? 'Tap to choose'
                    : '${chosen.day}/${chosen.month}/${chosen.year}'),
                const Icon(Icons.event_outlined, size: 18),
              ],
            ),
          ),
        );

      case FormFieldType.longText:
        return TextFormField(
          controller: controller,
          maxLines: 3,
          decoration: InputDecoration(
            labelText: label,
            hintText: field.hint.isEmpty ? null : field.hint,
            border: const OutlineInputBorder(),
          ),
          validator: (v) => _required(field, v),
        );

      case FormFieldType.phone:
        return TextFormField(
          controller: controller,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(
            labelText: label,
            hintText: field.hint.isEmpty ? null : field.hint,
            helperText:
                field.fieldKey == AdmissionFormService.keyGuardianPhone
                    ? 'Used to find this student at the desk'
                    : null,
            border: const OutlineInputBorder(),
          ),
          validator: (v) {
            final missing = _required(field, v);
            if (missing != null) return missing;
            if (v != null && v.trim().isNotEmpty && !Phone.isValid(v)) {
              return 'That does not look like a mobile number.';
            }
            return null;
          },
        );

      case FormFieldType.number:
        final isFee = field.fieldKey == AdmissionFormService.keyMonthlyFee;
        return TextFormField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: label,
            prefixText: isFee ? '৳ ' : null,
            helperText: isFee
                ? 'What this student pays each month — the batch fee is only a '
                    'starting point'
                : null,
            border: const OutlineInputBorder(),
          ),
          validator: (v) {
            final missing = _required(field, v);
            if (missing != null) return missing;
            if (v != null && v.trim().isNotEmpty && int.tryParse(v) == null) {
              return 'Numbers only.';
            }
            return null;
          },
        );

      case FormFieldType.text:
        return TextFormField(
          controller: controller,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: label,
            hintText: field.hint.isEmpty ? null : field.hint,
            border: const OutlineInputBorder(),
          ),
          validator: (v) => _required(field, v),
        );
    }
  }

  static String? _required(AdmissionField field, String? value) =>
      field.isRequired && (value == null || value.trim().isEmpty)
          ? '${field.label} is needed.'
          : null;
}
