import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../core/sections.dart';
import '../../data/defaults/curriculum_defaults.dart';
import '../../data/setup/setup_service.dart';

/// Guided first configuration of a centre.
///
/// Four short steps, each answerable without training, and every default chosen
/// so that an owner who taps through without changing anything still ends up
/// with a working centre. The alternative — an empty database and a menu of
/// CRUD screens — is where products like this lose people in the first ten
/// minutes.
class SetupWizard extends ConsumerStatefulWidget {
  const SetupWizard({super.key});

  @override
  ConsumerState<SetupWizard> createState() => _SetupWizardState();
}

class _SetupWizardState extends ConsumerState<SetupWizard> {
  final _controller = PageController();
  int _step = 0;

  final _name = TextEditingController();
  final _address = TextEditingController();
  final _phone = TextEditingController();

  late final _sessionName =
      TextEditingController(text: '${DateTime.now().year}');
  late DateTime _sessionStart = DateTime(DateTime.now().year, 1, 1);
  late DateTime _sessionEnd = DateTime(DateTime.now().year, 12, 31);

  final _selected = <DefaultClass>{};
  bool _banglaNames = true;
  bool _wantRooms = true;
  bool _wantSlots = true;

  bool _busy = false;
  String? _error;

  static const _stepCount = 4;

  @override
  void dispose() {
    _controller.dispose();
    _name.dispose();
    _address.dispose();
    _phone.dispose();
    _sessionName.dispose();
    super.dispose();
  }

  int get _subjectCount =>
      _selected.fold(0, (sum, c) => sum + c.subjects.length);

  bool get _canAdvance => switch (_step) {
        0 => _name.text.trim().isNotEmpty,
        1 => _sessionName.text.trim().isNotEmpty &&
            _sessionEnd.isAfter(_sessionStart),
        2 => _selected.isNotEmpty,
        _ => true,
      };

  void _next() {
    if (_step < _stepCount - 1) {
      setState(() => _step++);
      _controller.animateToPage(
        _step,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    } else {
      _finish();
    }
  }

  void _back() {
    if (_step == 0) return;
    setState(() => _step--);
    _controller.animateToPage(
      _step,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  Future<void> _finish() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final state = ref.read(bootstrapProvider).value! as BootstrapReady;
      // Order the selection the way the catalogue lists it, so a centre's
      // classes read in a sensible order rather than in tap order.
      final ordered =
          defaultClasses.where(_selected.contains).toList(growable: false);

      await ref.read(setupServiceProvider).apply(
            db: state.database,
            deviceId: state.deviceId,
            plan: SetupPlan(
              centreName: _name.text.trim(),
              address: _address.text.trim(),
              phone: _phone.text.trim(),
              sessionName: _sessionName.text.trim(),
              sessionStart: _sessionStart,
              sessionEnd: _sessionEnd,
              selectedClasses: ordered,
              banglaSubjectNames: _banglaNames,
              includeDefaultRooms: _wantRooms,
              includeDefaultTimeSlots: _wantSlots,
            ),
          );
      ref.invalidate(bootstrapProvider);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: SectionAppBar(
        section: Section.setup,
        title: 'Set up — step ${_step + 1} of $_stepCount',
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(value: (_step + 1) / _stepCount),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView(
              controller: _controller,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _profileStep(theme),
                _sessionStep(theme),
                _classesStep(theme),
                _finishStep(theme),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(_error!,
                  style: TextStyle(color: theme.colorScheme.error)),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  if (_step > 0)
                    TextButton(onPressed: _busy ? null : _back, child: const Text('Back')),
                  const Spacer(),
                  FilledButton(
                    onPressed: _busy || !_canAdvance ? null : _next,
                    child: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_step == _stepCount - 1 ? 'Create centre' : 'Next'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _profileStep(ThemeData theme) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Your centre', style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            'This appears on receipts, question papers and reports.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Centre name',
              hintText: 'Advance Educare',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _address,
            decoration: const InputDecoration(
              labelText: 'Address (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Phone (optional)',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      );

  Widget _sessionStep(ThemeData theme) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Academic session', style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            'Keeps this year’s students, fees and attendance separate from '
            'next year’s. At year end you promote batches instead of '
            'starting over.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _sessionName,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Session name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Starts'),
            trailing: Text(_dateLabel(_sessionStart)),
            onTap: () => _pickDate(
              initial: _sessionStart,
              onPicked: (d) => setState(() => _sessionStart = d),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Ends'),
            trailing: Text(_dateLabel(_sessionEnd)),
            onTap: () => _pickDate(
              initial: _sessionEnd,
              onPicked: (d) => setState(() => _sessionEnd = d),
            ),
          ),
        ],
      );

  Widget _classesStep(ThemeData theme) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('What do you teach?', style: theme.textTheme.titleLarge),
                const SizedBox(height: 6),
                Text(
                  'Subjects come with each class and can be changed later.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('বাংলা names')),
                    ButtonSegment(value: false, label: Text('English names')),
                  ],
                  selected: {_banglaNames},
                  onSelectionChanged: (v) =>
                      setState(() => _banglaNames = v.first),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: defaultClasses.length,
              itemBuilder: (context, i) {
                final item = defaultClasses[i];
                return CheckboxListTile(
                  value: _selected.contains(item),
                  onChanged: (on) => setState(() {
                    on ?? false ? _selected.add(item) : _selected.remove(item);
                  }),
                  title: Text(item.label),
                  subtitle: Text('${item.subjects.length} subjects'),
                );
              },
            ),
          ),
          if (_selected.isNotEmpty)
            Container(
              width: double.infinity,
              color: theme.colorScheme.secondaryContainer,
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
              child: Text(
                '${_selected.length} class(es) · $_subjectCount subjects',
                style: theme.textTheme.labelLarge,
              ),
            ),
        ],
      );

  Widget _finishStep(ThemeData theme) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Almost done', style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                ListTile(
                  dense: true,
                  title: const Text('Centre'),
                  trailing: Text(_name.text.trim()),
                ),
                ListTile(
                  dense: true,
                  title: const Text('Session'),
                  trailing: Text(_sessionName.text.trim()),
                ),
                ListTile(
                  dense: true,
                  title: const Text('Classes'),
                  trailing: Text('${_selected.length}'),
                ),
                ListTile(
                  dense: true,
                  title: const Text('Subjects'),
                  trailing: Text('$_subjectCount'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            value: _wantRooms,
            onChanged: (v) => setState(() => _wantRooms = v),
            title: const Text('Add two example rooms'),
            subtitle: const Text(
              'The routine builder needs rooms. Edit or add more later.',
            ),
          ),
          SwitchListTile(
            value: _wantSlots,
            onChanged: (v) => setState(() => _wantSlots = v),
            title: const Text('Add typical class times'),
            subtitle: const Text('3:00 PM to 8:15 PM, five one-hour periods.'),
          ),
        ],
      );

  Future<void> _pickDate({
    required DateTime initial,
    required ValueChanged<DateTime> onPicked,
  }) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(initial.year - 5),
      lastDate: DateTime(initial.year + 5),
    );
    if (picked != null) onPicked(picked);
  }

  static String _dateLabel(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';
}
