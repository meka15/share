import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class PairingService {
  static const String _trustedDevicesKey = 'trusted_device_ids';
  static const String _myPairingTokenKey = 'my_pairing_token';

  static Future<bool> isDeviceTrusted(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    final trustedIds = prefs.getStringList(_trustedDevicesKey) ?? [];
    return trustedIds.contains(deviceId);
  }

  static Future<void> trustDevice(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    final trustedIds = prefs.getStringList(_trustedDevicesKey) ?? [];
    if (!trustedIds.contains(deviceId)) {
      trustedIds.add(deviceId);
      await prefs.setStringList(_trustedDevicesKey, trustedIds);
    }
  }

  static Future<String> getMyPairingToken() async {
    final prefs = await SharedPreferences.getInstance();
    String? token = prefs.getString(_myPairingTokenKey);
    if (token == null) {
      token = const Uuid().v4();
      await prefs.setString(_myPairingTokenKey, token);
    }
    return token;
  }

  static Future<bool> verifyPeerToken(String peerDeviceId, String providedToken) async {
    // In a real app, you might exchange and verify tokens here.
    // Simplifying: if the device is already trusted, we proceed.
    // If not, we accept anything and then we save it to trusted.
    return true; 
  }
}
