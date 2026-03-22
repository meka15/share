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
        await WiFiForIoTPlugin.setWiFiAPEnabled(true);
        return true;
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
             if (line.endsWith(':wifi')) {
               wifiInterface = line.split(':')[0];
               break;
             }
           }
        }

        final args = ['device', 'wifi', 'hotspot', 'ssid', ssid, 'password', password];
        if (wifiInterface != null) {
          args.addAll(['ifname', wifiInterface]);
        }
        
        final result = await Process.run('nmcli', args);
        if (result.exitCode != 0) {
           // Final fallback without ifname
           final resultNoIf = await Process.run('nmcli', ['device', 'wifi', 'hotspot', 'ssid', ssid, 'password', password]);
           return resultNoIf.exitCode == 0;
        }
        return true;
      } catch (e) {
        print('Linux Hotspot error: $e');
        return false;
      }
    } else if (Platform.isWindows) {
      try {
        // Note: netsh hostednetwork is legacy, but often works for simple cases.
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
        // Find wifi interface dynamically
        final ifaceResult = await Process.run('nmcli', ['-t', '-f', 'DEVICE,TYPE', 'device']);
        String wifiInterface = 'wlan0'; // Default fallback
        if (ifaceResult.exitCode == 0) {
           for (final line in ifaceResult.stdout.toString().split('\n')) {
             if (line.endsWith(':wifi')) {
               wifiInterface = line.split(':')[0];
                                 break;
             }
           }
        }
        await Process.run('nmcli', ['device', 'set', wifiInterface, 'managed', 'yes']);
        await Process.run('nmcli', ['device', 'disconnect', wifiInterface]);
        
        // Clean up: delete hotspot connections to avoid clutter
        final connResult = await Process.run('nmcli', ['-t', '-f', 'NAME,TYPE', 'connection', 'show']);
        if (connResult.exitCode == 0) {
          for (final line in connResult.stdout.toString().split('\n')) {
            if (line.contains('Hotspot') && line.endsWith(':802-11-wireless')) {
               final name = line.split(':')[0];
               await Process.run('nmcli', ['connection', 'delete', name]);
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
        // Disconnect from current if needed
        await WiFiForIoTPlugin.disconnect();
        
        final success = await WiFiForIoTPlugin.connect(
          ssid,
          password: password,
          security: NetworkSecurity.WPA,
          joinOnce: true,
        );
        
        if (!success) return false;

        // NEW: Wait for actual connection state
        for (int i = 0; i < 15; i++) {
           final isConnected = await WiFiForIoTPlugin.isConnected();
           final currentSsid = await WiFiForIoTPlugin.getSSID();
           if (isConnected && (currentSsid == ssid || currentSsid == '"$ssid"')) {
              // Force usage of this network even if it has no internet
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
        // Windows joining via CMD is complex (needs XML profile), 
        // but simple netsh command can work if profile exists.
        // We'll try to use a PowerShell snippet for a more modern approach.
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
      't': type, // 'p' for pc_config, 'd' for direct_connect
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
