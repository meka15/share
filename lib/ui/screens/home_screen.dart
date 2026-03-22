import 'dart:io';
import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:lottie/lottie.dart';
import '../../core/services/connectivity_service.dart';
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
  bool _isHotspotActive = false;
  bool _isHotspotStarting = false;
  String _myDeviceName = 'Unknown Device';
  String _myDeviceId = 'unknown_id';
  String? _myIp;
  String? _hotspotSsid;
  String? _hotspotPassword;

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

    _myDeviceName = await DeviceUtil.getDeviceName();
    _myDeviceId = await DeviceUtil.getUniqueDeviceId();
    await _refreshIp();
    if (mounted) setState(() {});

    // 3. Listen for discovery
    AppConfig.discoveryService.deviceStream.listen((devices) {
      if (mounted) {
        setState(() => _devices = devices);
        print('Discovered devices updated: ${devices.length}');
      }
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

    // 5. IP refresh loop (periodic check)
    Timer.periodic(const Duration(seconds: 10), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      _refreshIp();
      ConnectivityService.ensureLocalRouting(); // Android fix for no-internet wifi
    });

    // 6. Handle incoming file dialog
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

  Future<void> _showConnectionSheet() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _buildConnectionSheet(),
    );
  }

  Widget _buildConnectionSheet() {
    final isDesktop = Platform.isLinux || Platform.isWindows || Platform.isMacOS;

    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: const BoxDecoration(
        color: Color(0xFF16213E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 24),
          Text('Quick Connection', style: GoogleFonts.outfit(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 8),
          Text(isDesktop ? 'Share via PC QR' : 'Scan or Show QR to join', style: const TextStyle(color: Colors.white60)),
          const SizedBox(height: 32),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  if (_isHotspotActive) ...[
                    const Icon(Icons.wifi_tethering, size: 80, color: Colors.greenAccent),
                    const SizedBox(height: 16),
                    const Text('Hotspot is currently active', style: TextStyle(color: Colors.white70)),
                    const SizedBox(height: 24),
                    _buildActionButton(
                      icon: Icons.stop_circle_outlined,
                      title: 'Stop Hotspot',
                      subtitle: 'Revert to normal WiFi mode',
                      onTap: () async {
                        await ConnectivityService.stopHotspot();
                        setState(() {
                          _isHotspotActive = false;
                          _hotspotSsid = null;
                          _hotspotPassword = null;
                        });
                        Navigator.pop(context);
                      },
                    ),
                  ] else ...[
                    if (isDesktop) _buildPCConfigSection(),
                    if (!isDesktop) ...[
                      _buildActionButton(
                        icon: Icons.qr_code_scanner_rounded,
                        title: 'Scan QR Code',
                        subtitle: 'Ensures WiFi is on to join',
                        onTap: () async {
                          await ConnectivityService.stopHotspot();
                          await ConnectivityService.ensureWifiOn();
                          setState(() => _isHotspotActive = false);
                          _startScanner();
                        },
                      ),
                      const SizedBox(height: 16),
                      _buildActionButton(
                        icon: Icons.qr_code_rounded,
                        title: 'My Shared QR',
                        subtitle: 'Force starts hotspot to share',
                        onTap: () async {
                          final ssid = 'Share_${(await DeviceUtil.getDeviceName()).replaceAll(' ', '_')}';
                          const password = 'antigravity_share';
                          
                          setState(() => _isHotspotStarting = true);
                          final success = await ConnectivityService.startHotspot(ssid: ssid, password: password);
                          if (success) {
                            await AppConfig.discoveryService.restart(port: AppConfig.transferService.port);
                          }
                          setState(() {
                            _isHotspotActive = success;
                            _isHotspotStarting = false;
                          });
                          
                          if (mounted) _showMyQr(ssid: ssid, password: password);
                        },
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPCConfigSection() {
    // Desktop generates a QR that tells the Phone to start a hotspot
    // Fix: SSID and Password must be stable once we decide to host
    _hotspotSsid ??= 'Antigravity_${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}';
    _hotspotPassword ??= 'share_${DateTime.now().millisecondsSinceEpoch.toString().substring(6)}';
    
    final ssid = _hotspotSsid!;
    final password = _hotspotPassword!;
    
    // Include device info in QR for instant pairing on mobile
    final qrData = ConnectivityService.generateQrData(
      type: 'join_pc',
      ssid: ssid,
      password: password,
      ip: 'auto', // Will be solved as gateway .1
      port: AppConfig.transferService.port,
    );

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
          child: QrImageView(data: qrData, size: 200, version: QrVersions.auto),
        ),
        const SizedBox(height: 24),
        if (!_isHotspotActive && !_isHotspotStarting)
          ElevatedButton.icon(
            onPressed: () async {
              setState(() => _isHotspotStarting = true);
              final success = await ConnectivityService.startHotspot(ssid: ssid, password: password);
              if (success) {
                // Force restart discovery on PC host
                await AppConfig.discoveryService.restart(port: AppConfig.transferService.port);
                setState(() {
                  _isHotspotActive = true;
                  _isHotspotStarting = false;
                });
              } else {
                setState(() => _isHotspotStarting = false);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to start hotspot. Please check permissions.'), backgroundColor: Colors.red));
              }
            },
            icon: const Icon(Icons.flash_on),
            label: const Text('FORCE START LOCAL HOTSPOT'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent, foregroundColor: Colors.white),
          ),
        if (_isHotspotStarting)
          const Column(children: [CircularProgressIndicator(), SizedBox(height: 8), Text('Starting Hotspot...', style: TextStyle(color: Colors.white70))]),
        if (_isHotspotActive)
          const Column(children: [Icon(Icons.check_circle, color: Colors.greenAccent), SizedBox(height: 8), Text('Hotspot Active!', style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold))]),
        const SizedBox(height: 24),
        Text('Scan this QR with your Phone to join', style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('The phone will automatically connect to this PC.', style: const TextStyle(color: Colors.white70, fontSize: 13)),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(12)),
          child: Column(
            children: [
              Text('Step 2: Connect PC to this WiFi:', style: const TextStyle(color: Colors.white60, fontSize: 12)),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [const Text('SSID: ', style: TextStyle(color: Colors.white54)), Text(ssid, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))]),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [const Text('Pass: ', style: TextStyle(color: Colors.white54)), Text(password, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))]),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildActionButton({required IconData icon, required String title, required String subtitle, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(border: Border.all(color: Colors.white12), borderRadius: BorderRadius.circular(20)),
        child: Row(
          children: [
            Icon(icon, size: 32, color: Colors.blueAccent),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: GoogleFonts.outfit(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                Text(subtitle, style: const TextStyle(color: Colors.white60, fontSize: 12)),
              ]),
            ),
            const Icon(Icons.chevron_right, color: Colors.white24),
          ],
        ),
      ),
    );
  }

  void _startScanner() {
    Navigator.pop(context);
    showDialog(
      context: context,
      builder: (context) => Scaffold(
        appBar: AppBar(title: const Text('Scan Connection QR')),
        body: MobileScanner(
          onDetect: (capture) {
            final List<Barcode> barcodes = capture.barcodes;
            if (barcodes.isNotEmpty) {
              final String? code = barcodes.first.rawValue;
              if (code != null) {
                _handleQrDetected(code);
                Navigator.pop(context);
              }
            }
          },
        ),
      ),
    );
  }

  void _handleQrDetected(String code) async {
    final data = ConnectivityService.parseQrData(code);
    if (data == null) return;

    final ssid = data['s'];
    final pass = data['p'];

    if (data['t'] == 'join_pc') {
      // Automatically join the PC's hotspot
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Connecting to PC WiFi: $ssid...')));
      final success = await ConnectivityService.connectToWifi(ssid: ssid, password: pass);
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Joined! Forcing local routing...'), backgroundColor: Colors.green));
        await _refreshIp();
        
        await AppConfig.discoveryService.restart(port: AppConfig.transferService.port);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Starting discovery...')));
        await Future.delayed(const Duration(seconds: 4)); // Wait for server to be up

        if (_myIp != null) {
          final parts = _myIp!.split('.');
          if (parts.length == 4) {
             final gatewayIp = '${parts[0]}.${parts[1]}.${parts[2]}.1';
             AppConfig.discoveryService.addDevice(SharedDeviceInfo(
               id: 'pc_qr_${data['s']}', 
               name: 'Link: PC Host',
               ip: gatewayIp,
               port: (data['v'] != null && data['v'] != 0) ? data['v'] : 42424,
               type: 'desktop',
               lastSeen: DateTime.now(),
             ));
             print('Manually added PC Host at $gatewayIp');
          }
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to join PC WiFi. Please try manually.'), backgroundColor: Colors.red));
      }
    } else if (data['t'] == 'pc_host') {
      // Legacy or other direction: Phone starts hotspot
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Force starting Hotspot...')));
      final success = await ConnectivityService.startHotspot(ssid: ssid, password: pass);
      if (success) {
        await AppConfig.discoveryService.restart(port: AppConfig.transferService.port);
        setState(() => _isHotspotActive = true);
      }
    } else if (data['t'] == 'direct') {
      // Direct connection via IP
      final ip = data['i'];
      final port = data['v'] ?? AppConfig.transferService.port;
      
      if (ssid != null && ssid.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Joining network: $ssid...')));
        final success = await ConnectivityService.connectToWifi(ssid: ssid, password: pass ?? '');
        if (!success) {
           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to join network. Proceeding with discovery anyway.'), backgroundColor: Colors.orange));
        } else {
           await _refreshIp();
        }
      }

      await AppConfig.discoveryService.restart(port: AppConfig.transferService.port);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Discovering...')));
      await Future.delayed(const Duration(seconds: 4));

      if (ip != null && ip != '0.0.0.0') {
        AppConfig.discoveryService.addDevice(SharedDeviceInfo(
          id: 'manual_${DateTime.now().millisecondsSinceEpoch}',
          name: 'Link: Direct Device',
          ip: ip,
          port: (port == null || port == 0) ? 42424 : port,
          type: 'unknown',
          lastSeen: DateTime.now(),
        ));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Device resolved via Direct Link!'), backgroundColor: Colors.green));
      }
    }
  }

  Future<void> _refreshIp() async {
    for (int i = 0; i < 5; i++) {
      final ip = await ConnectivityService.getLocalIp();
      if (ip != null && ip != '0.0.0.0') {
        if (mounted) {
          final oldIp = _myIp;
          setState(() => _myIp = ip);
          print('IP Resolved: $_myIp');
          
          if (oldIp != ip) {
             // Restart discovery if IP changed to ensure we bind to new interfaces properly
             await AppConfig.discoveryService.restart(port: AppConfig.transferService.port);
          }

          // CRITICAL FIX: Manually add the Host/Gateway as a device for any private subnet.
          // This avoids the "dependent on internet" feeling since broadcasts are often blocked on offline Wi-Fi.
          if (Platform.isAndroid) {
             final parts = _myIp!.split('.');
             if (parts.length == 4) {
               final gatewayIp = '${parts[0]}.${parts[1]}.${parts[2]}.1';
               if (gatewayIp != _myIp) {
                 AppConfig.discoveryService.addDevice(SharedDeviceInfo(
                   id: 'auto_host_link',
                   name: 'Host Gateway (Direct)',
                   ip: gatewayIp,
                   port: 42425,
                   type: 'desktop',
                   lastSeen: DateTime.now(),
                 ));
               }
             }
          }
        }
        return;
      }
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  void _showMyQr({String? ssid, String? password}) async {
    final ip = await ConnectivityService.getLocalIp() ?? '0.0.0.0';
    final myName = await DeviceUtil.getDeviceName();
    final qrData = ConnectivityService.generateQrData(
      type: 'direct',
      ssid: ssid ?? '',
      password: password ?? '',
      ip: ip,
      port: AppConfig.transferService.port, 
    );

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        title: Text('My ID: $myName', style: const TextStyle(color: Colors.white)),
        content: Container(
          width: 250,
          height: 250,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
          child: QrImageView(data: qrData, size: 200),
        ),
      ),
    );
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
            tooltip: 'Refresh Discovery',
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Restarting services...'), duration: Duration(milliseconds: 500)));
              await _refreshIp();
              await AppConfig.discoveryService.restart(port: AppConfig.transferService.port);
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showConnectionSheet,
        backgroundColor: Colors.blueAccent,
        icon: const Icon(Icons.flash_on_rounded, color: Colors.white),
        label: Text('Quick Connect', style: GoogleFonts.outfit(fontWeight: FontWeight.bold, color: Colors.white)),
      ),
      body: Stack(
        children: [
          _buildAnimatedBackground(),
          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 60), // Space for transparent AppBar
                _buildMyDeviceInfo(),
                if (Platform.isLinux) _buildLinuxHint(),
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

  Widget _buildMyDeviceInfo() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: Colors.blueAccent.withOpacity(0.1),
            child: const Icon(Icons.person_outline, color: Colors.blueAccent),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_myDeviceName, style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold)),
                Text(
                   _myIp != null ? 'Local IP: $_myIp' : 'Offline - Join Wi-Fi or Hotspot',
                   style: TextStyle(
                     color: _myIp != null ? Colors.white54 : Colors.orangeAccent,
                     fontSize: 12,
                     fontWeight: _myIp != null ? FontWeight.normal : FontWeight.bold,
                   ),
                ),
              ],
            ),
          ),
          if (_isHotspotActive)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.greenAccent.withOpacity(0.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text('HOTSPOT ON', style: TextStyle(color: Colors.greenAccent, fontSize: 10, fontWeight: FontWeight.bold)),
            ),
        ],
      ),
    );
  }

  Widget _buildLinuxHint() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withOpacity(0.2)),
      ),
      child: const Row(
        children: [
          Icon(Icons.privacy_tip_outlined, color: Colors.orangeAccent, size: 16),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Linux Tip: If devices don\'t appear, ensure port 42424/udp is open in your firewall.',
              style: TextStyle(color: Colors.orangeAccent, fontSize: 11),
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
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Nearby Devices', style: GoogleFonts.outfit(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white)),
                const Icon(Icons.radar_rounded, color: Colors.blueAccent),
              ],
            ),
          ),
          if (_devices.isEmpty)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      height: 100,
                      child: Icon(Icons.wifi_tethering_outlined, size: 80, color: Colors.blueAccent.withOpacity(0.3)),
                    ),
                    const SizedBox(height: 16),
                    const Text('Scanning for devices...', style: TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
            )
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

