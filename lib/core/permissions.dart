import '../data/db/tables.dart';

/// Things a signed-in user might be allowed to do.
enum Capability {
  /// Income, expenses, profit — the numbers that say how the business is doing.
  viewFinanceSummary,

  /// Taking money at the counter and printing a receipt.
  collectFees,

  /// Recording what the centre spent.
  manageExpenses,

  /// What teachers are paid.
  viewStaffSalaries,
  manageStaff,
  manageStudents,
  takeAttendance,
  manageInventory,
  manageMasterData,
  manageBackup,
  viewReports,
}

/// Who can do what.
///
/// The distinction that matters is not "admin versus user" but a specific one:
/// the receptionist collecting fees is trusted with the cash box and is not
/// trusted with the profit figures or with what each teacher earns. Those are
/// the owner's business, and on a shared counter phone the difference has to be
/// enforced rather than assumed.
abstract final class Permissions {
  static bool allows(UserRole role, Capability capability) => switch (role) {
        UserRole.owner => true,
        UserRole.staff => switch (capability) {
            // Everything the front desk actually does.
            Capability.collectFees ||
            Capability.manageStudents ||
            Capability.takeAttendance ||
            Capability.manageInventory =>
              true,

            // Deliberately withheld: money in aggregate, salaries, expenses,
            // the structure of the centre, and its backups.
            Capability.viewFinanceSummary ||
            Capability.manageExpenses ||
            Capability.viewStaffSalaries ||
            Capability.manageStaff ||
            Capability.manageMasterData ||
            Capability.manageBackup ||
            Capability.viewReports =>
              false,
          },
      };

  /// Capabilities a role has, for building a menu.
  static Set<Capability> grantedTo(UserRole role) =>
      {for (final c in Capability.values) if (allows(role, c)) c};
}
