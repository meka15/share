import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';

class StorageUtil {
  static Future<String> getReceivedFilesPath() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/received_files';
    final directory = Directory(path);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return path;
  }

  static Future<void> openFile(String filePath) async {
    await OpenFilex.open(filePath);
  }
}
