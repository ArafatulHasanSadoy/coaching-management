import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../app/lock_controller.dart';
import '../../core/permissions.dart';
import '../../core/sections.dart';
import '../../data/db/tables.dart';
import '../attendance/attendance_screen.dart';
import '../backup/backup_screen.dart';
import '../finance/collect_fee_screen.dart';
import '../finance/dues_screen.dart';
import '../finance/finance_screen.dart';
import '../inventory/inventory_screen.dart';
import '../master/batches_screen.dart';
import '../master/master_data_screen.dart';
import '../printing/print_centre_screen.dart';
import '../questions/question_bank_screen.dart';
import '../reports/reports_screen.dart';
import '../routine/routine_screen.dart';
import '../settings/settings_screen.dart';
import '../staff/payroll_screen.dart';
import '../staff/staff_screen.dart';
import '../students/admission_screen.dart';
import '../students/enquiries_screen.dart';
import '../students/students_screen.dart';

/// What the centre looks like today.
///
/// Assembled from what the signed-in person may do, not filtered afterwards —
/// a receptionist gets a home screen built around collecting fees and taking
/// the register, not a greyed-out list of what they are missing.
///
/// Each area carries its own colour throughout the app, so the person at the
/// desk recognises where they are before reading the title.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final institution = ref.watch(institutionProvider).value;
    final session = ref.watch(activeSessionProvider).value;
    final user = ref.watch(currentUserProvider);
    final role = user?.role ?? UserRole.staff;

    bool can(Capability c) => Permissions.allows(role, c);

    return Scaffold(
      appBar: AppBar(
        title: Text(institution?.name ?? 'Coaching Ops'),
        actions: [
          if (can(Capability.manageMasterData))
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => _go(context, const SettingsScreen()),
            ),
          IconButton(
            tooltip: 'Lock',
            icon: const Icon(Icons.lock_outline),
            onPressed: () => ref.read(lockControllerProvider.notifier).lock(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (user != null)
            Card(
              elevation: 0,
              color: Section.setup.tint(context),
              child: ListTile(
                leading: Icon(
                  role == UserRole.owner
                      ? Icons.shield_outlined
                      : Icons.badge_outlined,
                  color: Section.setup.onTint(context),
                ),
                title: Text(user.name),
                subtitle: Text(
                  role == UserRole.owner
                      ? 'Owner · full access'
                      : 'Staff · counter and register',
                ),
                trailing: session == null
                    ? null
                    : Chip(
                        label: Text(session.name),
                        visualDensity: VisualDensity.compact,
                      ),
              ),
            ),

          const SectionHeading('Today'),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1.55,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            children: [
              if (can(Capability.collectFees))
                _Tile(
                  section: Section.money,
                  label: 'Collect fee',
                  filled: true,
                  onTap: () => _go(context, const CollectFeeScreen()),
                ),
              if (can(Capability.takeAttendance))
                _Tile(
                  section: Section.attendance,
                  label: 'Attendance',
                  onTap: () => _go(context, const AttendanceScreen()),
                ),
              if (can(Capability.manageStudents))
                _Tile(
                  section: Section.students,
                  label: 'Admit',
                  icon: Icons.person_add_alt,
                  onTap: () => _go(context, const AdmissionScreen()),
                ),
              if (can(Capability.collectFees))
                _Tile(
                  section: Section.money,
                  label: 'Dues',
                  icon: Icons.receipt_long_outlined,
                  onTap: () => _go(context, const DuesScreen()),
                ),
            ],
          ),

          if (can(Capability.manageStudents)) ...[
            const SectionHeading('People', section: Section.students),
            _Group(
              section: Section.students,
              rows: [
                (
                  Icons.people_alt_outlined,
                  'Students',
                  'Class-wise, with search and import',
                  () => _go(context, const StudentsScreen()),
                ),
                (
                  Icons.contact_phone_outlined,
                  'Enquiries',
                  'People who asked but have not joined',
                  () => _go(context, const EnquiriesScreen()),
                ),
                if (can(Capability.manageMasterData))
                  (
                    Icons.groups_outlined,
                    'Batches',
                    'Groups students are admitted into',
                    () => _go(context, const BatchesScreen()),
                  ),
              ],
            ),
          ],

          if (can(Capability.manageStaff)) ...[
            const SectionHeading('Teaching', section: Section.teachers),
            _Group(
              section: Section.teachers,
              rows: [
                (
                  Icons.school_outlined,
                  'Teachers and staff',
                  'Classes taken, attendance and pay',
                  () => _go(context, const StaffScreen()),
                ),
                (
                  Icons.account_balance_outlined,
                  'Payroll',
                  'Per class and by the hour',
                  () => _go(context, const PayrollScreen()),
                ),
                (
                  Icons.grid_on_outlined,
                  'Routine',
                  'Class timetables, built for you',
                  () => _go(context, const RoutineScreen()),
                ),
              ],
            ),
          ],

          if (can(Capability.viewFinanceSummary)) ...[
            const SectionHeading('Money', section: Section.money),
            _Group(
              section: Section.money,
              rows: [
                (
                  Icons.account_balance_wallet_outlined,
                  'Finance',
                  'Accounts, expenses and closing the day',
                  () => _go(context, const FinanceScreen()),
                ),
                (
                  Icons.insights_outlined,
                  'Reports',
                  'Collections, expenses, dues, attendance',
                  () => _go(context, const ReportsScreen()),
                ),
              ],
            ),
          ],

          const SectionHeading('Paper', section: Section.questions),
          _Group(
            section: Section.questions,
            rows: [
              (
                Icons.quiz_outlined,
                'Questions and papers',
                'Scan or type, then print a proper paper',
                () => _go(context, const QuestionBankScreen()),
              ),
              (
                Icons.print_outlined,
                'Print centre',
                'Your own forms, ID cards, and what is due',
                () => _go(context, const PrintCentreScreen()),
              ),
            ],
          ),

          const SectionHeading('The centre', section: Section.setup),
          _Group(
            section: Section.setup,
            rows: [
              if (can(Capability.manageInventory))
                (
                  Icons.inventory_2_outlined,
                  'Inventory',
                  'Books, sheets, paper and toner',
                  () => _go(context, const InventoryScreen()),
                ),
              if (can(Capability.manageMasterData))
                (
                  Icons.tune,
                  'Classes, rooms and times',
                  'What the routine builder works from',
                  () => _go(context, const MasterDataScreen()),
                ),
              if (can(Capability.manageBackup))
                (
                  Icons.backup_outlined,
                  'Backup',
                  'Protect against losing this phone',
                  () => _go(context, const BackupScreen()),
                ),
            ],
          ),

          const SizedBox(height: 20),
          Center(
            child: Text(
              'Works entirely offline',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
        ],
      ),
    );
  }

  void _go(BuildContext context, Widget screen) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => screen));
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.section,
    required this.label,
    required this.onTap,
    this.icon,
    this.filled = false,
  });

  final Section section;
  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: filled ? section.band(context) : section.tint(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: section.colour.withValues(alpha: 0.22)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon ?? section.icon,
                size: 26, color: section.onTint(context)),
            const SizedBox(height: 8),
            Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: section.onTint(context),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.section, required this.rows});

  final Section section;
  final List<(IconData, String, String, VoidCallback)> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: section.colour.withValues(alpha: 0.20)),
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            ListTile(
              leading: CircleAvatar(
                radius: 18,
                backgroundColor: section.tint(context),
                child: Icon(rows[i].$1,
                    size: 19, color: section.onTint(context)),
              ),
              title: Text(rows[i].$2),
              subtitle: Text(rows[i].$3),
              trailing: const Icon(Icons.chevron_right),
              onTap: rows[i].$4,
            ),
            if (i < rows.length - 1) const Divider(height: 1, indent: 68),
          ],
        ],
      ),
    );
  }
}
