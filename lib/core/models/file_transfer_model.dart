enum TransferStatus { pending, inProgress, completed, failed, cancelled }

class FileTransferModel {
  final String id;
  final String fileName;
  final int fileSize;
  final String? filePath;
  final double progress;
  final double speedInMBps;
  final String? timeRemaining;
  final TransferStatus status;
  final String? error;
  final bool isIncoming;
  final String peerName;

  FileTransferModel({
    required this.id,
    required this.fileName,
    required this.fileSize,
    this.filePath,
    this.progress = 0.0,
    this.speedInMBps = 0.0,
    this.timeRemaining,
    this.status = TransferStatus.pending,
    this.error,
    this.isIncoming = false,
    required this.peerName,
  });

  FileTransferModel copyWith({
    String? id,
    String? fileName,
    int? fileSize,
    String? filePath,
    double? progress,
    double? speedInMBps,
    String? timeRemaining,
    TransferStatus? status,
    String? error,
    bool? isIncoming,
    String? peerName,
  }) {
    return FileTransferModel(
      id: id ?? this.id,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      filePath: filePath ?? this.filePath,
      progress: progress ?? this.progress,
      speedInMBps: speedInMBps ?? this.speedInMBps,
      timeRemaining: timeRemaining ?? this.timeRemaining,
      status: status ?? this.status,
      error: error ?? this.error,
      isIncoming: isIncoming ?? this.isIncoming,
      peerName: peerName ?? this.peerName,
    );
  }
}
