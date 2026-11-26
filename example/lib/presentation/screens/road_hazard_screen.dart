// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:roadchitra_example/road_hazard/detection_tracker.dart';
import 'package:roadchitra_example/road_hazard/feature_tools.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:roadchitra_example/reports/road_hazard_report.dart';

/// Road hazard inspection uses Ultralytics native camera and TFLite inference.
class RoadHazardScreen extends StatefulWidget {
  const RoadHazardScreen({super.key});

  @override
  State<RoadHazardScreen> createState() => _RoadHazardScreenState();
}

class _RoadHazardScreenState extends State<RoadHazardScreen> {
  static const _modelPath = 'assets/models/roadchitra.tflite';
  static const _hazardLabels = {
    'potholes',
    'corragation',
    'corrugation',
    'ruts',
  };
  static const _sessionFile = 'road_hazard_sessions.json';

  final _controller = YOLOViewController();
  final _sectionController = TextEditingController(text: 'Hauling Road');
  final _summaryController = TextEditingController();
  final _historySearchController = TextEditingController();
  String _historySeverity = 'ALL';
  String _historySource = 'ALL';
  final List<Map<String, dynamic>> _events = [];
  final List<Map<String, dynamic>> _sessions = [];
  final _reportExporter = RoadHazardReportExporter();
  final RoadHazardDetectionTracker _detectionTracker =
      RoadHazardDetectionTracker();
  final List<({YOLOResult result, String trackId})> _pendingCaptures = [];
  bool _processingCaptures = false;
  final Map<String, String> _eventIdByTrackId = {};

