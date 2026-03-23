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
  Timer? _arpTimer; // ARP scan for hotspot mode
  
  final _deviceController = StreamController<List<SharedDeviceInfo>>.broadcast();
  final Map<String, SharedDeviceInfo> _discoveredDevicesMap = {};

  Stream<List<SharedDeviceInfo>> get deviceStream => _deviceController.stream;

  // Safe send — never throws, just prints on error
  void _safeSend(List<int> bytes, InternetAddress address) {
    try {
      _socket?.send(bytes, address, _broadcastPort);
    } catch (e) {
      // Silently ignore unreachable addresses — this is normal in hotspot mode
    }
  }

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
    
    // Join Multicast group (optional, may fail on some systems)
    try {
      _socket?.joinMulticast(InternetAddress('224.0.0.1'));
    } catch (e) {
      // Multicast not supported on this interface — fine
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

              // Direct response if it's a broadcast
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

    // 2. Start broadcasting every 3s
    _broadcastTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      _sendBroadcast(deviceId, deviceName, port, deviceType);
    });

    // 3. Stale cleanup every 15s
    _cleanupTimer = Timer.periodic(const Duration(seconds: 15), (timer) {
      final now = DateTime.now();
      bool changed = false;
      _discoveredDevicesMap.removeWhere((id, device) {
        if (now.difference(device.lastSeen).inSeconds > 60) {
          changed = true;
          return true;
        }
        return false;
      });
      if (changed) _deviceController.add(_discoveredDevicesMap.values.toList());
    });

    // 4. ARP scan timer — critical for Linux hotspot mode
    // When PC is the hotspot, the phone connects but might not respond to UDP broadcasts.
    // The ARP table tells us which devices are connected, so we can target them directly.
    if (Platform.isLinux) {
      _arpTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
        _scanArpTable(deviceId, deviceName, port, deviceType);
      });
    }

    // Initial broadcast
    _sendBroadcast(deviceId, deviceName, port, deviceType);
    
    // Also do an initial ARP scan
    if (Platform.isLinux) {
      _scanArpTable(deviceId, deviceName, port, deviceType);
    }
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
    
    // 1. Try global broadcast (may fail in hotspot mode — that's OK)
    _safeSend(bytes, InternetAddress('255.255.255.255'));
    
    // 2. Iterate through all network interfaces
    try {
      final interfaces = await NetworkInterface.list();
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            final parts = addr.address.split('.');
            if (parts.length == 4) {
              final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
              
              // Subnet broadcast
              _safeSend(bytes, InternetAddress('$prefix.255'));
              
              // Gateway and edges
              _safeSend(bytes, InternetAddress('$prefix.1'));
              _safeSend(bytes, InternetAddress('$prefix.254'));
              
              // Full subnet sweep — ensures discovery even if broadcasts are blocked
              for (int i = 2; i < 254; i++) {
                if (parts[3] != i.toString()) {
                  _safeSend(bytes, InternetAddress('$prefix.$i'));
                }
              }
            }
          }
        }
      }
    } catch (e) {
      print('Interface enumeration error: $e');
    }
  }

  /// Scan Linux ARP table for connected devices and send targeted discovery to them.
  /// This is the most reliable way to find devices on a hosted hotspot.
  Future<void> _scanArpTable(String id, String name, int port, String type) async {
    try {
      final arpData = await File('/proc/net/arp').readAsString();
      final message = json.encode({
        'msgType': 'broadcast',
        'id': id,
        'name': name,
        'port': port,
        'type': type,
      });
      final bytes = utf8.encode(message);
      
      final lines = arpData.split('\n');
      for (final line in lines) {
        // 0x2 means the ARP entry is valid/active (device is connected)
        if (line.contains('0x2')) {
          final parts = line.trim().split(RegExp(r'\s+'));
          if (parts.isNotEmpty) {
            final ip = parts[0];
            // Only send to private IPs
            if (ip.startsWith('10.') || ip.startsWith('192.168.') || ip.startsWith('172.')) {
              _safeSend(bytes, InternetAddress(ip));
            }
          }
        }
      }
    } catch (e) {
      // /proc/net/arp not accessible — not critical
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
    _safeSend(bytes, target);
  }

  void addDevice(SharedDeviceInfo device) {
    _discoveredDevicesMap[device.id] = device;
    _deviceController.add(_discoveredDevicesMap.values.toList());
  }

  /// Refresh a device's lastSeen to keep it alive in the list.
  void refreshDeviceByIp(String ip) {
    bool changed = false;
    for (final entry in _discoveredDevicesMap.entries) {
      if (entry.value.ip == ip) {
        _discoveredDevicesMap[entry.key] = entry.value.copyWith(lastSeen: DateTime.now());
        changed = true;
      }
    }
    if (changed) _deviceController.add(_discoveredDevicesMap.values.toList());
  }

  /// Add a device if not present, or refresh its lastSeen if already known.
  /// Uses IP as the matching key to avoid duplicates.
  void addOrRefreshDevice(SharedDeviceInfo device) {
    String? existingKey;
    for (final entry in _discoveredDevicesMap.entries) {
      if (entry.value.ip == device.ip) {
        existingKey = entry.key;
        break;
      }
    }
    if (existingKey != null) {
      _discoveredDevicesMap[existingKey] = _discoveredDevicesMap[existingKey]!.copyWith(
        lastSeen: DateTime.now(),
        port: device.port,
        name: device.name.startsWith('Link:') || device.name.startsWith('Host') 
            ? _discoveredDevicesMap[existingKey]!.name
            : device.name,
      );
    } else {
      _discoveredDevicesMap[device.id] = device;
    }
    _deviceController.add(_discoveredDevicesMap.values.toList());
  }

  Future<void> stop() async {
    _broadcastTimer?.cancel();
    _cleanupTimer?.cancel();
    _arpTimer?.cancel();
    _socket?.close();
    _socket = null;
    _discoveredDevicesMap.clear();
    _deviceController.add([]);
  }

  Future<void> restart({required int port}) async {
    await stop();
    await Future.delayed(const Duration(seconds: 3));
    await start(port: port);
  }
}
