import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

class RoadHazardReportEvent {
  final String id;
  final String label;
  final double confidence;
  final DateTime timestamp;
  final Duration? videoOffset;
  final double? latitude;
  final double? longitude;
  final double? speedKmh;
  final String? notes;
  final Uint8List? photoBytes;

  const RoadHazardReportEvent({
    required this.id,
    required this.label,
    required this.confidence,
    required this.timestamp,
    this.videoOffset,
    this.latitude,
    this.longitude,
    this.speedKmh,
    this.notes,
    this.photoBytes,
  });
}

class RoadHazardReport {
  final String sessionCode;
  final String siteName;
  final String inspectorName;
  final String roadSection;
  final DateTime startTime;
  final DateTime endTime;
  final int durationSeconds;
  final double distanceMeters;
  final int potholesCount;
  final int corrugationCount;
  final int rutsCount;
  final String severity;
  final String? summaryNotes;
  final List<RoadHazardReportEvent> events;

  const RoadHazardReport({
    required this.sessionCode,
    required this.siteName,
    required this.inspectorName,
    required this.roadSection,
    required this.startTime,
    required this.endTime,
    required this.durationSeconds,
    required this.distanceMeters,
    required this.potholesCount,
    required this.corrugationCount,
    required this.rutsCount,
    required this.severity,
    this.summaryNotes,
    required this.events,
  });
}

class RoadHazardReportExporter {
  static const _header = 'HERO ROAD HAZARD FIELD REPORT';

  String _duration(int seconds) {
    final d = Duration(seconds: seconds < 0 ? 0 : seconds);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return h > 0 ? '${h}h ${m}m ${s}s' : '${m}m ${s}s';
  }

  String _two(int value) => value.toString().padLeft(2, '0');

  String _formatTimestamp(DateTime dt) {
    final local = dt.toLocal();
    return '${local.year}-${_two(local.month)}-${_two(local.day)} '
        '${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}';
  }

  String _formatOffset(Duration offset) {
    final safe = offset.isNegative ? Duration.zero : offset;
    final h = safe.inHours;
    final m = safe.inMinutes.remainder(60);
    final s = safe.inSeconds.remainder(60);
    return '${_two(h)}:${_two(m)}:${_two(s)}';
  }

