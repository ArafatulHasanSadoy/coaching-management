import '../db/database.dart';
import '../db/tables.dart';
import 'document_engine.dart';

/// Builds a money receipt.
///
/// Modelled on what a Bangladeshi coaching centre already hands over on paper,
/// down to showing previous due, amount paid and remaining due together —
/// guardians read that line first, and a receipt that omits it starts an
/// argument at the counter.
class ReceiptDocument {
  const ReceiptDocument({required this.engine});

  final DocumentEngine engine;

  String build({
    required Payment payment,
    required Student student,
    String batchName = '',
    String className = '',
    int previousDue = 0,
    bool isDuplicate = false,
  }) {
    final remaining = previousDue - payment.amount;
    final body = '''
${isDuplicate ? '<div class="stamp">DUPLICATE</div>' : ''}
<div class="doc-title">MONEY RECEIPT &nbsp;/&nbsp; মানি রসিদ</div>

<table class="kv">
  <tr><td>Receipt no</td><td><b>${DocumentEngine.escape(payment.receiptNo)}</b></td>
      <td>Date</td><td>${_date(payment.receivedOn)}</td></tr>
  <tr><td>Student</td><td><b>${DocumentEngine.escape(student.name)}</b></td>
      <td>Student ID</td><td>${DocumentEngine.escape(student.code)}</td></tr>
  <tr><td>Class</td><td>${DocumentEngine.escape(className)}</td>
      <td>Batch</td><td>${DocumentEngine.escape(batchName)}</td></tr>
  ${payment.forPeriod.isEmpty ? '' : '<tr><td>For</td><td colspan="3">${DocumentEngine.escape(payment.forPeriod)}</td></tr>'}
</table>

<table class="totals">
  ${previousDue > 0 ? '<tr><td>Previous due</td><td align="right">${_taka(previousDue)}</td></tr>' : ''}
  <tr class="grand"><td>Paid now</td><td align="right">${_taka(payment.amount)}</td></tr>
  ${previousDue > 0 ? '<tr><td>Remaining due</td><td align="right">${_taka(remaining < 0 ? 0 : remaining)}</td></tr>' : ''}
  <tr><td>In words</td><td align="right">${DocumentEngine.escape(takaInWords(payment.amount))}</td></tr>
  <tr><td>Payment method</td><td align="right">${_method(payment.method)}</td></tr>
  ${payment.reference.isEmpty ? '' : '<tr><td>Reference</td><td align="right">${DocumentEngine.escape(payment.reference)}</td></tr>'}
</table>

<div class="sign">
  <div>${DocumentEngine.escape(payment.receivedBy.isEmpty ? 'Received by' : payment.receivedBy)}</div>
  <div>Authorised signature</div>
</div>
''';

    return engine.page(
      title: 'Receipt ${payment.receiptNo}',
      body: body,
      paper: PaperSize.a5,
    );
  }

  static String _taka(int amount) => '৳ ${_grouped(amount)}';

  /// Groups in the South Asian style — 1,25,000 rather than 125,000 — because
  /// that is how the number will be read aloud at the counter.
  static String _grouped(int amount) {
    final digits = amount.abs().toString();
    if (digits.length <= 3) return '${amount < 0 ? '-' : ''}$digits';

    final last3 = digits.substring(digits.length - 3);
    var rest = digits.substring(0, digits.length - 3);
    final parts = <String>[];
    while (rest.length > 2) {
      parts.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) parts.insert(0, rest);
    return '${amount < 0 ? '-' : ''}${parts.join(',')},$last3';
  }

  static String _method(PaymentMethod m) => switch (m) {
        PaymentMethod.cash => 'Cash',
        PaymentMethod.bkash => 'bKash',
        PaymentMethod.nagad => 'Nagad',
        PaymentMethod.bank => 'Bank',
        PaymentMethod.other => 'Other',
      };

  static String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';

  /// Amount in words, in the lakh/crore system a Bangladeshi receipt uses.
  static String takaInWords(int amount) {
    if (amount == 0) return 'Zero taka only';
    final buffer = StringBuffer();
    var value = amount;

    void chunk(int divisor, String label) {
      final n = value ~/ divisor;
      if (n > 0) {
        buffer.write('${_below1000(n)} $label ');
        value %= divisor;
      }
    }

    chunk(10000000, 'crore');
    chunk(100000, 'lakh');
    chunk(1000, 'thousand');
    if (value > 0) buffer.write('${_below1000(value)} ');

    final words = buffer.toString().trim();
    return '${words[0].toUpperCase()}${words.substring(1)} taka only';
  }

  static const _ones = [
    '', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine',
    'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen',
    'seventeen', 'eighteen', 'nineteen',
  ];
  static const _tens = [
    '', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy',
    'eighty', 'ninety',
  ];

  static String _below1000(int n) {
    if (n < 20) return _ones[n];
    if (n < 100) {
      final rest = n % 10;
      return '${_tens[n ~/ 10]}${rest == 0 ? '' : '-${_ones[rest]}'}';
    }
    final rest = n % 100;
    return '${_ones[n ~/ 100]} hundred${rest == 0 ? '' : ' ${_below1000(rest)}'}';
  }
}
