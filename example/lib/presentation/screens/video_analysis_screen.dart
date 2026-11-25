// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:roadchitra_example/reports/road_hazard_report.dart';
import 'package:roadchitra_example/road_hazard/detection_tracker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:url_launcher/url_launcher.dart';

/// Analyzes an uploaded road video frame-by-frame, assigns non-repeating
/// bounding box IDs, computes timestamps from a configurable start time, and
/// exports PDF / Excel reports.
class VideoAnalysisScreen extends StatefulWidget {
  const VideoAnalysisScreen({super.key});

  @override
  State<VideoAnalysisScreen> createState() => _VideoAnalysisScreenState();
}

class _VideoAnalysisScreenState extends State<VideoAnalysisScreen> {
  static const _modelPath = 'assets/models/roadchitra.tflite';
  static const _sessionFile = 'road_hazard_sessions.json';
  static const _videoChannel = MethodChannel('roadchitra/video_frames');
  static const _hazardLabels = {
    'potholes',
    'corragation',
    'corrugation',
    'ruts',
  };

  final _picker = ImagePicker();
  final _sectionController = TextEditingController(text: 'Hauling Road');
  final _summaryController = TextEditingController();
  final _reportExporter = RoadHazardReportExporter();

  late final YOLO _yolo;
  RoadHazardDetectionTracker _tracker = RoadHazardDetectionTracker(
    maxMissedFrames: 6,
  );

  bool _modelReady = false;
  String? _modelError;
  String? _videoPath;
  String? _videoName;
  int _videoDurationMs = 0;

  DateTime _startTime = DateTime.now();
  int _fps = 2;
  double _confidence = 0.3;

  bool _analyzing = false;
  bool _paused = false;
  bool _cancelRequested = false;
  int _currentTimeMs = 0;
  Uint8List? _currentFrameBytes;
  Size? _currentFrameSize;
  List<TrackedHazard> _visibleBoxes = const [];

  final List<Map<String, dynamic>> _events = [];
  Map<String, dynamic>? _completedSession;

  @override
  void initState() {
    super.initState();
    _yolo = YOLO(
      modelPath: _modelPath,
      task: YOLOTask.detect,
      useMultiInstance: true,
    );
    unawaited(_initModel());
  }

  @override
  void dispose() {
    _cancelRequested = true;
    _sectionController.dispose();
    _summaryController.dispose();
    unawaited(_yolo.dispose());
    super.dispose();
  }

  Future<void> _initModel() async {
    try {
      await _yolo.loadModel();
      if (mounted) setState(() => _modelReady = true);
    } catch (error) {
      if (mounted) setState(() => _modelError = '$error');
    }
  }

  Future<void> _pickVideo() async {
    if (_analyzing) return;
    final picked = await _picker.pickVideo(source: ImageSource.gallery);
    if (picked == null) return;
    try {
      final durationMs =
          await _videoChannel.invokeMethod<int>('getVideoDurationMs', {
            'path': picked.path,
          }) ??
          0;
      final firstFrame = await _videoChannel.invokeMethod<Uint8List>(
        'extractFrame',
        {'path': picked.path, 'timeMs': 0, 'maxWidth': 1280},
      );
      Size? frameSize;
      if (firstFrame != null) {
        final decoded = await _decodeImage(firstFrame);
        frameSize = Size(decoded.width.toDouble(), decoded.height.toDouble());
        decoded.dispose();
      }
      if (!mounted) return;
      setState(() {
        _videoPath = picked.path;
        _videoName = picked.name;
        _videoDurationMs = durationMs;
        _currentTimeMs = 0;
        _currentFrameBytes = firstFrame;
        _currentFrameSize = frameSize;
        _visibleBoxes = const [];
        _events.clear();
        _completedSession = null;
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal membaca video: $error')),
        );
      }
    }
  }

