import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart' hide Response;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../models/file_transfer_model.dart';
import 'pairing_service.dart';
import '../utils/device_util.dart';

typedef OnIncomingFileCallback = Future<bool> Function(String fileName, String peerName);

class FileTransferService {
  HttpServer? _server;
  final Dio _dio = Dio();
  final _transferController = StreamController<FileTransferModel>.broadcast();
  Stream<FileTransferModel> get transferStream => _transferController.stream;

  final Map<String, FileTransferModel> _activeTransfers = {};

  OnIncomingFileCallback? onIncomingFile;

  Future<int> startServer() async {
    final router = Router();

    // 0. Connectivity check
    router.get('/ping', (Request request) => Response.ok('pong'));

    // 1. Initial connection / permission check
    router.post('/connect', (Request request) async {
      final payload = await request.readAsString();
      // Handle handshake / pairing here
      return Response.ok('Connected');
    });

    // 2. Receive file from peer
    router.post('/upload', (Request request) async {
      final peerName = request.headers['x-peer-name'] ?? 'Unknown Peer';
      final peerId = request.headers['x-peer-id'] ?? 'unknown_id';
      final fileName = request.headers['x-file-name'] ?? 'unknown_file';
      final fileSize = int.tryParse(request.headers['x-file-size'] ?? '0') ?? 0;
      final transferId = const Uuid().v4();

      // Check if trusted
      final isTrusted = await PairingService.isDeviceTrusted(peerId);
      if (!isTrusted) {
        // UI callback to accept or reject
        final accepted = await (onIncomingFile?.call(fileName, peerName) ?? Future.value(false));
        if (!accepted) {
          return Response.forbidden('Rejected by user');
        }
        await PairingService.trustDevice(peerId);
      }

      final dir = await getApplicationDocumentsDirectory();
      final shareDir = Directory('${dir.path}/received_files');
      if (!await shareDir.exists()) await shareDir.create(recursive: true);

      final filePath = '${shareDir.path}/${DateTime.now().millisecondsSinceEpoch}_$fileName';
      final file = File(filePath);
      final sink = file.openWrite();

      final model = FileTransferModel(
        id: transferId,
        fileName: fileName,
        fileSize: fileSize,
        filePath: filePath,
        isIncoming: true,
        peerName: peerName,
        status: TransferStatus.inProgress,
      );
      _activeTransfers[transferId] = model;
      _transferController.add(model);

      int receivedBytes = 0;
      final startTime = DateTime.now();

      try {
        await for (var chunk in request.read()) {
          sink.add(chunk);
          receivedBytes += chunk.length;
          
          final elapsed = DateTime.now().difference(startTime).inMilliseconds / 1000;
          final speed = elapsed > 0 ? (receivedBytes / (1024 * 1024)) / elapsed : 0.0;
          final remainingBytes = fileSize - receivedBytes;
          final etaSeconds = speed > 0 ? (remainingBytes / (1024 * 1024)) / speed : 0.0;
          final timeRemaining = _formatDuration(etaSeconds);

          final progress = receivedBytes / fileSize;
          
          final updatedModel = model.copyWith(
            progress: progress,
            speedInMBps: speed,
            timeRemaining: timeRemaining,
          );
          _activeTransfers[transferId] = updatedModel;
          _transferController.add(updatedModel);
        }
        await sink.close();
        
        final finalModel = _activeTransfers[transferId]!.copyWith(
          status: TransferStatus.completed,
          progress: 1.0,
        );
        _activeTransfers[transferId] = finalModel;
        _transferController.add(finalModel);
        
        return Response.ok('File received');
      } catch (e) {
        await sink.close();
        final errorModel = _activeTransfers[transferId]!.copyWith(
          status: TransferStatus.failed,
          error: e.toString(),
        );
        _activeTransfers[transferId] = errorModel;
        _transferController.add(errorModel);
        return Response.internalServerError(body: e.toString());
      }
    });

    _server = await shelf_io.serve(router, InternetAddress.anyIPv4, 0);
    print('Server running on port ${_server!.port}');
    return _server!.port;
  }

  Future<void> sendFile({
    required String peerIp,
    required int peerPort,
    required File file,
    required String myName,
  }) async {
    final fileName = path.basename(file.path);
    final fileSize = await file.length();
    final transferId = const Uuid().v4();

    final model = FileTransferModel(
      id: transferId,
      fileName: fileName,
      fileSize: fileSize,
      filePath: file.path,
      isIncoming: false,
      peerName: 'Peer ($peerIp)',
      status: TransferStatus.inProgress,
    );
    _activeTransfers[transferId] = model;
    _transferController.add(model);

    final myId = await DeviceUtil.getUniqueDeviceId();
    final startTime = DateTime.now();

    try {
      final response = await _dio.post(
        'http://$peerIp:$peerPort/upload',
        data: file.openRead(),
        options: Options(
          headers: {
            'x-peer-name': myName,
            'x-peer-id': myId,
            'x-file-name': fileName,
            'x-file-size': fileSize.toString(),
            'Content-Type': 'application/octet-stream',
          },
        ),
        onSendProgress: (sent, total) {
          final elapsed = DateTime.now().difference(startTime).inMilliseconds / 1000;
          final speed = elapsed > 0 ? (sent / (1024 * 1024)) / elapsed : 0.0;
          final remainingBytes = total - sent;
          final etaSeconds = speed > 0 ? (remainingBytes / (1024 * 1024)) / speed : 0.0;
          final timeRemaining = _formatDuration(etaSeconds);

          final progress = sent / total;
          final updatedModel = _activeTransfers[transferId]!.copyWith(
            progress: progress,
            speedInMBps: speed,
            timeRemaining: timeRemaining,
          );
          _activeTransfers[transferId] = updatedModel;
          _transferController.add(updatedModel);
        },
      );

      if (response.statusCode == 200) {
        final finalModel = _activeTransfers[transferId]!.copyWith(
          status: TransferStatus.completed,
          progress: 1.0,
        );
        _activeTransfers[transferId] = finalModel;
        _transferController.add(finalModel);
      } else {
        throw Exception('Failed to send file: ${response.statusMessage}');
      }
    } catch (e) {
      final errorModel = _activeTransfers[transferId]!.copyWith(
        status: TransferStatus.failed,
        error: e.toString(),
      );
      _activeTransfers[transferId] = errorModel;
      _transferController.add(errorModel);
      rethrow;
    }
  }

  Future<void> stopServer() async {
    await _server?.close();
  }

  String _formatDuration(double seconds) {
    if (seconds.isInfinite || seconds.isNaN || seconds < 0) return 'calc...';
    if (seconds < 60) return '${seconds.toInt()}s';
    final minutes = seconds / 60;
    if (minutes < 60) return '${minutes.toInt()}m ${ (seconds % 60).toInt()}s';
    return '> 1h';
  }
}
