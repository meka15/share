import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/device_info.dart';
import '../utils/device_util.dart';

class DiscoveryService {
  static const int _broadcastPort = 42424;
  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  Timer? _cleanupTimer;
  
  final _deviceController = StreamController<List<SharedDeviceInfo>>.broadcast();
  final Map<String, SharedDeviceInfo> _discoveredDevicesMap = {};

  Stream<List<SharedDeviceInfo>> get deviceStream => _deviceController.stream;

  Future<void> start({required int port}) async {
    final deviceName = await DeviceUtil.getDeviceName();
    final deviceId = await DeviceUtil.getUniqueDeviceId();
    final deviceType = deviceName.toLowerCase().contains('android') ? 'mobile' : 'desktop';

    // 1. Setup listening socket with reuse options
    _socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4, 
      _broadcastPort,
      reuseAddress: true,
      reusePort: true,
    );
    _socket?.broadcastEnabled = true;
    
    // Join Multicast group for more reliable discovery on some systems
    try {
      _socket?.joinMulticast(InternetAddress('224.0.0.1'));
      _socket?.joinMulticast(InternetAddress('239.255.255.250')); // SSDP group
    } catch (e) {
      print('Multicast join error: $e');
    }

    _socket?.listen((event) {
      if (event == RawSocketEvent.read) {
        final datagram = _socket?.receive();
        if (datagram != null) {
          try {
            final rawData = utf8.decode(datagram.data);
            final data = json.decode(rawData);
            if (data['id'] != deviceId) {
              final device = SharedDeviceInfo(
                id: data['id'],
                name: data['name'],
                ip: datagram.address.address,
                port: data['port'],
                type: data['type'] ?? 'unknown',
                lastSeen: DateTime.now(),
              );
              
              _discoveredDevicesMap[device.id] = device;
              _deviceController.add(_discoveredDevicesMap.values.toList());

              // Fix: Direct response if it's a broadcast
              if (data['msgType'] == 'broadcast') {
                _sendResponse(datagram.address, deviceId, deviceName, port, deviceType);
              }
            }
          } catch (e) {
            // Ignore malformed packets
          }
        }
      }
    });

    // 2. Start broadcasting
    _broadcastTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      _sendBroadcast(deviceId, deviceName, port, deviceType);
    });

    // 3. Stale cleanup
    _cleanupTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      final now = DateTime.now();
      bool changed = false;
      _discoveredDevicesMap.removeWhere((id, device) {
        if (now.difference(device.lastSeen).inSeconds > 20) {
          changed = true;
          return true;
        }
        return false;
      });
      if (changed) _deviceController.add(_discoveredDevicesMap.values.toList());
    });

    // Initial broadcast
    await _sendBroadcast(deviceId, deviceName, port, deviceType);
  }

  Future<void> _sendBroadcast(String id, String name, int port, String type) async {
    final message = json.encode({
      'msgType': 'broadcast',
      'id': id,
      'name': name,
      'port': port,
      'type': type,
    });
    final bytes = utf8.encode(message);
    
    // 1. Send to global broadcast address
    _socket?.send(bytes, InternetAddress('255.255.255.255'), _broadcastPort);
    
    // 2. Iterate through all network interfaces
    try {
      final interfaces = await NetworkInterface.list();
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            final parts = addr.address.split('.');
            if (parts.length == 4) {
              final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
              
              // Standard Subnet Broadcast
              _socket?.send(bytes, InternetAddress('$prefix.255'), _broadcastPort);
              
              // Proactive Gateway and Neighbors sweep
              // This is a life-saver for Android without WAN
              _socket?.send(bytes, InternetAddress('$prefix.1'), _broadcastPort);
              _socket?.send(bytes, InternetAddress('$prefix.254'), _broadcastPort);
              
              // Aggressive sweep for ALL IPs on the subnet
              // This ensures we find devices like the one at .79 even if broadcasts are blocked.
              // Sending 254 UDP packets is very fast on modern local networks.
              for (int i = 2; i < 255; i++) {
                if (parts[3] != i.toString()) {
                   _socket?.send(bytes, InternetAddress('$prefix.$i'), _broadcastPort);
                }
              }

              // Linux Specific: ARP Scavenger (Extremely reliable for Host mode)
              if (Platform.isLinux) {
                try {
                  final arpData = await File('/proc/net/arp').readAsString();
                  final lines = arpData.split('\n');
                  for (final line in lines) {
                    if (line.contains('0x2')) { // 0x2 means entry is valid/active
                       final parts = line.trim().split(RegExp(r'\s+'));
                       if (parts.isNotEmpty && parts[0].startsWith(prefix)) {
                          _socket?.send(bytes, InternetAddress(parts[0]), _broadcastPort);
                       }
                    }
                  }
                } catch (e) {
                  // Ignore if /proc/net/arp is not accessible
                }
              }
            }
          }
        }
      }
    } catch (e) {
      // Ignore network errors
    }
  }

  void _sendResponse(InternetAddress target, String id, String name, int port, String type) {
    final message = json.encode({
      'msgType': 'response',
      'id': id,
      'name': name,
      'port': port,
      'type': type,
    });
    final bytes = utf8.encode(message);
    _socket?.send(bytes, target, _broadcastPort);
    
    // Also send multicast response as fallback
    _socket?.send(bytes, InternetAddress('224.0.0.1'), _broadcastPort);
  }

  void addDevice(SharedDeviceInfo device) {
    _discoveredDevicesMap[device.id] = device;
    _deviceController.add(_discoveredDevicesMap.values.toList());
  }

  Future<void> stop() async {
    _broadcastTimer?.cancel();
    _cleanupTimer?.cancel();
    _socket?.close();
    _socket = null;
    _discoveredDevicesMap.clear();
    _deviceController.add([]);
  }

  Future<void> restart({required int port}) async {
    await stop();
    await Future.delayed(const Duration(seconds: 3)); // Increased delay for network stabilization
    await start(port: port);
  }

}
