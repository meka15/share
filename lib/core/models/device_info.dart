import 'dart:convert';

class SharedDeviceInfo {
  final String id;
  final String name;
  final String ip;
  final int port;
  final String type; // Mobile or Desktop
  final bool isTrusted;
  final DateTime lastSeen;

  SharedDeviceInfo({
    required this.id,
    required this.name,
    required this.ip,
    required this.port,
    required this.type,
    this.isTrusted = false,
    DateTime? lastSeen,
  }) : this.lastSeen = lastSeen ?? DateTime.now();

  SharedDeviceInfo copyWith({
    String? id,
    String? name,
    String? ip,
    int? port,
    String? type,
    bool? isTrusted,
    DateTime? lastSeen,
  }) {
    return SharedDeviceInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      type: type ?? this.type,
      isTrusted: isTrusted ?? this.isTrusted,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'ip': ip,
      'port': port,
      'type': type,
      'isTrusted': isTrusted,
      'lastSeen': lastSeen.millisecondsSinceEpoch,
    };
  }

  factory SharedDeviceInfo.fromMap(Map<String, dynamic> map) {
    return SharedDeviceInfo(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      ip: map['ip'] ?? '',
      port: map['port'] ?? 0,
      type: map['type'] ?? 'unknown',
      isTrusted: map['isTrusted'] ?? false,
      lastSeen: map['lastSeen'] != null ? DateTime.fromMillisecondsSinceEpoch(map['lastSeen']) : null,
    );
  }

  String toJson() => json.encode(toMap());

  factory SharedDeviceInfo.fromJson(String source) => SharedDeviceInfo.fromMap(json.decode(source));

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SharedDeviceInfo && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
