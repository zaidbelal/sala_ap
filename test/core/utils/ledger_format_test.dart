import 'package:flutter_test/flutter_test.dart';
import 'package:wissal/features/merchant/ledger/models/ledger_customer.dart';
import 'package:wissal/features/merchant/ledger/services/ledger_pdf_service.dart';

void main() {
  group('LedgerPdfService Date & Time Formatting', () {
    test('formats 12-hour PM time correctly after 12 (13:15 -> 01:15 م)', () {
      final dt = DateTime(2026, 11, 21, 13, 15);
      final formatted = LedgerPdfService.formatArabicTime12(dt);
      expect(formatted, '01:15 م');
    });

    test('formats midday 12:00 PM correctly (12:00 م)', () {
      final dt = DateTime(2026, 11, 21, 12, 0);
      final formatted = LedgerPdfService.formatArabicTime12(dt);
      expect(formatted, '12:00 م');
    });

    test('formats midnight 00:30 correctly (12:30 ص)', () {
      final dt = DateTime(2026, 11, 21, 0, 30);
      final formatted = LedgerPdfService.formatArabicTime12(dt);
      expect(formatted, '12:30 ص');
    });

    test('formats morning 09:05 AM correctly (09:05 ص)', () {
      final dt = DateTime(2026, 11, 21, 9, 5);
      final formatted = LedgerPdfService.formatArabicTime12(dt);
      expect(formatted, '09:05 ص');
    });

    test('formats Arabic days correctly', () {
      final saturday = DateTime(2026, 11, 21); // السبت
      expect(LedgerPdfService.formatArabicDay(saturday), 'السبت');
    });

    test('formats full date and time string correctly', () {
      final dt = DateTime(2026, 11, 21, 14, 45);
      final fullStr = LedgerPdfService.formatFullDateTime(dt);
      expect(fullStr, 'السبت 2026/11/21 - 02:45 م');
    });
  });

  group('LedgerCustomer Credit Limit & Financial Safety', () {
    test('calculates credit limit usage and remaining credit accurately', () {
      const customer = LedgerCustomer(
        id: 'cust_1',
        merchantId: 'merchant_1',
        name: 'أحمد صالح',
        creditLimit: 50000,
        currentBalance: 35000,
      );

      expect(customer.remainingCredit, 15000);
      expect(customer.isOverLimit, false);
      expect(customer.creditUsageRatio, 0.7);
    });

    test('detects when customer exceeds credit limit', () {
      const customer = LedgerCustomer(
        id: 'cust_2',
        merchantId: 'merchant_1',
        name: 'محمد علي',
        creditLimit: 20000,
        currentBalance: 25000,
      );

      expect(customer.remainingCredit, 0);
      expect(customer.isOverLimit, true);
      expect(customer.creditUsageRatio, 1.25);
    });

    test('handles open credit limit (creditLimit <= 0) safely', () {
      const customer = LedgerCustomer(
        id: 'cust_3',
        merchantId: 'merchant_1',
        name: 'خالد عمر',
        creditLimit: 0,
        currentBalance: 12000,
      );

      expect(customer.remainingCredit, 0);
      expect(customer.isOverLimit, false);
      expect(customer.creditUsageRatio, 0.0);
    });
  });
}
