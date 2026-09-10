import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';
import '../../data/db/tables.dart';

/// Designs the centre's own admission form.
///
/// Built once, before anyone is admitted, and then it *is* the form. Every
/// centre asks for something the next one does not, and a fixed set of fields
/// would leave most of them keeping a paper form beside the app.
class AdmissionFormBuilder extends ConsumerWidget {
  const AdmissionFormBuilder({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const section = Section.students;
    final service = ref.watch(admissionFormProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: const SectionAppBar(
        section: section,
        title: 'Admission form',
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: section.band(context),
        foregroundColor: section.onTint(context),
        onPressed: () => _addField(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add a question'),
      ),
      body: StreamBuilder<List<AdmissionField>>(
        stream: service.watchFields(),
        builder: (context, snapshot) {
          final fields = snapshot.data;
          if (fields == null) {
            return const Center(child: CircularProgressIndicator());
          }

          return Column(
            children: [
              Container(
                width: double.infinity,
                color: section.tint(context),
                padding: const EdgeInsets.all(14),
                child: Text(
                  'This is the form used for every admission. Drag to reorder. '
                  'The built-in questions feed the student record itself, so '
                  'they can be renamed or hidden but not deleted.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              Expanded(
                child: ReorderableListView(
                  padding: const EdgeInsets.only(bottom: 88),
                  // onReorderItem, not onReorder: it already accounts for the
                  // removed item, so no off-by-one adjustment is needed.
                  onReorderItem: (from, to) {
                    final reordered = [...fields];
                    reordered.insert(to, reordered.removeAt(from));
                    service.reorder(reordered);
                  },
                  children: [
                    for (final field in fields)
                      ListTile(
                        key: ValueKey(field.id),
                        leading: Icon(_iconFor(field.type),
                            color: section.onTint(context)),
                        title: Row(
                          children: [
                            Flexible(child: Text(field.label)),
                            if (field.isRequired)
                              Padding(
                                padding: const EdgeInsets.only(left: 6),
                                child: Text('*',
                                    style: TextStyle(
                                        color: theme.colorScheme.error,
                                        fontWeight: FontWeight.bold)),
                              ),
                          ],
                        ),
                        subtitle: Text([
                          _labelFor(field.type),
                          if (field.isBuiltIn) 'built in',
                        ].join(' · ')),
                        trailing: PopupMenuButton<String>(
                          onSelected: (choice) => switch (choice) {
                            'edit' => _editField(context, ref, field),
                            'remove' => _removeField(context, ref, field),
                            _ => null,
                          },
                          itemBuilder: (context) => [
                            const PopupMenuItem(
                                value: 'edit', child: Text('Edit')),
                            PopupMenuItem(
                              value: 'remove',
                              child: Text(field.isBuiltIn
                                  ? 'Hide from the form'
                                  : 'Remove'),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static IconData _iconFor(FormFieldType type) => switch (type) {
        FormFieldType.text => Icons.short_text,
        FormFieldType.longText => Icons.notes,
        FormFieldType.number => Icons.pin,
        FormFieldType.phone => Icons.phone_outlined,
        FormFieldType.date => Icons.event_outlined,
        FormFieldType.choice => Icons.list_alt,
      };

  static String _labelFor(FormFieldType type) => switch (type) {
        FormFieldType.text => 'Short answer',
        FormFieldType.longText => 'Long answer',
        FormFieldType.number => 'Number',
        FormFieldType.phone => 'Phone',
        FormFieldType.date => 'Date',
        FormFieldType.choice => 'Choose one',
      };

  Future<void> _addField(BuildContext context, WidgetRef ref) async {
    final result = await _fieldSheet(context: context);
    if (result == null) return;
    await ref.read(admissionFormProvider).addField(
          label: result.label,
          type: result.type,
          required: result.required,
          options: result.options,
        );
  }

  Future<void> _editField(
    BuildContext context,
    WidgetRef ref,
    AdmissionField field,
  ) async {
    final options = () {
      try {
        final raw = jsonDecode(field.optionsJson);
        return raw is List ? raw.map((o) => '$o').toList() : <String>[];
      } catch (_) {
        return <String>[];
      }
    }();

    final result = await _fieldSheet(
      context: context,
      existing: field,
      initialOptions: options,
    );
    if (result == null) return;

    await ref.read(admissionFormProvider).updateField(
          field,
          label: result.label,
          required: result.required,
          options: result.options,
        );
  }

  Future<void> _removeField(
    BuildContext context,
    WidgetRef ref,
    AdmissionField field,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(field.isBuiltIn
            ? 'Hide "${field.label}"?'
            : 'Remove "${field.label}"?'),
        content: Text(
          field.isBuiltIn
              ? 'It disappears from the form, but the student record keeps the '
                  'field and anything already stored in it.'
              : 'It disappears from the form. Answers already collected stay on '
                  'the students who gave them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(field.isBuiltIn ? 'Hide' : 'Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(admissionFormProvider).removeField(field);
  }

  Future<({String label, FormFieldType type, bool required, List<String> options})?>
      _fieldSheet({
    required BuildContext context,
    AdmissionField? existing,
    List<String> initialOptions = const [],
  }) {
    final label = TextEditingController(text: existing?.label ?? '');
    final optionsText =
        TextEditingController(text: initialOptions.join(', '));
    var type = existing?.type ?? FormFieldType.text;
    var required = existing?.isRequired ?? false;

    return showModalBottomSheet<
        ({String label, FormFieldType type, bool required, List<String> options})>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(existing == null ? 'New question' : 'Edit question',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 14),
                TextField(
                  controller: label,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'What do you want to ask?',
                    hintText: "Father's occupation",
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                if (existing?.isBuiltIn ?? false)
                  Text(
                    'This is a built-in question, so its kind cannot change — '
                    'it writes to the student record itself.',
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                else
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final option in FormFieldType.values)
                        ChoiceChip(
                          label: Text(_labelFor(option)),
                          selected: type == option,
                          onSelected: (_) => setSheet(() => type = option),
                        ),
                    ],
                  ),
                if (type == FormFieldType.choice) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: optionsText,
                    decoration: const InputDecoration(
                      labelText: 'Choices, separated by commas',
                      hintText: 'Mirpur, Uttara, Walks',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: required,
                  onChanged: (v) => setSheet(() => required = v),
                  title: const Text('Must be answered'),
                  subtitle:
                      const Text('Admission cannot be saved without it'),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: label.text.trim().isEmpty
                        ? null
                        : () => Navigator.pop(context, (
                              label: label.text.trim(),
                              type: type,
                              required: required,
                              options: optionsText.text
                                  .split(',')
                                  .map((o) => o.trim())
                                  .where((o) => o.isNotEmpty)
                                  .toList(),
                            )),
                    child: Text(existing == null ? 'Add' : 'Save'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
