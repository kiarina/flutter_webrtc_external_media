import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'loopback.dart';

void main() => runApp(const MaterialApp(home: Smoke()));

class Smoke extends StatefulWidget {
  const Smoke({super.key});
  @override
  State<Smoke> createState() => _Smoke();
}

class _Smoke extends State<Smoke> {
  String status = 'Starting';
  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(milliseconds: 200), run);
  }

  Future<void> run() async {
    final report = <String, dynamic>{
      'kind': 'external-source-native-smoke',
      'hardwareCapture': false,
      'errors': <String>[]
    };
    RTCExternalMediaSource? source;
    try {
      if (Platform.environment['EXTERNAL_MEDIA_LOOPBACK'] == '1') {
        report['kind'] = 'synthetic-local-rtp';
        report['loopback'] = await loopback();
      } else {
        source = await RTCExternalMediaSource.create();
        await source.pushAudio(Uint8List(960));
        final image = Uint8List(320 * 240 * 4);
        for (var i = 0; i < image.length; i += 4) {
          image[i] = 40;
          image[i + 1] = 100;
          image[i + 2] = 160;
          image[i + 3] = 255;
        }
        await source.pushVideo(image, 320, 240, 1);
        report['stats'] = await source.stats();
        report['renderReference'] = source.hasRenderReference;
        report['timestampSource'] = source.videoTimestampSource;
        await source.flush();
        await source.dispose();
        await source.dispose();
        source = null;
      }
    } catch (e, st) {
      (report['errors'] as List<String>).add('$e');
      report['stack'] = '$st';
    } finally {
      try {
        await source?.dispose();
      } catch (e) {
        (report['errors'] as List<String>).add('cleanup: $e');
      }
      final output = Platform.environment['EXTERNAL_MEDIA_RESULT'];
      if (output != null) {
        try {
          File(output).writeAsStringSync(jsonEncode(report));
        } catch (e) {
          report['artifactWriteError'] = '$e';
        }
      }
      // Machine-readable test report.
      // ignore: avoid_print
      print('EXTERNAL_MEDIA_REPORT ${jsonEncode(report)}');
      if (mounted) {
        setState(() => status = (report['errors'] as List).isEmpty
            ? 'DONE'
            : 'ERROR ${report['errors']}');
      }
      if (Platform.environment['EXTERNAL_MEDIA_EXIT'] == '1') {
        await Future<void>.delayed(const Duration(seconds: 1));
        exit((report['errors'] as List).isEmpty ? 0 : 1);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('External media source smoke')),
      body: Center(child: Text(status)));
}
