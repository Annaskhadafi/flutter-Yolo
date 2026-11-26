import 'dart:convert';
import 'dart:io';

Future<List<Map<String, dynamic>>> loadHistorySessions(File file) async {
  if (!await file.exists()) return [];
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! List) return [];
  return decoded
      .whereType<Map>()
      .map((row) => Map<String, dynamic>.from(row))
      .toList();
}

Future<void> saveHistorySession(File file, Map<String, dynamic> session) async {
  final sessions = await loadHistorySessions(file);
  final code = session['code'];
  final existingIndex = sessions.indexWhere((row) => row['code'] == code);
  if (existingIndex >= 0) {
    sessions.removeAt(existingIndex);
  }
  sessions.insert(0, Map<String, dynamic>.from(session));
  await file.parent.create(recursive: true);
  final temporary = File('${file.path}.tmp');
  try {
    await temporary.writeAsString(jsonEncode(sessions), flush: true);
    await temporary.rename(file.path);
  } catch (_) {
    if (await temporary.exists()) await temporary.delete();
    rethrow;
  }
}

List<Map<String, dynamic>> sortRoadHazardHistory(
  Iterable<Map<String, dynamic>> sessions,
) {
  final rows = sessions.map(Map<String, dynamic>.from).toList();
  DateTime? parse(Map<String, dynamic> row) {
    final value = row['startTime'];
    return value is String ? DateTime.tryParse(value) : null;
  }

  rows.sort((a, b) {
    final left = parse(a);
    final right = parse(b);
    if (left == null) return right == null ? 0 : 1;
    if (right == null) return -1;
    return right.compareTo(left);
  });
  return rows;
}

List<Map<String, dynamic>> filterRoadHazardHistory(
  Iterable<Map<String, dynamic>> sessions, {
  String query = '',
  String severity = 'ALL',
  String source = 'ALL',
}) {
  final needle = query.trim().toLowerCase();
  return sortRoadHazardHistory(
    sessions.where((row) {
      final haystack = [
        row['code'],
        row['roadSection'],
        row['source'],
        row['severity'],
      ].whereType<String>().join(' ').toLowerCase();
      final severityMatch =
          severity == 'ALL' ||
          (row['severity'] as String? ?? '').toUpperCase() ==
              severity.toUpperCase();
      final sourceMatch =
          source == 'ALL' ||
          (row['source'] as String? ?? '').toLowerCase() ==
              source.toLowerCase();
      return (needle.isEmpty || haystack.contains(needle)) &&
          severityMatch &&
          sourceMatch;
    }),
  );
}

Map<String, int> historyHazardTotals(Iterable<Map<String, dynamic>> sessions) {
  final counts = <String, int>{
    'Potholes': 0,
    'Corragation': 0,
    'Ruts': 0,
    'Total': 0,
  };
  for (final session in sessions) {
    final events = session['events'];
    if (events is! List) continue;
    for (final event in events.whereType<Map>()) {
      final label = (event['label'] as String? ?? '').toLowerCase();
      final category = switch (label) {
        'potholes' => 'Potholes',
        'corragation' || 'corrugation' => 'Corragation',
        'ruts' => 'Ruts',
        _ => null,
      };
      if (category == null) continue;
      counts[category] = counts[category]! + 1;
      counts['Total'] = counts['Total']! + 1;
    }
  }
  return counts;
}

String roadHazardHistoryCsv(Iterable<Map<String, dynamic>> sessions) {
  String field(Object? value) {
    final text = value?.toString() ?? '';
    if (!text.contains(',') &&
        !text.contains('"') &&
        !text.contains('\n') &&
        !text.contains('\r')) {
      return text;
    }
    return '"${text.replaceAll('"', '""')}"';
  }

  final rows = <List<Object?>>[
    [
      'Session',
      'Source',
      'Road',
      'Severity',
      'Hazard ID',
      'Hazard',
      'Confidence',
      'Timestamp',
      'Video Offset ms',
      'Latitude',
      'Longitude',
      'Evidence path',
    ],
  ];
  for (final session in sessions) {
    final events = session['events'];
    if (events is! List || events.isEmpty) {
      rows.add([
        session['code'],
        session['source'],
        session['roadSection'],
        session['severity'],
        '',
        '',
        '',
        session['startTime'],
        '',
        '',
        '',
        '',
      ]);
      continue;
    }
    for (final item in events.whereType<Map>()) {
      rows.add([
        session['code'],
        session['source'],
        session['roadSection'],
        session['severity'],
        item['id'],
        item['label'],
        item['confidence'],
        item['time'],
        item['videoOffsetMs'],
        item['latitude'],
        item['longitude'],
        item['photoPath'],
      ]);
    }
  }
  return rows.map((row) => row.map(field).join(',')).join('\r\n');
}

Map<String, dynamic> photoImportEvent({
  required String id,
  required String label,
  required double confidence,
  required DateTime timestamp,
  required String photoPath,
  double? latitude,
  double? longitude,
}) => {
  'id': id,
  'label': label,
  'confidence': confidence,
  'time': timestamp.toIso8601String(),
  'photoPath': photoPath,
  'latitude': latitude,
  'longitude': longitude,
  'manual': false,
};