  Future<void> _pickStartDateTime() async {
    if (_analyzing) return;
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _startTime,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (pickedDate == null || !mounted) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_startTime),
    );
    if (pickedTime == null || !mounted) return;

    setState(() {
      _startTime = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
        _startTime.second,
      );
    });
  }

  Future<void> _startAnalysis() async {
    if (!_modelReady || _videoPath == null || _analyzing) return;
    final durationMs = _videoDurationMs;
    if (durationMs <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Durasi video tidak valid.')),
      );
      return;
    }

    _tracker = RoadHazardDetectionTracker(maxMissedFrames: _fps * 3);
    _tracker.clear();
    setState(() {
      _analyzing = true;
      _paused = false;
      _cancelRequested = false;
      _currentTimeMs = 0;
      _events.clear();
      _visibleBoxes = const [];
      _completedSession = null;
    });

    final stepMs = (1000 / _fps).round().clamp(100, 1000);
    final directory = await getApplicationDocumentsDirectory();

    try {
      for (var timeMs = 0; timeMs <= durationMs; timeMs += stepMs) {
        if (_cancelRequested || !mounted) break;
        while (_paused && !_cancelRequested && mounted) {
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
        if (_cancelRequested || !mounted) break;

        final frameBytes = await _videoChannel.invokeMethod<Uint8List>(
          'extractFrame',
          {'path': _videoPath, 'timeMs': timeMs, 'maxWidth': 1280},
        );
        if (frameBytes == null) continue;

        final rawResult = await _yolo.predict(
          frameBytes,
          confidenceThreshold: _confidence,
        );
        final detections = (rawResult['detections'] as List? ?? const [])
            .whereType<Map>()
            .map(YOLOResult.fromMap)
            .where(
              (result) => _hazardLabels.contains(
                result.className.trim().toLowerCase(),
              ),
            )
            .where((result) => result.confidence >= _confidence)
            .toList(growable: false);

        final tracked = _tracker.update(
          detections
              .map(
                (result) => HazardDetection(
                  label: result.className.trim(),
                  left: result.normalizedBox.left,
                  top: result.normalizedBox.top,
                  width: result.normalizedBox.width,
                  height: result.normalizedBox.height,
                ),
              )
              .toList(growable: false),
        );

        // Only uncaptured IDs are allowed to appear and be captured.
        final uncaptured = _tracker.uncaptured(tracked);
        final newCaptures = <({TrackedHazard tracked, double confidence})>[];
        for (var i = 0; i < tracked.length; i++) {
          final item = tracked[i];
          if (_tracker.isCaptured(item.id)) continue;
          _tracker.markCaptured(item.id);
          newCaptures.add((
            tracked: item,
            confidence: detections[i].confidence,
          ));
        }

        final decoded = await _decodeImage(frameBytes);
        final frameSize = Size(
          decoded.width.toDouble(),
          decoded.height.toDouble(),
        );

        for (final capture in newCaptures) {
          final eventTime = _startTime.add(Duration(milliseconds: timeMs));
          final annotatedBytes = await _renderAnnotatedPhoto(
            decoded,
            capture.tracked,
            capture.confidence,
          );
          final photoFile = File(
            '${directory.path}/road-hazard-${capture.tracked.id}-${eventTime.microsecondsSinceEpoch}.png',
          );
          await photoFile.writeAsBytes(annotatedBytes, flush: true);

          _events.insert(0, <String, dynamic>{
            'id': capture.tracked.id,
            'label': capture.tracked.label,
            'confidence': capture.confidence,
            'box': [
              capture.tracked.left,
              capture.tracked.top,
              capture.tracked.width,
              capture.tracked.height,
            ],
            'time': eventTime.toIso8601String(),
            'videoOffsetMs': timeMs,
            'manual': false,
            'photoPath': photoFile.path,
          });
        }

        decoded.dispose();

        if (!mounted) break;
        setState(() {
          _currentTimeMs = timeMs;
          _currentFrameBytes = frameBytes;
          _currentFrameSize = frameSize;
          // Captured IDs are hidden from subsequent frames.
          _visibleBoxes = uncaptured
              .where((item) => !_tracker.isCaptured(item.id))
              .toList(growable: false);
        });
      }

      if (mounted && !_cancelRequested) {
        final session = await _persistCompletedSession(
          durationMs > 0 ? (durationMs / 1000).round() : 0,
        );
        if (mounted) {
          setState(() => _completedSession = session);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Analisis selesai: ${_events.length} hazard unik terdeteksi.',
              ),
            ),
          );
        }
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Analisis video gagal: $error')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _analyzing = false;
          _paused = false;
        });
      }
    }
  }

  Future<ui.Image> _decodeImage(Uint8List bytes) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(bytes, completer.complete);
    return completer.future;
  }

  Future<Uint8List> _renderAnnotatedPhoto(
    ui.Image image,
    TrackedHazard hazard,
    double confidence,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final width = image.width.toDouble();
    final height = image.height.toDouble();

    canvas.drawImage(image, Offset.zero, Paint());

    final rect = Rect.fromLTWH(
      (hazard.left * width).clamp(0.0, width),
      (hazard.top * height).clamp(0.0, height),
      (hazard.width * width).clamp(1.0, width),
      (hazard.height * height).clamp(1.0, height),
    );

    final boxPaint = Paint()
      ..color = Colors.redAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = (width / 320).clamp(2.0, 5.0);
    canvas.drawRect(rect, boxPaint);

    final labelText =
        '${hazard.id} · ${hazard.label} ${(confidence * 100).toStringAsFixed(0)}%';
    final fontSize = (width / 42).clamp(14.0, 28.0);
    final textPainter = TextPainter(
      text: TextSpan(
        text: labelText,
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final pillWidth = textPainter.width + 16;
    final pillHeight = textPainter.height + 10;
    final pillTop = (rect.top - pillHeight).clamp(0.0, height - pillHeight);
    final pillLeft = rect.left.clamp(0.0, (width - pillWidth).clamp(0.0, width));

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(pillLeft, pillTop, pillWidth, pillHeight),
        const Radius.circular(6),
      ),
      Paint()..color = Colors.redAccent,
    );
    textPainter.paint(canvas, Offset(pillLeft + 8, pillTop + 5));

    final picture = recorder.endRecording();
    final rendered = await picture.toImage(image.width, image.height);
    final byteData = await rendered.toByteData(format: ui.ImageByteFormat.png);
    rendered.dispose();
    if (byteData == null) {
      throw StateError('Failed to encode annotated frame.');
    }
    return byteData.buffer.asUint8List();
  }

  Future<Map<String, dynamic>> _persistCompletedSession(
    int durationSeconds,
  ) async {
    final endTime = _startTime.add(Duration(seconds: durationSeconds));
    final counts = _countEvents(_events);
    final code =
        'RH-VID-${_startTime.year}${_two(_startTime.month)}${_two(_startTime.day)}-'
        '${_two(_startTime.hour)}${_two(_startTime.minute)}${_two(_startTime.second)}';
    final session = <String, dynamic>{
      'code': code,
      'source': 'video',
      'videoName': _videoName ?? '',
      'site': 'Video upload',
      'roadSection': _sectionController.text.trim().isEmpty
          ? 'Hauling Road'
          : _sectionController.text.trim(),
      'startTime': _startTime.toIso8601String(),
      'endTime': endTime.toIso8601String(),
      'durationSeconds': durationSeconds,
      'distanceMeters': 0.0,
      'potholesCount': counts['Potholes']!,
      'corrugationCount': counts['Corragation']!,
      'rutsCount': counts['Ruts']!,
      'severity': _severityFor(_events.length),
      'summaryNotes': _summaryController.text.trim(),
      'events': List<Map<String, dynamic>>.from(_events.reversed),
    };

    final file = File(
      '${(await getApplicationDocumentsDirectory()).path}/$_sessionFile',
    );
    final existing = <Map<String, dynamic>>[];
    if (await file.exists()) {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is List) {
        existing.addAll(
          decoded.whereType<Map>().map((row) => Map<String, dynamic>.from(row)),
        );
      }
    }
    final insertIndex =
        existing.isNotEmpty && existing.first['code'] == 'DRAFT' ? 1 : 0;
    existing.insert(insertIndex, session);
    await file.writeAsString(jsonEncode(existing), flush: true);
    return session;
  }

  Map<String, int> _countEvents(Iterable<Map<String, dynamic>> events) {
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

  RoadHazardReport _buildReport(Map<String, dynamic> session) {
    final rawEvents = (session['events'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
    final events = rawEvents.map((event) {
      final photoPath = event['photoPath'] as String?;
      Uint8List? photoBytes;
      if (photoPath != null) {
        final file = File(photoPath);
        if (file.existsSync()) photoBytes = file.readAsBytesSync();
      }
      final offsetMs = event['videoOffsetMs'];
      return RoadHazardReportEvent(
        id: event['id'] as String? ?? '',
        label: event['label'] as String? ?? 'Other',
        confidence: (event['confidence'] as num?)?.toDouble() ?? 0,
        timestamp:
            DateTime.tryParse(event['time'] as String? ?? '') ?? _startTime,
        videoOffset: offsetMs is int ? Duration(milliseconds: offsetMs) : null,
        notes: event['notes'] as String?,
        photoBytes: photoBytes,
      );
    }).toList();

    return RoadHazardReport(
      sessionCode: session['code'] as String? ?? 'RH-VID',
      siteName: session['site'] as String? ?? 'Video upload',
      inspectorName: 'Field inspector',
      roadSection: session['roadSection'] as String? ?? 'Hauling Road',
      startTime:
          DateTime.tryParse(session['startTime'] as String? ?? '') ??
          _startTime,
      endTime:
          DateTime.tryParse(session['endTime'] as String? ?? '') ?? _startTime,
      durationSeconds: session['durationSeconds'] as int? ?? 0,
      distanceMeters: 0,
      potholesCount: session['potholesCount'] as int? ?? 0,
      corrugationCount: session['corrugationCount'] as int? ?? 0,
      rutsCount: session['rutsCount'] as int? ?? 0,
      severity: session['severity'] as String? ?? 'LOW',
      summaryNotes: session['summaryNotes'] as String?,
      events: events,
    );
  }

  Future<void> _exportPdf() async {
    final session = _completedSession;
    if (session == null) return;
    final bytes = await _reportExporter.toPdf(_buildReport(session));
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/${session['code']}.pdf');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], subject: '${session['code']}.pdf'),
    );
  }

  Future<void> _exportExcel() async {
    final session = _completedSession;
    if (session == null) return;
    final bytes = _reportExporter.toXlsx(_buildReport(session));
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/${session['code']}.xlsx');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        subject: '${session['code']}.xlsx',
      ),
    );
  }

  Future<void> _shareWhatsApp() async {
    final session = _completedSession;
    if (session == null) return;
    final report = _buildReport(session);
    final text = [
      '*ROAD HAZARD VIDEO REPORT*',
      'Session: ${report.sessionCode}',
      'Road section: ${report.roadSection}',
      'Start: ${_formatDateTime(report.startTime)}',
      'Severity: ${report.severity}',
      'Total hazards: ${report.events.length}',
      'Potholes: ${report.potholesCount}, Corrugation: ${report.corrugationCount}, Ruts: ${report.rutsCount}',
    ].join('\n');
    final uri = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  String _two(int v) => v.toString().padLeft(2, '0');

  String _formatDateTime(DateTime dt) {
    final local = dt.toLocal();
    return '${local.year}-${_two(local.month)}-${_two(local.day)} '
        '${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}';
  }

  String _formatDurationMs(int ms) {
    final d = Duration(milliseconds: ms < 0 ? 0 : ms);
    return '${_two(d.inHours)}:${_two(d.inMinutes.remainder(60))}:${_two(d.inSeconds.remainder(60))}';
  }

  @override
  Widget build(BuildContext context) {
    final progress = _videoDurationMs > 0
        ? (_currentTimeMs / _videoDurationMs).clamp(0.0, 1.0)
        : 0.0;
    final counts = _countEvents(_events);

    return Scaffold(
      appBar: AppBar(title: const Text('Analisis Video Hazard')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_modelError != null)
              Card(
                color: Colors.red.shade900,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text('Model gagal dimuat: $_modelError'),
                ),
              ),
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: ColoredBox(
                  color: Colors.black,
                  child: _currentFrameBytes == null
                      ? Center(
                          child: Text(
                            _videoName == null
                                ? 'Pilih video inspeksi jalan untuk dianalisis'
                                : _videoName!,
                            textAlign: TextAlign.center,
                          ),
                        )
                      : LayoutBuilder(
                          builder: (context, constraints) => Stack(
                            fit: StackFit.expand,
                            children: [
                              Image.memory(
                                _currentFrameBytes!,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                              ),
                              if (_currentFrameSize != null &&
                                  _visibleBoxes.isNotEmpty)
                                CustomPaint(
                                  painter: _VideoBoxPainter(
                                    boxes: _visibleBoxes,
                                    imageSize: _currentFrameSize!,
                                    viewSize: constraints.biggest,
                                  ),
                                ),
                              Positioned(
                                left: 10,
                                bottom: 10,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black87,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    '${_formatDateTime(_startTime.add(Duration(milliseconds: _currentTimeMs)))} '
                                    '(${_formatDurationMs(_currentTimeMs)})',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            if (_analyzing || _currentTimeMs > 0) ...[
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 4),
              Text(
                'Progress: ${(progress * 100).toStringAsFixed(0)}% · '
                '${_formatDurationMs(_currentTimeMs)} / ${_formatDurationMs(_videoDurationMs)}',
              ),
              const SizedBox(height: 10),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _analyzing ? null : _pickVideo,
                  icon: const Icon(Icons.video_library_outlined),
                  label: Text(_videoPath == null ? 'Upload Video' : 'Ganti Video'),
                ),
                OutlinedButton.icon(
                  onPressed: _analyzing ? null : _pickStartDateTime,
                  icon: const Icon(Icons.schedule),
                  label: Text('Mulai: ${_formatDateTime(_startTime)}'),
                ),
                if (!_analyzing)
                  FilledButton.icon(
                    onPressed: (_modelReady && _videoPath != null)
                        ? _startAnalysis
                        : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Analisis Video'),
                  )
                else ...[
                  FilledButton.tonalIcon(
                    onPressed: () => setState(() => _paused = !_paused),
                    icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                    label: Text(_paused ? 'Lanjutkan' : 'Jeda'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => setState(() => _cancelRequested = true),
                    icon: const Icon(Icons.stop),
                    label: const Text('Batal'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Sampling FPS: '),
                const SizedBox(width: 8),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 1, label: Text('1 FPS')),
                    ButtonSegment(value: 2, label: Text('2 FPS')),
                    ButtonSegment(value: 5, label: Text('5 FPS')),
                  ],
                  selected: {_fps},
                  onSelectionChanged: _analyzing
                      ? null
                      : (selected) => setState(() => _fps = selected.first),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text('Confidence ${(100 * _confidence).round()}%'),
                ),
                Expanded(
                  flex: 2,
                  child: Slider(
                    value: _confidence,
                    min: 0.1,
                    max: 0.9,
                    divisions: 16,
                    onChanged: _analyzing
                        ? null
                        : (value) => setState(() => _confidence = value),
                  ),
                ),
              ],
            ),
            TextField(
              controller: _sectionController,
              enabled: !_analyzing,
              decoration: const InputDecoration(
                labelText: 'Road section',
                prefixIcon: Icon(Icons.route),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _summaryController,
              enabled: !_analyzing,
              minLines: 2,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Ringkasan / rekomendasi',
                prefixIcon: Icon(Icons.notes),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _statCard('Total', _events.length, Colors.blue),
                _statCard('Potholes', counts['Potholes']!, Colors.red),
                _statCard('Corrugation', counts['Corragation']!, Colors.orange),
                _statCard('Ruts', counts['Ruts']!, Colors.amber),
              ],
            ),
            if (_completedSession != null) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _exportPdf,
                    icon: const Icon(Icons.picture_as_pdf),
                    label: const Text('Export PDF'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _exportExcel,
                    icon: const Icon(Icons.table_chart),
                    label: const Text('Export Excel'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _shareWhatsApp,
                    icon: const Icon(Icons.share),
                    label: const Text('WhatsApp'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            Text(
              'Hasil Deteksi (${_events.length})',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            if (_events.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('Belum ada hazard terdeteksi.'),
              )
            else
              ..._events.map((event) {
                final photoPath = event['photoPath'] as String?;
                final file = photoPath == null ? null : File(photoPath);
                final offsetMs = event['videoOffsetMs'] as int? ?? 0;
                final time =
                    DateTime.tryParse(event['time'] as String? ?? '') ??
                    _startTime;
                return Card(
                  child: ListTile(
                    leading: file != null && file.existsSync()
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(
                              file,
                              width: 56,
                              height: 56,
                              fit: BoxFit.cover,
                            ),
                          )
                        : const Icon(Icons.warning_amber_rounded),
                    title: Text('${event['id']} · ${event['label']}'),
                    subtitle: Text(
                      '${(((event['confidence'] as num?) ?? 0) * 100).toStringAsFixed(0)}% · '
                      '${_formatDateTime(time)} · Offset ${_formatDurationMs(offsetMs)}',
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _statCard(String label, int value, Color color) => Expanded(
    child: Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Column(
          children: [
            Text(label, style: TextStyle(fontSize: 11, color: color)),
            const SizedBox(height: 2),
            Text(
              '$value',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    ),
  );
}

class _VideoBoxPainter extends CustomPainter {
  const _VideoBoxPainter({
    required this.boxes,
    required this.imageSize,
    required this.viewSize,
  });

  final List<TrackedHazard> boxes;
  final Size imageSize;
  final Size viewSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (imageSize.width <= 0 || imageSize.height <= 0) return;
    final fitted = applyBoxFit(BoxFit.contain, imageSize, viewSize);
    final dst = fitted.destination;
    final dx = (viewSize.width - dst.width) / 2;
    final dy = (viewSize.height - dst.height) / 2;

    final paint = Paint()
      ..color = Colors.redAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;

    for (final box in boxes) {
      final rect = Rect.fromLTWH(
        dx + box.left * dst.width,
        dy + box.top * dst.height,
        box.width * dst.width,
        box.height * dst.height,
      );
      canvas.drawRect(rect, paint);

      final tp = TextPainter(
        text: TextSpan(
          text: '${box.id} · ${box.label}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final pill = Rect.fromLTWH(
        rect.left,
        (rect.top - tp.height - 6).clamp(0.0, viewSize.height),
        tp.width + 10,
        tp.height + 6,
      );
      canvas.drawRect(pill, Paint()..color = Colors.redAccent);
      tp.paint(canvas, Offset(pill.left + 5, pill.top + 3));
    }
  }

  @override
  bool shouldRepaint(covariant _VideoBoxPainter oldDelegate) =>
      oldDelegate.boxes != boxes ||
      oldDelegate.imageSize != imageSize ||
      oldDelegate.viewSize != viewSize;
}
