import 'dart:convert';
import 'dart:io';
import 'package:wifi_iot/wifi_iot.dart';
import 'package:network_info_plus/network_info_plus.dart';

class ConnectivityService {
  static final _info = NetworkInfo();

  static Future<bool> isOnLan() async {
    final ip = await getLocalIp();
    return ip != null && ip != '0.0.0.0';
  }

  static Future<String?> getLocalIp() async {
    try {
      // 1. Try iterating through all interfaces first for accuracy
      final interfaces = await NetworkInterface.list();
      
      // Look for any valid IPv4 that is not loopback
      // Prefer wifi-looking names but take anything that has an address
      for (final interface in interfaces) {
        final name = interface.name.toLowerCase();
        // Priority to wifi/hotspot interfaces
        if (name.contains('wlan') || name.contains('ap') || name.contains('wlp') || name.contains('p2p')) {
          for (final addr in interface.addresses) {
            if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) return addr.address;
          }
        }
      }

      // 2. Secondary check for anything else
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) return addr.address;
        }
      }

      // 3. Fallback to NetworkInfo (might return null if no WAN)
      final wifiIp = await _info.getWifiIP().timeout(const Duration(milliseconds: 500), onTimeout: () => null);
      if (wifiIp != null && wifiIp != '0.0.0.0') return wifiIp;

      // 4. Android Special: If we are a Hotspot, we are almost always 192.168.43.1 or 192.168.44.1
      if (Platform.isAndroid) {
        final isApEn = await WiFiForIoTPlugin.isWiFiAPEnabled();
        if (isApEn) {
          return '192.168.43.1'; // Standard Android AP Gateway
        }
      }

    } catch (e) {
      print('Error getting local IP: $e');
    }
    return null;
  }

  // FORCE ANDROID to use current Wi-Fi even if it has no internet
  static Future<void> ensureLocalRouting() async {
     if (Platform.isAndroid) {
        try {
           final isConnected = await WiFiForIoTPlugin.isConnected();
           if (isConnected) {
              // Note: We used to filter by SSID, but for generic offline LANs we should force it whenever we are on WiFi
              await WiFiForIoTPlugin.forceWifiUsage(true);
              print('Android: Forcing WiFi usage for local routing.');
           }
        } catch (e) {
           print('Android Logic error: $e');
        }
     }
  }

  // --- Hotspot Management ---

  static Future<bool> startHotspot({required String ssid, required String password}) async {
    if (Platform.isAndroid) {
      try {
        print('Android: Force starting hotspot...');
        // Force wifi OFF first (often required to start AP)
        await WiFiForIoTPlugin.forceWifiUsage(false);
        await WiFiForIoTPlugin.setEnabled(false);
        await Future.delayed(const Duration(milliseconds: 500));
        
        final success = await WiFiForIoTPlugin.setWiFiAPEnabled(true);
        if (success) {
           print('Android Hotspot started successfully.');
           // Set the SSID/Password if supported (some plugins require separate call)
           // But usually WiFiForIoTPlugin.setWiFiAPEnabled(true) uses system settings.
           // For full control across all Android versions, this is sometimes limited.
        }
        return success;
      } catch (e) {
        print('Android Hotspot error: $e');
        return false;
      }
    } else if (Platform.isLinux) {
      try {
        // Find wifi interface dynamically
        final ifaceResult = await Process.run('nmcli', ['-t', '-f', 'DEVICE,TYPE', 'device']);
        String? wifiInterface;
        if (ifaceResult.exitCode == 0) {
           for (final line in ifaceResult.stdout.toString().split('\n')) {
             if (line.contains(':wifi')) {
               wifiInterface = line.split(':')[0];
               break;
             }
           }
        }

        if (wifiInterface == null) {
          print('Linux: No WiFi interface found.');
          return false;
        }

        const conName = 'Antigravity-Hotspot';
        await Process.run('nmcli', ['connection', 'delete', conName]);
        await Process.run('nmcli', ['device', 'set', wifiInterface, 'managed', 'yes']);
        await Process.run('nmcli', ['device', 'disconnect', wifiInterface]);

        final result = await Process.run('nmcli', [
          'device', 'wifi', 'hotspot', 
          'ifname', wifiInterface, 
          'con-name', conName, 
          'ssid', ssid, 
          'password', password
        ]);
        
        if (result.exitCode != 0) {
           print('Hotspot failed: ${result.stderr}');
           return false;
        }
        return true;
      } catch (e) {
        print('Linux Hotspot error: $e');
        return false;
      }
    } else if (Platform.isWindows) {
      try {
        await Process.run('netsh', ['wlan', 'set', 'hostednetwork', 'mode=allow', 'ssid=$ssid', 'key=$password']);
        final result = await Process.run('netsh', ['wlan', 'start', 'hostednetwork']);
        return result.exitCode == 0;
      } catch (e) {
        print('Windows Hotspot error: $e');
        return false;
      }
    }
    return false;
  }

  static Future<void> ensureWifiOn() async {
    if (Platform.isAndroid) {
      await WiFiForIoTPlugin.setEnabled(true);
    } else if (Platform.isLinux) {
      await Process.run('nmcli', ['radio', 'wifi', 'on']);
      await Process.run('rfkill', ['unblock', 'wifi']);
    } else if (Platform.isWindows) {
      await Process.run('netsh', ['interface', 'set', 'interface', 'name="Wi-Fi"', 'admin=enabled']);
    }
  }

  static Future<void> stopHotspot() async {
    if (Platform.isAndroid) {
      await WiFiForIoTPlugin.forceWifiUsage(false);
      await WiFiForIoTPlugin.setWiFiAPEnabled(false);
    } else if (Platform.isLinux) {
      try {
        final conName = 'Antigravity-Hotspot';
        await Process.run('nmcli', ['connection', 'down', conName]);
        await Process.run('nmcli', ['connection', 'delete', conName]);
        
        final ifaceResult = await Process.run('nmcli', ['-t', '-f', 'DEVICE,TYPE', 'device']);
        if (ifaceResult.exitCode == 0) {
           for (final line in ifaceResult.stdout.toString().split('\n')) {
             if (line.contains(':wifi')) {
               final iface = line.split(':')[0];
               await Process.run('nmcli', ['device', 'set', iface, 'managed', 'yes']);
             }
           }
        }
      } catch (e) {
         print('Linux Stop Hotspot error: $e');
      }
    } else if (Platform.isWindows) {
      await Process.run('netsh', ['wlan', 'stop', 'hostednetwork']);
    }
  }

  // --- WiFi Client Actions ---

  static Future<bool> connectToWifi({required String ssid, required String password}) async {
    if (Platform.isAndroid) {
      try {
        print('Android: Force enabling WiFi before connection...');
        await WiFiForIoTPlugin.setEnabled(true);
        await Future.delayed(const Duration(seconds: 1));

        await WiFiForIoTPlugin.disconnect();
        
        final success = await WiFiForIoTPlugin.connect(
          ssid,
          password: password,
          security: NetworkSecurity.WPA,
          joinOnce: true,
        );
        
        if (!success) return false;

        for (int i = 0; i < 15; i++) {
           final isConnected = await WiFiForIoTPlugin.isConnected();
           final currentSsid = await WiFiForIoTPlugin.getSSID();
           if (isConnected && (currentSsid == ssid || currentSsid == '"$ssid"')) {
              await WiFiForIoTPlugin.forceWifiUsage(true);
              return true;
           }
           await Future.delayed(const Duration(seconds: 1));
        }
        return false;
      } catch (e) {
        return false;
      }
    } else if (Platform.isLinux) {
      try {
        final result = await Process.run('nmcli', [
          'device', 'wifi', 'connect', ssid, 'password', password
        ]);
        return result.exitCode == 0;
      } catch (e) {
        return false;
      }
    } else if (Platform.isWindows) {
      try {
        final psCommand = 'netsh wlan connect name="$ssid" ssid="$ssid"';
        final result = await Process.run('powershell', ['-Command', psCommand]);
        return result.exitCode == 0;
      } catch (e) {
        return false;
      }
    }
    return false;
  }

  // --- QR Data Handling ---

  static String generateQrData({
    required String type,
    required String ssid,
    required String password,
    String? ip,
    int? port,
  }) {
    return json.encode({
      't': type,
      's': ssid,
      'p': password,
      'i': ip,
      'v': port,
    });
  }

  static Map<String, dynamic>? parseQrData(String data) {
    try {
      return json.decode(data) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }
}