  YOLOResult? _latestHazard;
  String? _latestHazardId;
  DateTime? _startedAt;
  String _summaryNotes = '';
  double _confidence = 0.3;
  double _distanceMeters = 0;
  double? _latitude;
  double? _longitude;
  String? _cameraError;
  bool _recording = false;
  bool _paused = false;
  bool _torch = false;
  bool _isSaving = false;
  bool _loadingHistory = true;
  bool _isFullscreen = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSessions());
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _sectionController.dispose();
    _summaryController.dispose();
    _historySearchController.dispose();
    _controller.dispose();
    super.dispose();
  }

  String _label(YOLOResult result) => result.className.trim();

  List<YOLOResult> _hazards(List<YOLOResult> results) => results
      .where((result) => _hazardLabels.contains(_label(result).toLowerCase()))
      .where((result) => result.confidence >= _confidence)
      .toList(growable: false);

  void _onResults(List<YOLOResult> results) {
    if (_paused || !mounted) return;
    final hazards = _hazards(results);
    final tracked = _detectionTracker.update(
      hazards
          .map(
            (result) => HazardDetection(
              label: _label(result),
              left: result.normalizedBox.left,
              top: result.normalizedBox.top,
              width: result.normalizedBox.width,
              height: result.normalizedBox.height,
            ),
          )
          .toList(growable: false),
    );
    final uncaptured = _detectionTracker.uncaptured(tracked);
    setState(() {
      _latestHazard = uncaptured.isEmpty
          ? null
          : hazards[tracked.indexOf(uncaptured.first)];
      _latestHazardId = uncaptured.isEmpty ? null : uncaptured.first.id;
    });
    if (!_recording || hazards.isEmpty) return;
    for (var index = 0; index < tracked.length; index++) {
      final detection = tracked[index];
      if (_detectionTracker.isCaptured(detection.id) ||
          _eventIdByTrackId.containsKey(detection.id)) {
        continue;
      }
      _detectionTracker.markCaptured(detection.id);
      _eventIdByTrackId[detection.id] = detection.id;
      _pendingCaptures.add((result: hazards[index], trackId: detection.id));
      unawaited(_processPendingCaptures());
    }
  }

  Future<void> _processPendingCaptures() async {
    if (_processingCaptures) return;
    _processingCaptures = true;
    try {
      while (_pendingCaptures.isNotEmpty) {
        final pending = _pendingCaptures.removeAt(0);
        await _addEvent(
          pending.result,
          manual: false,
          eventId: pending.trackId,
        );
      }
    } finally {
      _processingCaptures = false;
    }
  }

  Future<File> _sessionsFile() async =>
      File('${(await getApplicationDocumentsDirectory()).path}/$_sessionFile');

  Future<void> _loadSessions() async {
    try {
      final file = await _sessionsFile();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) {
        throw const FormatException(
          'Expected a JSON list of saved inspections.',
        );
      }
      if (mounted) {
        setState(() {
          _sessions.addAll(
            decoded.whereType<Map>().map(
              (row) => Map<String, dynamic>.from(row),
            ),
          );
        });
      }
    } catch (error) {
      debugPrint('Unable to load local road hazard history: $error');
    } finally {
      if (mounted) setState(() => _loadingHistory = false);
    }
  }

  Future<void> _saveSessions() async {
    final file = await _sessionsFile();
    final temporaryFile = File('${file.path}.tmp');
    try {
      await temporaryFile.writeAsString(jsonEncode(_sessions), flush: true);
      if (Platform.isWindows && await file.exists()) await file.delete();
      await temporaryFile.rename(file.path);
    } catch (_) {
      if (await temporaryFile.exists()) await temporaryFile.delete();
      rethrow;
    }
  }

  Future<void> _writeSessionSnapshot() async {
    final events = List<Map<String, dynamic>>.from(_events);
    final isDraft = _sessions.isNotEmpty && _sessions.first['code'] == 'DRAFT';
    final previous = isDraft ? _sessions.first : null;
    if (isDraft) {
      _sessions[0] = {..._sessions.first, 'events': events};
    } else {
      _sessions.insert(0, {'code': 'DRAFT', 'events': events});
    }
    try {
      await _saveSessions();
    } catch (_) {
      if (isDraft && previous != null) {
        _sessions[0] = previous;
      } else if (_sessions.isNotEmpty && _sessions.first['code'] == 'DRAFT') {
        _sessions.removeAt(0);
      }
      rethrow;
    }
  }

  Future<void> _addEvent(
    YOLOResult result, {
    required bool manual,
    required String eventId,
  }) async {
    if (!_recording || _isSaving || (_paused && !manual)) return;
    if (_events.any((event) => event['id'] == eventId)) return;
    final now = DateTime.now();
    String? photoPath;
    try {
      final bytes = await _controller.capturePhoto(withOverlays: true);
      if (bytes != null) {
        final directory = await getApplicationDocumentsDirectory();
        final photo = File(
          '${directory.path}/road-hazard-$eventId-${now.microsecondsSinceEpoch}.jpg',
        );
        await photo.writeAsBytes(bytes, flush: true);
        photoPath = photo.path;
      }
    } catch (error) {
      debugPrint('Auto-capture failed for $eventId: $error');
    }
    final event = <String, dynamic>{
      'id': eventId,
      'label': _label(result),
      'confidence': result.confidence,
      'box': [
        result.normalizedBox.left,
        result.normalizedBox.top,
        result.normalizedBox.width,
        result.normalizedBox.height,
      ],
      'latitude': _latitude,
      'longitude': _longitude,
      'time': now.toIso8601String(),
      'manual': manual,
      'photoPath': photoPath,
    };
    _events.insert(0, event);
    try {
      await _writeSessionSnapshot();
      if (mounted) setState(() {});
    } catch (error) {
      _events.remove(event);
      if (photoPath != null) {
        final photo = File(photoPath);
        if (await photo.exists()) await photo.delete();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal menyimpan event hazard: $error')),
        );
      }
    }
  }

  Map<String, int> _eventCounts(Iterable<Map<String, dynamic>> events) {
    final counts = <String, int>{'Potholes': 0, 'Corragation': 0, 'Ruts': 0};
    for (final event in events) {
      final label = (event['label'] as String? ?? '').toLowerCase();
      final category = switch (label) {
        'potholes' => 'Potholes',
        'corragation' || 'corrugation' => 'Corragation',
        'ruts' => 'Ruts',
        _ => null,
      };
      if (category != null) counts[category] = counts[category]! + 1;
    }
    return counts;
  }

  String _severityFor(int count) => count >= 12
      ? 'CRITICAL'
      : count >= 7
      ? 'HIGH'
      : count >= 3
      ? 'MEDIUM'
      : 'LOW';

  RoadHazardReport _reportFromSession(Map<String, dynamic> session) {
    final rawEvents = (session['events'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((event) => Map<String, dynamic>.from(event))
        .toList();
    final events = rawEvents.map((event) {
      final photoPath = event['photoPath'] as String?;
      Uint8List? photoBytes;
      if (photoPath != null) {
        final photoFile = File(photoPath);
        if (photoFile.existsSync()) photoBytes = photoFile.readAsBytesSync();
      }
      final offsetMs = event['videoOffsetMs'];
      return RoadHazardReportEvent(
        id: event['id'] as String? ?? '',
        label: event['label'] as String? ?? 'Other',
        confidence: (event['confidence'] as num?)?.toDouble() ?? 0,
        timestamp:
            DateTime.tryParse(event['time'] as String? ?? '') ?? DateTime.now(),
        videoOffset: offsetMs is int ? Duration(milliseconds: offsetMs) : null,
        latitude: (event['latitude'] as num?)?.toDouble(),
        longitude: (event['longitude'] as num?)?.toDouble(),
        speedKmh: (event['speedKmh'] as num?)?.toDouble(),
        notes: event['notes'] as String?,
        photoBytes: photoBytes,
      );
    }).toList();
    final start =
        DateTime.tryParse(session['startTime'] as String? ?? '') ??
        DateTime.now();
    final end = DateTime.tryParse(session['endTime'] as String? ?? '') ?? start;
    final counts = _eventCounts(rawEvents);
    return RoadHazardReport(
      sessionCode: session['code'] as String? ?? 'RH-DRAFT',
      siteName: session['site'] as String? ?? 'Local device',
      inspectorName: 'Field inspector',
      roadSection: session['roadSection'] as String? ?? 'Hauling Road',
      startTime: start,
      endTime: end,
      durationSeconds: session['durationSeconds'] as int? ?? 0,
      distanceMeters: (session['distanceMeters'] as num?)?.toDouble() ?? 0,
      potholesCount: session['potholesCount'] as int? ?? counts['Potholes']!,
      corrugationCount:
          session['corrugationCount'] as int? ?? counts['Corragation']!,
      rutsCount: session['rutsCount'] as int? ?? counts['Ruts']!,
      severity:
          session['severity'] as String? ?? _severityFor(rawEvents.length),
      summaryNotes: session['summaryNotes'] as String?,
      events: events,
    );
  }

  Future<void> _exportSessionPdf(Map<String, dynamic> session) async {
    try {
      final bytes = await _reportExporter.toPdf(_reportFromSession(session));
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/${session['code']}.pdf');
      await file.writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: '${session['code']}.pdf',
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Gagal membuat PDF: $error')));
      }
    }
  }

  Future<void> _exportSessionExcel(Map<String, dynamic> session) async {
    try {
      final bytes = _reportExporter.toXlsx(_reportFromSession(session));
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/${session['code']}.xlsx');
      await file.writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: '${session['code']}.xlsx',
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Gagal membuat Excel: $error')));
      }
    }
  }

  Future<void> _shareWhatsApp(Map<String, dynamic> session) async {
    final report = _reportFromSession(session);
    final text = [
      '*ROAD HAZARD INSPECTION*',
      'Session: ${report.sessionCode}',
      'Site: ${report.siteName}',
      'Road: ${report.roadSection}',
      'Severity: ${report.severity}',
      'Hazards: ${report.events.length} (Potholes ${report.potholesCount}, Corrugation ${report.corrugationCount}, Ruts ${report.rutsCount})',
      'Distance: ${report.distanceMeters.toStringAsFixed(0)} m',
      if ((report.summaryNotes ?? '').trim().isNotEmpty)
        'Notes: ${report.summaryNotes}',
    ].join('\\n');
    final uri = Uri.https('wa.me', '/', {'text': text});
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tidak dapat membuka WhatsApp.')),
      );
    }
  }

  Future<void> _saveSession() async {
    if (!_recording || _startedAt == null || _isSaving) return;
    final now = DateTime.now();
    final events = List<Map<String, dynamic>>.from(_events);
    final counts = _eventCounts(events);
    final row = <String, dynamic>{
      'code': 'RH-${now.toUtc().millisecondsSinceEpoch}',
      'source': 'camera',
      'site': 'Local device',
      'roadSection': _sectionController.text.trim().isEmpty
          ? 'Hauling Road'
          : _sectionController.text.trim(),
      'startTime': _startedAt!.toIso8601String(),
      'endTime': now.toIso8601String(),
      'durationSeconds': now.difference(_startedAt!).inSeconds,
      'distanceMeters': _distanceMeters,
      'totalHazards': events.length,
      'potholesCount': counts['Potholes'],
      'corrugationCount': counts['Corragation'],
      'rutsCount': counts['Ruts'],
      'severity': _severityFor(events.length),
      'events': events,
      'summaryNotes': _summaryNotes,
    };

    setState(() {
      _recording = false;
      _isSaving = true;
      _sessions.insert(0, row);
    });
    try {
      await _saveSessions();
      if (!mounted) return;
      setState(() {
        _paused = false;
        _startedAt = null;
        _events.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Inspeksi tersimpan offline di perangkat.'),
        ),
      );
    } catch (error) {
      _sessions.remove(row);
      if (mounted) {
        setState(() => _recording = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal menyimpan inspeksi: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _startInspection() async {
    if (_recording || _isSaving) return;
    if (_sessions.any((session) => session['code'] == 'DRAFT')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Selesaikan atau buang inspeksi draft sebelum memulai yang baru.',
          ),
        ),
      );
      return;
    }
    setState(() => _isSaving = true);
    var locationReady = false;
    try {
      if (await Geolocator.isLocationServiceEnabled()) {
        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        locationReady =
            permission == LocationPermission.whileInUse ||
            permission == LocationPermission.always;
        if (locationReady) {
          try {
            final position = await Geolocator.getCurrentPosition();
            _latitude = position.latitude;
            _longitude = position.longitude;
          } catch (error) {
            locationReady = false;
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Lokasi awal tidak tersedia: $error')),
              );
            }
          }
        }
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('GPS tidak tersedia: $error')));
      }
    }
    if (!mounted) return;
    _detectionTracker.clear();
    _eventIdByTrackId.clear();
    setState(() {
      _events.clear();
      _distanceMeters = 0;
      if (!locationReady) {
        _latitude = null;
        _longitude = null;
      }
      _startedAt = DateTime.now();
      _recording = true;
      _paused = false;
      _isSaving = false;
    });
    if (locationReady) unawaited(_captureLocation());
    if (!locationReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Inspeksi berjalan tanpa GPS; lokasi dan jarak tidak akan direkam.',
          ),
        ),
      );
    }
  }

  Future<void> _captureLocation() async {
    if (_recording && _paused) return;
    var continueLocationUpdates = false;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (!mounted) return;
        setState(() {
          _latitude = null;
          _longitude = null;
        });
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission != LocationPermission.whileInUse &&
          permission != LocationPermission.always) {
        if (!mounted) return;
        setState(() {
          _latitude = null;
          _longitude = null;
        });
        return;
      }
      continueLocationUpdates = true;
      final position = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      setState(() {
        final oldLatitude = _latitude;
        final oldLongitude = _longitude;
        if (_recording && oldLatitude != null && oldLongitude != null) {
          final meters = Geolocator.distanceBetween(
            oldLatitude,
            oldLongitude,
            position.latitude,
            position.longitude,
          );
          if (meters >= 1 && meters <= 500) _distanceMeters += meters;
        }
        _latitude = position.latitude;
        _longitude = position.longitude;
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lokasi tidak tersedia: $error')),
        );
      }
    } finally {
      if (continueLocationUpdates && mounted && _recording && !_paused) {
        unawaited(
          Future<void>.delayed(const Duration(seconds: 10), _captureLocation),
        );
      }
    }
  }

  Future<void> _snapshot() async {
    if (_recording && _latestHazardId != null) {
      final existing = _events.cast<Map<String, dynamic>?>().firstWhere(
        (event) => event?['id'] == _latestHazardId,
        orElse: () => null,
      );
      final photoPath = existing?['photoPath'];
      if (photoPath is String && await File(photoPath).exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Hazard $_latestHazardId sudah dicapture.')),
          );
        }
        return;
      }
    }
    File? savedFile;
    try {
      final bytes = await _controller.capturePhoto(withOverlays: true);
      if (bytes == null) throw StateError('Kamera belum siap mengambil foto.');
      final dir = await getApplicationDocumentsDirectory();
      savedFile = File(
        '${dir.path}/road-hazard-${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      await savedFile.writeAsBytes(bytes, flush: true);
      final active = _latestHazard;
      if (_recording && active != null && _latestHazardId != null) {
        final now = DateTime.now();
        final existing = _events.cast<Map<String, dynamic>?>().firstWhere(
          (event) => event?['id'] == _latestHazardId,
          orElse: () => null,
        );
        if (existing != null) {
          final oldPath = existing['photoPath'];
          existing['photoPath'] = savedFile.path;
          existing['manual'] = true;
          try {
            await _writeSessionSnapshot();
            if (oldPath is String && oldPath != savedFile.path) {
              final oldFile = File(oldPath);
              if (await oldFile.exists()) await oldFile.delete();
            }
          } catch (_) {
            existing['photoPath'] = oldPath;
            rethrow;
          }
        } else {
          final event = <String, dynamic>{
            'id': _latestHazardId,
            'label': _label(active),
            'confidence': active.confidence,
            'box': [
              active.normalizedBox.left,
              active.normalizedBox.top,
              active.normalizedBox.width,
              active.normalizedBox.height,
            ],
            'latitude': _latitude,
            'longitude': _longitude,
            'time': now.toIso8601String(),
            'manual': true,
            'photoPath': savedFile.path,
          };
          _events.insert(0, event);
          try {
            await _writeSessionSnapshot();
          } catch (_) {
            _events.remove(event);
            rethrow;
          }
        }
        if (mounted) setState(() {});
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Foto inspeksi tersimpan: ${savedFile.uri.pathSegments.last}',
            ),
          ),
        );
      }
    } catch (error) {
      if (savedFile != null && await savedFile.exists()) {
        await savedFile.delete();
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Gagal mengambil foto: $error')));
      }
    }
  }

  Future<void> _deleteSession(Map<String, dynamic> session) async {
    final index = _sessions.indexOf(session);
    if (index < 0) return;
    setState(() => _sessions.removeAt(index));
    try {
      await _saveSessions();
      final events = (session['events'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((event) => Map<String, dynamic>.from(event));
      for (final path
          in events.map((event) => event['photoPath']).whereType<String>()) {
        final photo = File(path);
        if (await photo.exists()) {
          await photo.delete();
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Inspeksi dihapus dari perangkat.')),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _sessions.insert(index, session));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal menghapus inspeksi: $error')),
        );
      }
    }
  }

  Future<void> _exportHistoryCsv() async {
    try {
      final csv = roadHazardHistoryCsv(_sessions);
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/chitra-vision-history.csv');
      await file.writeAsString(csv, flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: 'Chitra Vision hazard history CSV',
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Gagal mengekspor CSV: $error')));
      }
    }
  }

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hapus semua inspeksi?'),
        content: const Text(
          'Inspeksi dan foto terkait akan dihapus permanen dari perangkat.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hapus semua'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final previousSessions = List<Map<String, dynamic>>.from(_sessions);
    setState(() => _sessions.clear());
    try {
      await _saveSessions();
      for (final session in previousSessions) {
        final events = (session['events'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map((event) => Map<String, dynamic>.from(event));
        for (final path
            in events.map((event) => event['photoPath']).whereType<String>()) {
          final photo = File(path);
          if (await photo.exists()) {
            await photo.delete();
          }
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() => _sessions.addAll(previousSessions));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal menghapus riwayat: $error')),
        );
      }
    }
  }

  int _count(String label) => _events
      .where(
        (event) =>
            (event['label'] as String? ?? '').toLowerCase() ==
            label.toLowerCase(),
      )
      .length;

  Future<void> _editEventNote(Map<String, dynamic> event) async {
    final controller = TextEditingController(
      text: event['notes'] as String? ?? '',
    );
    final note = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Catatan: ${event['label']}'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          maxLength: 300,
          decoration: const InputDecoration(
            hintText: 'Tambahkan catatan lapangan',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Hapus catatan'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (note == null) return;
    final previousNote = event['notes'];
    if (note.isEmpty) {
      event.remove('notes');
    } else {
      event['notes'] = note;
    }
    try {
      await _writeSessionSnapshot();
      if (mounted) setState(() {});
    } catch (error) {
      if (previousNote == null) {
        event.remove('notes');
      } else {
        event['notes'] = previousNote;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal menyimpan catatan: $error')),
        );
      }
    }
  }

  Future<void> _removeEvent(Map<String, dynamic> event) async {
    final index = _events.indexOf(event);
    if (index < 0) return;
    _events.removeAt(index);
    try {
      await _writeSessionSnapshot();
      if (mounted) setState(() {});
    } catch (error) {
      _events.insert(index, event);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal menghapus event: $error')),
        );
      }
    }
  }

  Widget _eventTile(Map<String, dynamic> event, {bool readOnly = false}) {
    final photoPath = event['photoPath'] as String?;
    final photo = photoPath == null ? null : File(photoPath);
    return Card(
      child: ListTile(
        leading: photo != null && photo.existsSync()
            ? ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  photo,
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                ),
              )
            : const Icon(Icons.warning_amber_rounded),
        title: Text(
          '${event['id'] ?? 'no-id'} · ${event['label'] as String? ?? 'Unknown hazard'}',
        ),
        subtitle: Text(
          '${(((event['confidence'] as num?) ?? 0) * 100).toStringAsFixed(0)}% · '
          '${(DateTime.tryParse(event['time'] as String? ?? '') ?? DateTime.now()).toLocal()} · '
          '${event['latitude'] ?? 'GPS —'}, ${event['longitude'] ?? '—'}'
          '${event['notes'] == null ? '' : '\\n${event['notes']}'}',
        ),
        trailing: readOnly
            ? null
            : PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'note') unawaited(_editEventNote(event));
                  if (value == 'delete') unawaited(_removeEvent(event));
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'note', child: Text('Edit catatan')),
                  PopupMenuItem(value: 'delete', child: Text('Hapus event')),
                ],
              ),
      ),
    );
  }

  Future<void> _showMapPreview(List<Map<String, dynamic>> events) async {
    final points = events
        .where((event) => event['latitude'] is num && event['longitude'] is num)
        .toList();
    if (points.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Belum ada titik GPS dalam inspeksi ini.'),
        ),
      );
      return;
    }
    final coordinates = points
        .map(
          (event) => LatLng(
            (event['latitude'] as num).toDouble(),
            (event['longitude'] as num).toDouble(),
          ),
        )
        .toList();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.8,
          child: FlutterMap(
            options: MapOptions(
              initialCameraFit: CameraFit.coordinates(
                coordinates: coordinates,
                padding: const EdgeInsets.all(48),
                maxZoom: 18,
                minZoom: 5,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.chitraparatama.chitravision',
              ),
              MarkerLayer(
                markers: points.map((event) {
                  final point = LatLng(
                    (event['latitude'] as num).toDouble(),
                    (event['longitude'] as num).toDouble(),
                  );
                  return Marker(
                    point: point,
                    width: 56,
                    height: 64,
                    child: GestureDetector(
                      onTap: () => unawaited(
                        launchUrl(
                          Uri.https('maps.google.com', '/', {
                            'q': '${point.latitude},${point.longitude}',
                          }),
                          mode: LaunchMode.externalApplication,
                        ),
                      ),
                      child: const Icon(
                        Icons.location_pin,
                        color: Colors.red,
                        size: 44,
                      ),
                    ),
                  );
                }).toList(),
              ),
              const RichAttributionWidget(
                attributions: [
                  TextSourceAttribution('© OpenStreetMap contributors'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
  }

  Widget _severityBadge(String severity) {
    final color = switch (severity) {
      'CRITICAL' => Colors.red,
      'HIGH' => Colors.deepOrange,
      'MEDIUM' => Colors.amber,
      _ => Colors.green,
    };
    return Chip(
      avatar: Icon(Icons.shield_outlined, color: color, size: 18),
      label: Text(severity),
      side: BorderSide(color: color.withValues(alpha: 0.55)),
    );
  }

  String _formatDuration(int seconds) {
    final duration = Duration(seconds: seconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final remainingSeconds = duration.inSeconds.remainder(60);
    return hours > 0
        ? '${hours}h ${minutes}m ${remainingSeconds}s'
        : '${minutes}m ${remainingSeconds}s';
  }

  @override
  Widget build(BuildContext context) {
    final current = _latestHazard;
    return Scaffold(
      appBar: _isFullscreen
          ? null
          : AppBar(
              title: const Text('Road Hazard AI'),
              actions: [
                IconButton(
                  tooltip: 'Analisis Foto',
                  icon: const Icon(Icons.photo_library_outlined),
                  onPressed: () async {
                    await Navigator.pushNamed(context, '/single');
                    if (mounted) {
                      _sessions.clear();
                      await _loadSessions();
                    }
                  },
                ),
                IconButton(
                  tooltip: 'Upload & Analisis Video',
                  icon: const Icon(Icons.video_file_outlined),
                  onPressed: () async {
                    await Navigator.pushNamed(context, '/video');
                    if (mounted) {
                      _sessions.clear();
                      await _loadSessions();
                    }
                  },
                ),
                IconButton(
                  tooltip: 'Riwayat inspeksi',
                  icon: const Icon(Icons.history),
                  onPressed: _showHistory,
                ),
              ],
            ),
      body: _isFullscreen
          ? Stack(
              fit: StackFit.expand,
              children: [
                _cameraPreview(current),
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton.filledTonal(
                    tooltip: 'Keluar dari layar penuh',
                    onPressed: () => unawaited(_setFullscreen(false)),
                    icon: const Icon(Icons.fullscreen_exit),
                  ),
                ),
              ],
            )
          : SafeArea(
              child: Column(
                children: [
                  Expanded(
                    flex: 6,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _cameraPreview(current),
                        Positioned(
                          top: 8,
                          right: 8,
                          child: IconButton.filledTonal(
                            tooltip: 'Layar penuh',
                            onPressed: () => unawaited(_setFullscreen(true)),
                            icon: const Icon(Icons.fullscreen),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 5,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                      children: [
                        TextField(
                          controller: _sectionController,
                          decoration: const InputDecoration(
                            labelText: 'Road section',
                            prefixIcon: Icon(Icons.route),
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _summaryController,
                          minLines: 2,
                          maxLines: 4,
                          maxLength: 500,
                          decoration: const InputDecoration(
                            labelText: 'Ringkasan / rekomendasi',
                            hintText: 'Catatan kondisi jalan dan tindak lanjut',
                            prefixIcon: Icon(Icons.notes),
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (value) =>
                              setState(() => _summaryNotes = value.trim()),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: _stat(
                                'Potholes',
                                _count('Potholes'),
                                Colors.red,
                              ),
                            ),
                            Expanded(
                              child: _stat(
                                'Corragation',
                                _count('Corragation') + _count('Corrugation'),
                                Colors.orange,
                              ),
                            ),
                            Expanded(
                              child: _stat(
                                'Ruts',
                                _count('Ruts'),
                                Colors.amber,
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Confidence ${(100 * _confidence).round()}%',
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Slider(
                                value: _confidence,
                                min: 0.1,
                                max: 0.9,
                                divisions: 16,
                                onChanged: (value) {
                                  setState(() => _confidence = value);
                                  unawaited(
                                    _controller.setConfidenceThreshold(value),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed: _recording
                                  ? (_isSaving ? null : _saveSession)
                                  : (_isSaving ? null : _startInspection),
                              icon: _isSaving
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Icon(
                                      _recording
                                          ? Icons.stop
                                          : Icons.fiber_manual_record,
                                    ),
                              label: Text(
                                _isSaving
                                    ? 'Menyimpan…'
                                    : _recording
                                    ? 'Akhiri inspeksi'
                                    : 'Mulai inspeksi',
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: _snapshot,
                              icon: const Icon(Icons.camera_alt),
                              label: const Text('Foto manual'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _captureLocation,
                              icon: const Icon(Icons.my_location),
                              label: const Text('GPS'),
                            ),
                          ],
                        ),
                        if (_recording)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              'Inspeksi berjalan${_paused ? ' · dijeda' : ''} · ${_events.length} hazard · '
                              'Jarak ${_distanceMeters.toStringAsFixed(0)} m · GPS '
                              '${_latitude?.toStringAsFixed(5) ?? '—'}, '
                              '${_longitude?.toStringAsFixed(5) ?? '—'}',
                            ),
                          ),
                        const SizedBox(height: 8),
                        Text(
                          'Deteksi terbaru',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (_events.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(12),
                            child: Text('Hazard inspeksi akan muncul di sini.'),
                          )
                        else
                          ..._events.take(12).map((event) => _eventTile(event)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _cameraPreview(YOLOResult? current) => Stack(
    fit: StackFit.expand,
    children: [
      YOLOView(
        modelPath: _modelPath,
        task: YOLOTask.detect,
        controller: _controller,
        cameraResolution: '720p',
        confidenceThreshold: _confidence,
        onResult: _onResults,
        onModelError: (error, modelPath, task) {
          if (mounted) setState(() => _cameraError = '$error');
        },
        onModelLoad: (_, _) {
          if (mounted) setState(() => _cameraError = null);
        },
      ),
      if (current != null && _latestHazardId != null)
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _LiveDetectionPainter(
                id: _latestHazardId!,
                label: _label(current),
                confidence: current.confidence,
                box: current.normalizedBox,
              ),
            ),
          ),
        ),
      if (_cameraError != null)
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: Card(
            color: Colors.red.shade900,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text('Model/kamera gagal dimuat: $_cameraError'),
            ),
          ),
        ),
      Positioned(
        right: 10,
        top: 8,
        child: Row(
          children: [
            IconButton.filledTonal(
              tooltip: _paused ? 'Lanjutkan' : 'Pause',
              onPressed: () async {
                final next = !_paused;
                setState(() => _paused = next);
                if (next) {
                  await _controller.pause();
                } else {
                  await _controller.resume();
                  if (_recording) unawaited(_captureLocation());
                }
              },
              icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
            ),
            IconButton.filledTonal(
              tooltip: 'Lampu kamera',
              onPressed: () async {
                await _controller.setTorchMode(!_torch);
                if (mounted) {
                  setState(() => _torch = _controller.isTorchEnabled);
                }
              },
              icon: Icon(_torch ? Icons.flash_on : Icons.flash_off),
            ),
          ],
        ),
      ),
    ],
  );

  Future<void> _setFullscreen(bool enabled) async {
    if (_isFullscreen == enabled) return;
    setState(() => _isFullscreen = enabled);
    await SystemChrome.setEnabledSystemUIMode(
      enabled ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  Widget _stat(String label, int count, Color color) => Card(
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        children: [
          Text(
            '$count',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      ),
    ),
  );

  void _showHistory() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Riwayat inspeksi lokal (${_sessions.length})',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => unawaited(
                      _showMapPreview(
                        _sessions
                            .expand(
                              (session) =>
                                  (session['events'] as List<dynamic>? ??
                                          const [])
                                      .whereType<Map>()
                                      .map(
                                        (event) =>
                                            Map<String, dynamic>.from(event),
                                      ),
                            )
                            .toList(),
                      ),
                    ),
                    icon: const Icon(Icons.map_outlined),
                    label: const Text('Peta'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _sessions.isEmpty
                        ? null
                        : () => unawaited(_exportHistoryCsv()),
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('CSV'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _sessions.isEmpty
                        ? null
                        : () => unawaited(_clearHistory()),
                    icon: const Icon(Icons.delete_sweep_outlined),
                    label: const Text('Hapus semua'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _historySearchController,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Cari kode sesi atau nama jalan',
                  suffixIcon: IconButton(
                    tooltip: 'Hapus pencarian',
                    onPressed: () {
                      _historySearchController.clear();
                      setState(() {});
                    },
                    icon: const Icon(Icons.clear),
                  ),
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 4,
              children: [
                for (final severity in [
                  'ALL',
                  'LOW',
                  'MEDIUM',
                  'HIGH',
                  'CRITICAL',
                ])
                  ChoiceChip(
                    label: Text(severity == 'ALL' ? 'Semua risiko' : severity),
                    selected: _historySeverity == severity,
                    onSelected: (_) =>
                        setState(() => _historySeverity = severity),
                  ),
                for (final source in ['ALL', 'camera', 'video', 'image'])
                  ChoiceChip(
                    label: Text(source == 'ALL' ? 'Semua sumber' : source),
                    selected: _historySource == source,
                    onSelected: (_) => setState(() => _historySource = source),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(
                alignment: WrapAlignment.center,
                children: [
                  for (final entry in historyHazardTotals(_sessions).entries)
                    Chip(label: Text('${entry.key}: ${entry.value}')),
                ],
              ),
            ),
            Expanded(
              child: Builder(
                builder: (context) {
                  if (_loadingHistory) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final filteredSessions = filterRoadHazardHistory(
                    _sessions,
                    query: _historySearchController.text,
                    severity: _historySeverity,
                    source: _historySource,
                  );
                  if (filteredSessions.isEmpty) {
                    return Center(
                      child: Text(
                        _sessions.isEmpty
                            ? 'Belum ada inspeksi tersimpan.'
                            : 'Tidak ada sesi yang cocok dengan filter.',
                      ),
                    );
                  }
                  return ListView.builder(
                    itemCount: filteredSessions.length,
                    itemBuilder: (_, index) {
                      final session = filteredSessions[index];
                      final severity = session['severity'] as String? ?? 'LOW';
                      final eventCount = session['totalHazards'] as int? ?? 0;
                      final distance =
                          (session['distanceMeters'] as num?)?.toDouble() ?? 0;
                      final duration = session['durationSeconds'] as int? ?? 0;
                      return ListTile(
                        leading: const Icon(Icons.route),
                        title: Text(
                          session['roadSection'] as String? ?? 'Hauling Road',
                        ),
                        subtitle: Text(
                          '${session['code']} · $eventCount hazard · ${distance.toStringAsFixed(0)} m · '
                          '${_formatDuration(duration)} · '
                          '${(DateTime.tryParse(session['startTime'] as String? ?? '') ?? DateTime.now()).toLocal()}',
                        ),
                        trailing: _severityBadge(severity),
                        onTap: () => _showSessionDetails(session),
                        onLongPress: () => unawaited(_deleteSession(session)),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );

  void _showSessionDetails(Map<String, dynamic> session) {
    final events = (session['events'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((event) => Map<String, dynamic>.from(event))
        .toList();
    final counts = _eventCounts(events);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.85,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text(
                      '${session['roadSection']} · ${session['severity']}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text('${session['code']} · ${session['site']}'),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  children: [
                    Chip(label: Text('Hazard ${session['totalHazards']}')),
                    Chip(label: Text('Pothole ${counts['Potholes']}')),
                    Chip(label: Text('Corrugation ${counts['Corragation']}')),
                    Chip(label: Text('Ruts ${counts['Ruts']}')),
                    Chip(
                      label: Text(
                        '${((session['distanceMeters'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)} m',
                      ),
                    ),
                    Chip(
                      label: Text(
                        _formatDuration(
                          session['durationSeconds'] as int? ?? 0,
                        ),
                      ),
                    ),
                    _severityBadge(session['severity'] as String? ?? 'LOW'),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => unawaited(_showMapPreview(events)),
                      icon: const Icon(Icons.map_outlined),
                      label: const Text('Peta'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => unawaited(_exportSessionPdf(session)),
                      icon: const Icon(Icons.picture_as_pdf),
                      label: const Text('PDF'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => unawaited(_exportSessionExcel(session)),
                      icon: const Icon(Icons.table_chart),
                      label: const Text('Excel'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => unawaited(_shareWhatsApp(session)),
                      icon: const Icon(Icons.chat),
                      label: const Text('WhatsApp'),
                    ),
                    FilledButton.icon(
                      onPressed: () => unawaited(_exportSession(session)),
                      icon: const Icon(Icons.ios_share),
                      label: const Text('JSON'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: events.isEmpty
                    ? const Center(child: Text('Tidak ada detail hazard.'))
                    : ListView(
                        children: events
                            .map((event) => _eventTile(event, readOnly: true))
                            .toList(),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _exportSession(Map<String, dynamic> session) async {
    try {
      final directory = await getTemporaryDirectory();
      final name = '${session['code']}.json';
      final file = File('${directory.path}/$name');
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(session),
        flush: true,
      );
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], subject: name),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal mengekspor laporan: $error')),
        );
      }
    }
  }
}

class _LiveDetectionPainter extends CustomPainter {
  const _LiveDetectionPainter({
    required this.id,
    required this.label,
    required this.confidence,
    required this.box,
  });

  final String id;
  final String label;
  final double confidence;
  final Rect box;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || box.isEmpty) return;
    final rect = Rect.fromLTRB(
      (box.left * size.width).clamp(0.0, size.width),
      (box.top * size.height).clamp(0.0, size.height),
      (box.right * size.width).clamp(0.0, size.width),
      (box.bottom * size.height).clamp(0.0, size.height),
    );
    final boxPaint = Paint()
      ..color = Colors.redAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawRect(rect, boxPaint);

    final painter = TextPainter(
      text: TextSpan(
        text: '$id · $label · ${(confidence * 100).toStringAsFixed(0)}%',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: size.width * 0.8);
    final labelWidth = (painter.width + 12).clamp(0.0, size.width);
    final labelHeight = painter.height + 8;
    final labelLeft = rect.left.clamp(0.0, size.width - labelWidth);
    final labelTop = rect.top >= labelHeight
        ? rect.top - labelHeight
        : (rect.bottom).clamp(0.0, size.height - labelHeight);
    final background = RRect.fromRectAndRadius(
      Rect.fromLTWH(labelLeft, labelTop, labelWidth, labelHeight),
      const Radius.circular(4),
    );
    canvas.drawRRect(background, Paint()..color = Colors.redAccent);
    painter.paint(canvas, Offset(labelLeft + 6, labelTop + 4));
  }

  @override
  bool shouldRepaint(covariant _LiveDetectionPainter oldDelegate) =>
      oldDelegate.id != id ||
      oldDelegate.label != label ||
      oldDelegate.confidence != confidence ||
      oldDelegate.box != box;
}
