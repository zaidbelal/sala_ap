import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../../../../core/services/local_storage.dart';
import '../models/ledger_customer.dart';
import '../models/ledger_entry.dart';

class LedgerPdfService {
  /// تحويل اليوم إلى اللغة العربية
  static String formatArabicDay(DateTime dt) {
    switch (dt.weekday) {
      case DateTime.saturday:
        return 'السبت';
      case DateTime.sunday:
        return 'الأحد';
      case DateTime.monday:
        return 'الإثنين';
      case DateTime.tuesday:
        return 'الثلاثاء';
      case DateTime.wednesday:
        return 'الأربعاء';
      case DateTime.thursday:
        return 'الخميس';
      case DateTime.friday:
        return 'الجمعة';
      default:
        return '';
    }
  }

  /// تنسيق التاريخ بصيغة YYYY/MM/DD
  static String formatArabicDate(DateTime dt) {
    return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}';
  }

  /// تنسيق الوقت بنظام 12 ساعة (بعد 12 تظهر 01:00 م بدلاً من 13:00)
  static String formatArabicTime12(DateTime dt) {
    int hour = dt.hour;
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = hour >= 12 ? 'م' : 'ص';

    if (hour == 0) {
      hour = 12;
    } else if (hour > 12) {
      hour -= 12;
    }

    final hourStr = hour.toString().padLeft(2, '0');
    return '$hourStr:$minute $period';
  }

  /// تنسيق كامل للتاريخ والوقت: اليوم التاريخ - الوقت
  static String formatFullDateTime(DateTime dt) {
    return '${formatArabicDay(dt)} ${formatArabicDate(dt)} - ${formatArabicTime12(dt)}';
  }

  /// توليد وثيقة كشف الحساب الرسمية بصيغة PDF
  static Future<Uint8List> generateStatementPdf({
    required LedgerCustomer customer,
    required List<LedgerEntry> entries,
    String? storeName,
    String? storePhone,
  }) async {
    final pdf = pw.Document();

    // تحميل خط Cairo العربي المدمج في المشروع
    final fontRegularData = await rootBundle.load('assets/fonts/Cairo-Regular.ttf');
    final fontBoldData = await rootBundle.load('assets/fonts/Cairo-Bold.ttf');
    final ttfRegular = pw.Font.ttf(fontRegularData);
    final ttfBold = pw.Font.ttf(fontBoldData);

    final merchantName = storeName ?? AppStorage.userName ?? 'متجر البقالة';
    final merchantPhone = storePhone ?? AppStorage.userPhone ?? '';
    final now = DateTime.now();

    // حساب المجاميع
    double totalDebts = 0;
    double totalPayments = 0;
    for (final e in entries) {
      if (e.isVoided) continue;
      if (e.isDebt) totalDebts += e.amount;
      if (e.isPayment) totalPayments += e.amount;
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        theme: pw.ThemeData.withFont(
          base: ttfRegular,
          bold: ttfBold,
        ),
        textDirection: pw.TextDirection.rtl,
        build: (context) => [
          // ══ Header ══
          pw.Container(
            padding: const pw.EdgeInsets.all(16),
            decoration: pw.BoxDecoration(
              color: PdfColors.blueGrey50,
              borderRadius: pw.BorderRadius.circular(10),
              border: pw.Border.all(color: PdfColors.blueGrey200, width: 0.8),
            ),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      merchantName,
                      style: pw.TextStyle(
                        font: ttfBold,
                        fontSize: 18,
                        color: PdfColors.blueGrey900,
                      ),
                    ),
                    pw.SizedBox(height: 4),
                    pw.Text(
                      'سجل حسابات العملاء والديون الآجلة',
                      style: pw.TextStyle(font: ttfRegular, fontSize: 11, color: PdfColors.grey700),
                    ),
                    if (merchantPhone.isNotEmpty) ...[
                      pw.SizedBox(height: 2),
                      pw.Text(
                        'هاتف المتجر: $merchantPhone',
                        style: pw.TextStyle(font: ttfRegular, fontSize: 10, color: PdfColors.grey700),
                      ),
                    ],
                  ],
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Container(
                      padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: pw.BoxDecoration(
                        color: PdfColors.blue800,
                        borderRadius: pw.BorderRadius.circular(6),
                      ),
                      child: pw.Text(
                        'كشف حساب تفصيلي',
                        style: pw.TextStyle(font: ttfBold, fontSize: 12, color: PdfColors.white),
                      ),
                    ),
                    pw.SizedBox(height: 6),
                    pw.Text(
                      'تاريخ الاستخراج:',
                      style: pw.TextStyle(font: ttfBold, fontSize: 9, color: PdfColors.grey700),
                    ),
                    pw.Text(
                      formatFullDateTime(now),
                      style: pw.TextStyle(font: ttfRegular, fontSize: 9, color: PdfColors.black),
                    ),
                  ],
                ),
              ],
            ),
          ),

          pw.SizedBox(height: 14),

          // ══ بيانات العميل ══
          pw.Container(
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.grey300),
              borderRadius: pw.BorderRadius.circular(8),
            ),
            child: pw.Row(
              children: [
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.RichText(
                        text: pw.TextSpan(
                          children: [
                            pw.TextSpan(
                              text: 'اسم العميل: ',
                              style: pw.TextStyle(font: ttfBold, fontSize: 11, color: PdfColors.grey800),
                            ),
                            pw.TextSpan(
                              text: customer.name,
                              style: pw.TextStyle(font: ttfBold, fontSize: 12, color: PdfColors.black),
                            ),
                          ],
                        ),
                      ),
                      pw.SizedBox(height: 4),
                      pw.RichText(
                        text: pw.TextSpan(
                          children: [
                            pw.TextSpan(
                              text: 'رقم الهاتف: ',
                              style: pw.TextStyle(font: ttfRegular, fontSize: 10, color: PdfColors.grey700),
                            ),
                            pw.TextSpan(
                              text: customer.phone.isNotEmpty ? customer.phone : 'غير مسجل',
                              style: pw.TextStyle(font: ttfRegular, fontSize: 10, color: PdfColors.black),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                pw.Container(width: 1, height: 40, color: PdfColors.grey300),
                pw.SizedBox(width: 14),
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.RichText(
                        text: pw.TextSpan(
                          children: [
                            pw.TextSpan(
                              text: 'سقف الدين المحدد: ',
                              style: pw.TextStyle(font: ttfRegular, fontSize: 10, color: PdfColors.grey700),
                            ),
                            pw.TextSpan(
                              text: customer.creditLimit > 0
                                  ? '${customer.creditLimit.toStringAsFixed(0)} ريال'
                                  : 'مفتوح (بدون سقف)',
                              style: pw.TextStyle(font: ttfBold, fontSize: 10, color: PdfColors.black),
                            ),
                          ],
                        ),
                      ),
                      pw.SizedBox(height: 4),
                      pw.RichText(
                        text: pw.TextSpan(
                          children: [
                            pw.TextSpan(
                              text: 'الرصيد المتبقي للدفع: ',
                              style: pw.TextStyle(font: ttfBold, fontSize: 11, color: PdfColors.red800),
                            ),
                            pw.TextSpan(
                              text: '${customer.currentBalance.toStringAsFixed(0)} ريال',
                              style: pw.TextStyle(font: ttfBold, fontSize: 13, color: PdfColors.red900),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          pw.SizedBox(height: 14),

          // ══ بطاقات الإحصاءات السريعة ══
          pw.Row(
            children: [
              pw.Expanded(
                child: _buildSummaryBox(
                  title: 'إجمالي المشتريات الآجلة',
                  value: '${totalDebts.toStringAsFixed(0)} ريال',
                  ttfBold: ttfBold,
                  ttfRegular: ttfRegular,
                  color: PdfColors.orange50,
                  textColor: PdfColors.deepOrange900,
                ),
              ),
              pw.SizedBox(width: 8),
              pw.Expanded(
                child: _buildSummaryBox(
                  title: 'إجمالي السداد النقدي',
                  value: '${totalPayments.toStringAsFixed(0)} ريال',
                  ttfBold: ttfBold,
                  ttfRegular: ttfRegular,
                  color: PdfColors.green50,
                  textColor: PdfColors.green900,
                ),
              ),
              pw.SizedBox(width: 8),
              pw.Expanded(
                child: _buildSummaryBox(
                  title: 'المبلغ المتبقي حالياً',
                  value: '${customer.currentBalance.toStringAsFixed(0)} ريال',
                  ttfBold: ttfBold,
                  ttfRegular: ttfRegular,
                  color: customer.isOverLimit ? PdfColors.red50 : PdfColors.blue50,
                  textColor: customer.isOverLimit ? PdfColors.red900 : PdfColors.blue900,
                ),
              ),
            ],
          ),

          pw.SizedBox(height: 16),

          // ══ جدول الحركات التفصيلي ══
          pw.Text(
            'سجل الحركات المالية المفصل:',
            style: pw.TextStyle(font: ttfBold, fontSize: 12, color: PdfColors.blueGrey900),
          ),
          pw.SizedBox(height: 6),

          pw.TableHelper.fromTextArray(
            border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
            headerStyle: pw.TextStyle(font: ttfBold, fontSize: 9, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey800),
            cellStyle: pw.TextStyle(font: ttfRegular, fontSize: 8.5),
            cellAlignment: pw.Alignment.center,
            columnWidths: {
              0: const pw.FlexColumnWidth(0.6), // #
              1: const pw.FlexColumnWidth(2.3), // التاريخ والوقت
              2: const pw.FlexColumnWidth(1.2), // نوع الحركة
              3: const pw.FlexColumnWidth(3.2), // البيان والأصناف
              4: const pw.FlexColumnWidth(1.3), // مدين
              5: const pw.FlexColumnWidth(1.3), // دائن
              6: const pw.FlexColumnWidth(1.4), // الرصيد بعد الحركة
            },
            headers: [
              '#',
              'اليوم والتاريخ والوقت',
              'نوع القيد',
              'البيان وتفاصيل الأصناف بالحبة',
              'مدين (+)',
              'دائن (-)',
              'الرصيد',
            ],
            data: List.generate(entries.length, (index) {
              final entry = entries[index];
              final dateStr = entry.createdAt != null
                  ? formatFullDateTime(entry.createdAt!)
                  : '-';

              String details = entry.notes;
              if (entry.items.isNotEmpty) {
                final itemsDesc = entry.items.map((i) {
                  return '${i.name} (${i.quantity.toStringAsFixed(0)} حبة × ${i.unitPrice.toStringAsFixed(0)})';
                }).join(' + ');
                details = details.isNotEmpty ? '$itemsDesc | $details' : itemsDesc;
              }
              if (details.isEmpty) {
                details = entry.isDebt ? 'مشتريات آجل' : 'دفعة نقدية كاش';
              }

              if (entry.isVoided) {
                details = '[ملغي] $details';
              }

              return [
                '${index + 1}',
                dateStr,
                entry.typeLabel,
                details,
                entry.isDebt && !entry.isVoided ? '${entry.amount.toStringAsFixed(0)}' : '-',
                entry.isPayment && !entry.isVoided ? '${entry.amount.toStringAsFixed(0)}' : '-',
                entry.isVoided ? 'قيد ملغي' : '${entry.balanceAfter.toStringAsFixed(0)} ريال',
              ];
            }),
          ),

          pw.SizedBox(height: 24),

          // ══ قسم التوقيعات ══
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Text('توقيع العميل / المقر بالدين', style: pw.TextStyle(font: ttfBold, fontSize: 10)),
                  pw.SizedBox(height: 30),
                  pw.Container(width: 140, height: 1, color: PdfColors.black),
                ],
              ),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Text('ختم وتوقيع إدارة المتجر', style: pw.TextStyle(font: ttfBold, fontSize: 10)),
                  pw.SizedBox(height: 30),
                  pw.Container(width: 140, height: 1, color: PdfColors.black),
                ],
              ),
            ],
          ),

          pw.SizedBox(height: 20),

          // ══ Footer ══
          pw.Divider(color: PdfColors.grey300),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'تم إصدار هذا الكشف عبر نظام وصال الذكي لإدارة التوزيع والتجزئة',
                style: pw.TextStyle(font: ttfRegular, fontSize: 8, color: PdfColors.grey600),
              ),
              pw.Text(
                'صفحة 1 من 1',
                style: pw.TextStyle(font: ttfRegular, fontSize: 8, color: PdfColors.grey600),
              ),
            ],
          ),
        ],
      ),
    );

    return pdf.save();
  }

  static pw.Widget _buildSummaryBox({
    required String title,
    required String value,
    required pw.Font ttfBold,
    required pw.Font ttfRegular,
    required PdfColor color,
    required PdfColor textColor,
  }) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      decoration: pw.BoxDecoration(
        color: color,
        borderRadius: pw.BorderRadius.circular(6),
        border: pw.Border.all(color: textColor, width: 0.5),
      ),
      child: pw.Column(
        children: [
          pw.Text(title, style: pw.TextStyle(font: ttfRegular, fontSize: 8.5, color: PdfColors.grey800)),
          pw.SizedBox(height: 2),
          pw.Text(value, style: pw.TextStyle(font: ttfBold, fontSize: 11, color: textColor)),
        ],
      ),
    );
  }

  /// معاينة أو طباعة كشف الحساب مباشرة
  static Future<void> printOrShareStatement({
    required LedgerCustomer customer,
    required List<LedgerEntry> entries,
    String? storeName,
    String? storePhone,
  }) async {
    final pdfBytes = await generateStatementPdf(
      customer: customer,
      entries: entries,
      storeName: storeName,
      storePhone: storePhone,
    );

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdfBytes,
      name: 'كشف_حساب_${customer.name}_${formatArabicDate(DateTime.now()).replaceAll('/', '-')}',
    );
  }
}
