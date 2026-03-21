import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:ui';
import '../../core/utils/storage_util.dart';
import '../../core/models/device_info.dart';
import '../../core/models/file_transfer_model.dart';
import '../../core/services/pairing_service.dart';
import '../../core/utils/device_util.dart';
import '../../main.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<SharedDeviceInfo> _devices = [];
  final List<FileTransferModel> _transfers = [];

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    // 1. Permissions
    if (Platform.isAndroid) {
      await [
        Permission.storage,
        Permission.location,
        Permission.nearbyWifiDevices,
      ].request();
    }

    // 2. Start Services
    final port = await AppConfig.transferService.startServer();
    await AppConfig.discoveryService.start(port: port);

    // 3. Listen for discovery
    AppConfig.discoveryService.deviceStream.listen((devices) {
      if (mounted) setState(() => _devices = devices);
    });

    // 4. Listen for transfers
    AppConfig.transferService.transferStream.listen((transfer) {
      if (mounted) {
        setState(() {
          final index = _transfers.indexWhere((t) => t.id == transfer.id);
          if (index != -1) {
            _transfers[index] = transfer;
          } else {
            _transfers.insert(0, transfer);
          }
        });
      }
    });

    // 5. Handle incoming file dialog
    AppConfig.transferService.onIncomingFile = (fileName, peerName) async {
      return await _showAcceptDialog(fileName, peerName);
    };
  }

  Future<bool> _showAcceptDialog(String fileName, String peerName) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Incoming File'),
        content: Text('$peerName wants to send you:\n$fileName'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Decline'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Accept'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _sendFile(SharedDeviceInfo device) async {
    final result = await FilePicker.platform.pickFiles();
    if (result != null && result.files.single.path != null) {
      final file = File(result.files.single.path!);
      final myName = await DeviceUtil.getDeviceName();
      
      try {
        await AppConfig.transferService.sendFile(
          peerIp: device.ip,
          peerPort: device.port,
          file: file,
          myName: myName,
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text('Antigravity Share', style: GoogleFonts.outfit(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              AppConfig.discoveryService.stop().then((_) {
                _initializeApp();
              });
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          _buildAnimatedBackground(),
          SafeArea(
            child: Column(
              children: [
                _buildDeviceSection(),
                const Divider(color: Colors.white24, indent: 24, endIndent: 24),
                _buildTransferSection(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnimatedBackground() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0F2027), Color(0xFF203A43), Color(0xFF2C5364)],
        ),
      ),
    );
  }

  Widget _buildDeviceSection() {
    return Expanded(
      flex: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Text('Nearby Devices', style: GoogleFonts.outfit(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white)),
          ),
          if (_devices.isEmpty)
            const Expanded(child: Center(child: Text('Scanning for devices...', style: TextStyle(color: Colors.white70))))
          else
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _devices.length,
                itemBuilder: (context, index) {
                  final dev = _devices[index];
                  return _buildGlassCard(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Colors.white10,
                        child: Icon(dev.type == 'mobile' ? Icons.phone_android : Icons.computer, color: Colors.blueAccent),
                      ),
                      title: Text(dev.name, style: GoogleFonts.outfit(color: Colors.white)),
                      subtitle: Text(dev.ip, style: const TextStyle(color: Colors.white54)),
                      trailing: ElevatedButton.icon(
                        onPressed: () => _sendFile(dev),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blueAccent.withOpacity(0.2),
                          foregroundColor: Colors.blueAccent,
                        ),
                        icon: const Icon(Icons.send_rounded),
                        label: Text('Send', style: GoogleFonts.outfit()),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTransferSection() {
    return Expanded(
      flex: 3,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Text('Transfers', style: GoogleFonts.outfit(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white)),
          ),
          if (_transfers.isEmpty)
            const Expanded(child: Center(child: Text('No active transfers', style: TextStyle(color: Colors.white70))))
          else
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _transfers.length,
                itemBuilder: (context, index) {
                  final transfer = _transfers[index];
                  return _buildGlassCard(
                    child: ListTile(
                      title: Text(transfer.fileName, style: GoogleFonts.outfit(color: Colors.white)),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(transfer.isIncoming ? 'From: ${transfer.peerName}' : 'To: ${transfer.peerName}', style: const TextStyle(color: Colors.white70)),
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: transfer.progress,
                              backgroundColor: Colors.white10,
                              minHeight: 8,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                '${(transfer.progress * 100).toInt()}% • ${transfer.speedInMBps.toStringAsFixed(1)} MB/s',
                                style: const TextStyle(fontSize: 12, color: Colors.white54),
                              ),
                              if (transfer.status == TransferStatus.inProgress)
                                Text(
                                  'ETA: ${transfer.timeRemaining}',
                                  style: const TextStyle(fontSize: 12, color: Colors.blueAccent),
                                ),
                            ],
                          ),
                        ],
                      ),
                      trailing: _buildStatusAction(transfer),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildGlassCard({required Widget child}) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _buildStatusAction(FileTransferModel transfer) {
    if (transfer.status == TransferStatus.completed && transfer.isIncoming && transfer.filePath != null) {
      return IconButton(
        icon: const Icon(Icons.open_in_new_rounded, color: Colors.greenAccent),
        onPressed: () => StorageUtil.openFile(transfer.filePath!),
      );
    }
    return _getStatusIcon(transfer.status);
  }

  Widget _getStatusIcon(TransferStatus status) {
    switch (status) {
      case TransferStatus.completed:
        return const Icon(Icons.check_circle, color: Colors.green);
      case TransferStatus.failed:
        return const Icon(Icons.error, color: Colors.red);
      case TransferStatus.inProgress:
        return const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2));
      default:
        return const Icon(Icons.access_time);
    }
  }
}