  Uint8List toXlsx(RoadHazardReport report) {
    final book = Excel.createExcel();
    final sheet = book['Road Hazard'];
    final rows = <List<CellValue?>>[
      [TextCellValue(_header)],
      [TextCellValue('Session'), TextCellValue(report.sessionCode)],
      [TextCellValue('Site'), TextCellValue(report.siteName)],
      [TextCellValue('Inspector'), TextCellValue(report.inspectorName)],
      [TextCellValue('Road section'), TextCellValue(report.roadSection)],
      [
        TextCellValue('Start'),
        TextCellValue(_formatTimestamp(report.startTime)),
      ],
      [TextCellValue('End'), TextCellValue(_formatTimestamp(report.endTime))],
      [
        TextCellValue('Duration'),
        TextCellValue(_duration(report.durationSeconds)),
      ],
      [TextCellValue('Distance (m)'), DoubleCellValue(report.distanceMeters)],
      [TextCellValue('Severity'), TextCellValue(report.severity)],
      [TextCellValue('Total hazards'), IntCellValue(report.events.length)],
      [TextCellValue('Potholes'), IntCellValue(report.potholesCount)],
      [TextCellValue('Corrugation'), IntCellValue(report.corrugationCount)],
      [TextCellValue('Ruts'), IntCellValue(report.rutsCount)],
      [TextCellValue('Summary'), TextCellValue(report.summaryNotes ?? '')],
      [],
      [
        TextCellValue('ID'),
        TextCellValue('Hazard'),
        TextCellValue('Confidence'),
        TextCellValue('Timestamp'),
        TextCellValue('Video Offset'),
        TextCellValue('Latitude'),
        TextCellValue('Longitude'),
        TextCellValue('Speed km/h'),
        TextCellValue('Notes'),
        TextCellValue('Photo'),
      ],
    ];
    for (final event in report.events) {
      rows.add([
        TextCellValue(event.id),
        TextCellValue(event.label),
        DoubleCellValue(event.confidence.clamp(0, 1).toDouble()),
        TextCellValue(_formatTimestamp(event.timestamp)),
        TextCellValue(
          event.videoOffset == null ? '' : _formatOffset(event.videoOffset!),
        ),
        event.latitude == null ? null : DoubleCellValue(event.latitude!),
        event.longitude == null ? null : DoubleCellValue(event.longitude!),
        event.speedKmh == null ? null : DoubleCellValue(event.speedKmh!),
        TextCellValue(event.notes ?? ''),
        TextCellValue(event.photoBytes == null ? '' : 'Included in PDF'),
      ]);
    }
    for (var row = 0; row < rows.length; row++) {
      for (var col = 0; col < rows[row].length; col++) {
        final value = rows[row][col];
        if (value != null) {
          sheet
                  .cell(
                    CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row),
                  )
                  .value =
              value;
        }
      }
    }
    final bytes = book.encode();
    if (bytes == null || bytes.isEmpty) {
      throw StateError('XLSX export returned no bytes.');
    }
    return Uint8List.fromList(bytes);
  }

  Future<Uint8List> toPdf(RoadHazardReport report) async {
    final document = pw.Document();
    final severityColor = switch (report.severity.toUpperCase()) {
      'CRITICAL' => PdfColors.red700,
      'HIGH' => PdfColors.deepOrange700,
      'MEDIUM' => PdfColors.amber800,
      _ => PdfColors.green700,
    };
    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        header: (_) => pw.Container(
          padding: const pw.EdgeInsets.fromLTRB(14, 12, 14, 10),
          decoration: const pw.BoxDecoration(
            color: PdfColor.fromInt(0xff0f172a),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                _header,
                style: pw.TextStyle(
                  color: PdfColors.white,
                  fontSize: 13,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                'Session ${report.sessionCode}',
                style: const pw.TextStyle(
                  color: PdfColor.fromInt(0xffcbd5e1),
                  fontSize: 9,
                ),
              ),
            ],
          ),
        ),
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            'Page ${context.pageNumber} / ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
        ),
        build: (_) => [
          pw.SizedBox(height: 14),
          pw.Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _badge('SITE', report.siteName),
              _badge('INSPECTOR', report.inspectorName),
              _badge('ROAD SECTION', report.roadSection),
              _badge('SEVERITY', report.severity, color: severityColor),
              _badge('START', _formatTimestamp(report.startTime)),
              _badge('DURATION', _duration(report.durationSeconds)),
              _badge(
                'DISTANCE',
                '${report.distanceMeters.toStringAsFixed(0)} m',
              ),
            ],
          ),
          pw.SizedBox(height: 14),
          pw.Row(
            children: [
              _kpi('TOTAL', report.events.length, PdfColors.blue700),
              _kpi('POTHOLES', report.potholesCount, PdfColors.red700),
              _kpi('CORRUGATION', report.corrugationCount, PdfColors.orange700),
              _kpi('RUTS', report.rutsCount, PdfColors.amber800),
            ],
          ),
          if ((report.summaryNotes ?? '').trim().isNotEmpty) ...[
            pw.SizedBox(height: 12),
            pw.Text(
              'Summary and recommendations',
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              report.summaryNotes!.trim(),
              style: const pw.TextStyle(fontSize: 9),
            ),
          ],
          pw.SizedBox(height: 14),
          pw.Text(
            'Hazard events (${report.events.length})',
            style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          if (report.events.isEmpty)
            pw.Text(
              'No hazards were recorded for this inspection.',
              style: const pw.TextStyle(fontSize: 9),
            )
          else
            ...report.events.map(_eventCard),
        ],
      ),
    );
    return Uint8List.fromList(await document.save());
  }

  pw.Widget _badge(
    String label,
    String value, {
    PdfColor color = PdfColors.blueGrey700,
  }) => pw.Container(
    width: 245,
    padding: const pw.EdgeInsets.all(8),
    decoration: pw.BoxDecoration(
      color: PdfColors.grey100,
      border: pw.Border.all(color: PdfColors.grey300),
      borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          label,
          style: pw.TextStyle(
            fontSize: 7,
            color: color,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        pw.SizedBox(height: 3),
        pw.Text(value, style: const pw.TextStyle(fontSize: 9)),
      ],
    ),
  );

  pw.Widget _kpi(String label, int value, PdfColor color) => pw.Expanded(
    child: pw.Container(
      margin: const pw.EdgeInsets.only(right: 5),
      padding: const pw.EdgeInsets.symmetric(vertical: 10, horizontal: 5),
      decoration: pw.BoxDecoration(
        color: PdfColors.grey100,
        border: pw.Border.all(color: color),
      ),
      child: pw.Column(
        children: [
          pw.Text(
            label,
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(
              fontSize: 7,
              color: color,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            '$value',
            style: pw.TextStyle(
              fontSize: 15,
              color: color,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        ],
      ),
    ),
  );

  pw.Widget _eventCard(RoadHazardReportEvent event) {
    final image = event.photoBytes == null
        ? null
        : pw.MemoryImage(event.photoBytes!);
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 8),
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey300),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          if (image != null)
            pw.Container(
              width: 90,
              height: 66,
              margin: const pw.EdgeInsets.only(right: 8),
              child: pw.Image(image, fit: pw.BoxFit.cover),
            ),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  '${event.id} · ${event.label} · ${(event.confidence * 100).toStringAsFixed(0)}%',
                  style: pw.TextStyle(
                    fontSize: 10,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.SizedBox(height: 3),
                pw.Text(
                  event.videoOffset == null
                      ? _formatTimestamp(event.timestamp)
                      : '${_formatTimestamp(event.timestamp)} · Offset ${_formatOffset(event.videoOffset!)}',
                  style: const pw.TextStyle(
                    fontSize: 8,
                    color: PdfColors.grey700,
                  ),
                ),
                pw.Text(
                  event.latitude == null || event.longitude == null
                      ? 'GPS unavailable'
                      : 'GPS: ${event.latitude}, ${event.longitude}',
                  style: const pw.TextStyle(fontSize: 8),
                ),
                if (event.speedKmh != null)
                  pw.Text(
                    'Speed: ${event.speedKmh!.toStringAsFixed(1)} km/h',
                    style: const pw.TextStyle(fontSize: 8),
                  ),
                if ((event.notes ?? '').trim().isNotEmpty)
                  pw.Text(
                    'Note: ${event.notes!.trim()}',
                    style: const pw.TextStyle(fontSize: 8),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
