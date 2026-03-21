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

    // 1. Setup listening socket
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _broadcastPort);
    _socket?.broadcastEnabled = true;

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
    _cleanupTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      final now = DateTime.now();
      bool changed = false;
      _discoveredDevicesMap.removeWhere((id, device) {
        if (now.difference(device.lastSeen).inSeconds > 10) {
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
              // Try the subnet broadcast (e.g., 192.168.x.255)
              final subnetBroadcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
              _socket?.send(bytes, InternetAddress(subnetBroadcast), _broadcastPort);
              
              // If we are a client, the host/hotspot is almost always at .1
              if (parts[3] != '1') {
                final gateway = '${parts[0]}.${parts[1]}.${parts[2]}.1';
                _socket?.send(bytes, InternetAddress(gateway), _broadcastPort);
              }

              // iPhone Hotspot standard: 172.20.10.1 (subnet broadcast 172.20.10.15)
              if (addr.address.startsWith('172.20.10.')) {
                 _socket?.send(bytes, InternetAddress('172.20.10.255'), _broadcastPort);
                 _socket?.send(bytes, InternetAddress('172.20.10.1'), _broadcastPort);
              }
              
              // Standard Android Hotspot: 192.168.43.x
              if (addr.address.startsWith('192.168.43.')) {
                 _socket?.send(bytes, InternetAddress('192.168.43.255'), _broadcastPort);
                 _socket?.send(bytes, InternetAddress('192.168.43.1'), _broadcastPort);
              }
              
              // Windows Hotspot: 192.168.137.x
              if (addr.address.startsWith('192.168.137.')) {
                 _socket?.send(bytes, InternetAddress('192.168.137.255'), _broadcastPort);
                 _socket?.send(bytes, InternetAddress('192.168.137.1'), _broadcastPort);
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
    _socket?.send(utf8.encode(message), target, _broadcastPort);
  }

  Future<void> stop() async {
    _broadcastTimer?.cancel();
    _cleanupTimer?.cancel();
    _socket?.close();
    _discoveredDevicesMap.clear();
    _deviceController.add([]);
  }
}
