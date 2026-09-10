import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../core/sections.dart';
import '../../data/reports/reports_service.dart';

/// The questions an owner actually asks, each answerable in one tap.
class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  DateTimeRange _range = DateTimeRange(
    start: DateTime(DateTime.now().year, DateTime.now().month),
    end: DateTime(DateTime.now().year, DateTime.now().month + 1),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reports = ref.watch(reportsProvider);

    return Scaffold(
      appBar: const SectionAppBar(section: Section.reports, title: 'Reports'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.date_range),
              title: const Text('Period'),
              subtitle: Text('${_label(_range.start)} to '
                  '${_label(_range.end.subtract(const Duration(days: 1)))}'),
              trailing: TextButton(
                onPressed: _pickRange,
                child: const Text('Change'),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _tile(
            'Income and expenses',
            'What came in, what went out, what is left',
            () => reports.profitAndLoss(from: _range.start, to: _range.end),
          ),
          _tile(
            'Collections',
            'Every receipt in the period',
            () => reports.collections(from: _range.start, to: _range.end),
          ),
          _tile(
            'Expenses',
            'Where the money went, biggest heads first',
            () => reports.expenses(from: _range.start, to: _range.end),
          ),
          _tile(
            'Outstanding fees',
            'Who owes what, right now',
            () => reports.outstanding(),
          ),
          _tile(
            'Low attendance',
            'Students below 70% — the ones to ring',
            () => reports.lowAttendance(from: _range.start, to: _range.end),
          ),
          const SizedBox(height: 16),
          Text(
            'Every report can be printed or saved as a PDF.',
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _tile(String title, String subtitle, Future<Report> Function() build) =>
      Card(
        child: ListTile(
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            final report = await build();
            if (!mounted) return;
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => _ReportView(report: report),
              ),
            );
          },
        ),
      );

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
      initialDateRange: _range,
    );
    if (picked != null) {
      setState(() => _range = DateTimeRange(
            start: picked.start,
            end: picked.end.add(const Duration(days: 1)),
          ));
    }
  }

  static String _label(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';
}

class _ReportView extends ConsumerWidget {
  const _ReportView({required this.report});
  final Report report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: SectionAppBar(
        section: Section.reports,
        title: report.title,
        actions: [
          IconButton(
            icon: const Icon(Icons.print_outlined),
            tooltip: 'Print',
            onPressed: () async {
              final engine = ref.read(documentEngineProvider);
              final html =
                  ref.read(reportsProvider).toHtml(report, engine);
              await engine.printDocument(html, jobName: report.title);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(report.subtitle, style: theme.textTheme.bodySmall),
          ),
          if (report.totals.isNotEmpty)
            Container(
              width: double.infinity,
              color: theme.colorScheme.secondaryContainer,
              padding: const EdgeInsets.all(14),
              child: Wrap(
                spacing: 24,
                runSpacing: 6,
                children: [
                  for (final (label, value) in report.totals)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(label, style: theme.textTheme.labelSmall),
                        Text(value, style: theme.textTheme.titleMedium),
                      ],
                    ),
                ],
              ),
            ),
          Expanded(
            child: report.rows.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text('Nothing to show for this period.'),
                    ),
                  )
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SingleChildScrollView(
                      child: DataTable(
                        columns: [
                          for (final column in report.columns)
                            DataColumn(label: Text(column)),
                        ],
                        rows: [
                          for (final row in report.rows)
                            DataRow(
                              cells: [
                                for (final cell in row) DataCell(Text(cell)),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
