import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'dart:isolate';

class StreamOption {
  final StreamInfo streamInfo;
  final String type; // 'muxed', 'video-only', or 'audio-only'
  final String quality;

  StreamOption(this.streamInfo, this.type, this.quality);
}

class DownloadParams {
  final String url;
  final String filePath;
  final String videoTitle;
  final SendPort sendPort;
  final StreamInfo streamInfo;
  final String streamType;

  DownloadParams({
    required this.url,
    required this.filePath,
    required this.videoTitle,
    required this.sendPort,
    required this.streamInfo,
    required this.streamType,
  });
}

Future<String> downloadVideoInBackground(DownloadParams params) async {
  try {
    final yt = YoutubeExplode();

    final stream = yt.videos.streamsClient.get(params.streamInfo);
    final file = File(params.filePath);
    final fileStream = file.openWrite();
    int bytesReceived = 0;
    final totalBytes = params.streamInfo.size.totalBytes;

    await for (final chunk in stream) {
      bytesReceived += chunk.length;
      final progress = bytesReceived / totalBytes;
      params.sendPort.send(progress);
      fileStream.add(chunk);
    }

    await fileStream.flush();
    await fileStream.close();

    yt.close();

    return 'Download completed! Saved to: ${params.filePath} (${params.streamType} stream)';
  } catch (e) {
    return 'Error: $e';
  }
}

class YouTubeDownloaderHomePage extends StatefulWidget {
  const YouTubeDownloaderHomePage({super.key});

  @override
  _YouTubeDownloaderHomePageState createState() =>
      _YouTubeDownloaderHomePageState();
}

class _YouTubeDownloaderHomePageState extends State<YouTubeDownloaderHomePage> {
  final TextEditingController _urlController = TextEditingController();
  String _status = '';
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  List<FileSystemEntity> _downloadedFiles = [];
  bool _permissionsGranted = false;

  @override
  void initState() {
    super.initState();
    _requestListPermissions();
  }

  Future<void> _requestListPermissions() async {
    if (Platform.isAndroid) {
      final permissionsGranted = await _promptAndRequestListPermissions();
      setState(() {
        _permissionsGranted = permissionsGranted;
        if (permissionsGranted) {
          _loadDownloadedFiles();
        } else {
          _status =
              'Permissions required to list downloaded files. Please grant in settings.';
        }
      });
    } else {
      setState(() {
        _permissionsGranted = true;
      });
      _loadDownloadedFiles();
    }
  }

  Future<bool> _promptAndRequestListPermissions() async {
    bool allGranted = true;
    int sdkInt = 0;

    if (Platform.isAndroid) {
      final deviceInfo = await DeviceInfoPlugin().androidInfo;
      sdkInt = deviceInfo.version.sdkInt;
    }

    if (Platform.isAndroid) {
      if (sdkInt >= 33) {
        // Android 13+: Request media permissions for listing
        allGranted = await _requestMediaPermissions();
      } else {
        // Android 12 and below: Request storage permission for listing
        allGranted = await _requestStoragePermission();
      }
    }

    if (!allGranted) {
      if (await Permission.storage.isPermanentlyDenied ||
          await Permission.videos.isPermanentlyDenied) {
        await openAppSettings();
      }
    }

    return allGranted;
  }

  Future<bool> _requestMediaPermissions() async {
    bool videosGranted = await _showPermissionDialog(
      title: 'Video Access Permission',
      message:
          'This app needs access to videos to list downloaded YouTube videos in the Download folder.',
      permission: Permission.videos,
    );

    return videosGranted;
  }

  Future<bool> _requestStoragePermission() async {
    return await _showPermissionDialog(
      title: 'Storage Access Permission',
      message:
          'This app needs access to storage to list downloaded YouTube videos in the Download folder.',
      permission: Permission.storage,
    );
  }

  Future<bool> _showPermissionDialog({
    required String title,
    required String message,
    required Permission permission,
  }) async {
    bool granted = false;

    if (await permission.isGranted) {
      return true;
    }

    bool? shouldRequest = true;

    if (shouldRequest == true) {
      final status = await permission.request();
      granted = status.isGranted;
    }

    return granted;
  }

  Future<void> _loadDownloadedFiles() async {
    if (!_permissionsGranted) return;

    final directory = await _getDownloadDirectory();
    try {
      if (await directory.exists()) {
        final files =
            await directory
                .list()
                .where((file) => file is File && file.path.endsWith('.mp4'))
                .toList();
        setState(() {
          _downloadedFiles = files;
        });
      }
    } catch (e) {
      setState(() {
        _status = 'Error accessing downloaded files: $e';
      });
    }
  }

  Future<Directory> _getDownloadDirectory() async {
    if (Platform.isAndroid) {
      final directory = Directory(
        '/storage/emulated/0/Download/youtubedownloader',
      );
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      return directory;
    } else {
      return await getApplicationDocumentsDirectory();
    }
  }

  Future<String> getFilePath(String videoTitle) async {
    final sanitizedTitle = videoTitle.replaceAll(RegExp(r'[^\w\s-]'), '');
    final fileName = '$sanitizedTitle.mp4';
    final directory = await _getDownloadDirectory();
    final filePath = path.join(directory.path, fileName);

    final file = File(filePath);
    if (await file.exists()) {
      final baseName = path.basenameWithoutExtension(fileName);
      final extension = path.extension(fileName);
      int counter = 1;
      String newFilePath;
      do {
        newFilePath = path.join(
          directory.path,
          '$baseName ($counter)$extension',
        );
        counter++;
      } while (await File(newFilePath).exists());
      return newFilePath;
    }

    return filePath;
  }

  Future<List<StreamOption>> _getAvailableStreams(String url) async {
    final yt = YoutubeExplode();
    try {
      final video = await yt.videos.get(url);
      final videoId = video.id.value;
      final manifest = await yt.videos.streamsClient.getManifest(videoId);

      List<StreamOption> streams = [];

      for (var stream in manifest.muxed) {
        streams.add(
          StreamOption(
            stream,
            'muxed',
            '${stream.videoResolution} (${stream.bitrate.toString().split(' ').first})',
          ),
        );
      }

      for (var stream in manifest.video) {
        streams.add(
          StreamOption(
            stream,
            'video-only',
            '${stream.videoResolution} (${stream.bitrate.toString().split(' ').first})',
          ),
        );
      }

      for (var stream in manifest.audio) {
        streams.add(
          StreamOption(
            stream,
            'audio-only',
            '${stream.audioCodec} (${stream.bitrate.toString().split(' ').first})',
          ),
        );
      }

      return streams;
    } finally {
      yt.close();
    }
  }

  Future<void> _showStreamSelectionDialog(String url, String videoTitle) async {
    if (!_permissionsGranted) {
      setState(() {
        _status = 'Please grant permissions to list and save files.';
      });
      await _requestListPermissions();
      return;
    }

    setState(() {
      _status = 'Fetching available streams...';
    });

    try {
      final streams = await _getAvailableStreams(url);

      if (streams.isEmpty) {
        setState(() {
          _status = 'Error: No suitable streams found';
        });
        return;
      }

      final selectedStream = await showDialog<StreamOption>(
        context: context,
        builder:
            (context) => AlertDialog(
              title: const Text('Select Stream'),
              content: SizedBox(
                width: double.maxFinite,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: streams.length,
                  itemBuilder: (context, index) {
                    final stream = streams[index];
                    return ListTile(
                      title: Text('${stream.type}'),
                      subtitle: Text('Quality: ${stream.quality}'),
                      onTap: () {
                        Navigator.of(context).pop(stream);
                      },
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ],
            ),
      );

      if (selectedStream != null) {
        await _downloadVideo(url, videoTitle, selectedStream);
      } else {
        setState(() {
          _status = '';
        });
      }
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
      });
    }
  }

  Future<void> _downloadVideo(
    String url,
    String videoTitle,
    StreamOption selectedStream,
  ) async {
    setState(() {
      _isDownloading = true;
      _status = 'Starting download...';
      _downloadProgress = 0.0;
    });

    try {
      // Request write permissions for saving files
      bool writeGranted = true;
      if (Platform.isAndroid) {
        final sdkInt = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
        if (sdkInt < 33) {
          writeGranted = await _showPermissionDialog(
            title: 'Storage Write Permission',
            message:
                'This app needs write access to storage to save downloaded YouTube videos.',
            permission: Permission.storage,
          );
        }
      }

      if (!writeGranted) {
        setState(() {
          _status = 'Write permissions denied. Please grant in settings.';
          _isDownloading = false;
        });
        return;
      }

      final filePath = await getFilePath(videoTitle);

      final directory = File(filePath).parent;
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      final receivePort = ReceivePort();
      receivePort.listen((message) {
        if (message is double) {
          setState(() {
            _downloadProgress = message;
          });
        }
      });

      final result = await compute(
        downloadVideoInBackground,
        DownloadParams(
          url: url,
          filePath: filePath,
          videoTitle: videoTitle,
          sendPort: receivePort.sendPort,
          streamInfo: selectedStream.streamInfo,
          streamType: selectedStream.type,
        ),
      );

      receivePort.close();

      await _loadDownloadedFiles();

      setState(() {
        _status = result;
        _isDownloading = false;
      });
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
        _isDownloading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text(
          'YouTube Downloader',
          style: TextStyle(fontWeight: FontWeight.w600, color: Colors.white),
        ),
        backgroundColor: const Color(0xFF2196F3),
        elevation: 0,
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Input Section
                Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Download a Video',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF2196F3),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _urlController,
                          decoration: InputDecoration(
                            hintText: 'Paste YouTube video URL here',
                            hintStyle: TextStyle(color: Colors.grey[600]),
                            filled: true,
                            fillColor: Colors.white,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                            prefixIcon: const Icon(
                              Icons.link,
                              color: Color(0xFF2196F3),
                            ),
                            suffixIcon:
                                _urlController.text.isNotEmpty
                                    ? IconButton(
                                      icon: const Icon(
                                        Icons.clear,
                                        color: Colors.grey,
                                      ),
                                      onPressed: () {
                                        setState(() {
                                          _urlController.clear();
                                          _status = '';
                                        });
                                      },
                                    )
                                    : null,
                          ),
                          style: const TextStyle(color: Colors.black87),
                          keyboardType: TextInputType.url,
                          onSubmitted: (value) {
                            if (value.isNotEmpty && !_isDownloading) {
                              _fetchVideoAndShowStreams(value);
                            }
                          },
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFF2196F3), Color(0xFF64B5F)],
                              ),
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.2),
                                  blurRadius: 6,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: ElevatedButton(
                              onPressed:
                                  _isDownloading
                                      ? null
                                      : () {
                                        if (_urlController.text.isNotEmpty) {
                                          _fetchVideoAndShowStreams(
                                            _urlController.text,
                                          );
                                        } else {
                                          setState(() {
                                            _status =
                                                'Please enter a valid URL';
                                          });
                                        }
                                      },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                shadowColor: Colors.transparent,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child:
                                  _isDownloading
                                      ? const Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          SizedBox(
                                            width: 24,
                                            height: 24,
                                            child: CircularProgressIndicator(
                                              color: Colors.white,
                                              strokeWidth: 2.5,
                                            ),
                                          ),
                                          SizedBox(width: 12),
                                          Text(
                                            'Downloading...',
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ],
                                      )
                                      : const Text(
                                        'Start Download',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                        ),
                                      ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                // Progress and Status Section
                if (_isDownloading || _status.isNotEmpty)
                  Card(
                    elevation: 4,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_isDownloading) ...[
                            LinearProgressIndicator(
                              value: _downloadProgress,
                              backgroundColor: Colors.grey[200],
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                Color(0xFF2196F3),
                              ),
                              minHeight: 8,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Progress: ${(_downloadProgress * 100).toStringAsFixed(1)}%',
                              style: const TextStyle(
                                fontSize: 14,
                                color: Color(0xFF2196F3),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                          if (_status.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Icon(
                                  _status.contains('Error')
                                      ? Icons.error_outline
                                      : _status.contains('completed')
                                      ? Icons.check_circle_outline
                                      : Icons.info_outline,
                                  color:
                                      _status.contains('Error')
                                          ? Colors.red
                                          : _status.contains('completed')
                                          ? Colors.green
                                          : Colors.grey,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _status,
                                    style: TextStyle(
                                      fontSize: 14,
                                      color:
                                          _status.contains('Error')
                                              ? Colors.red
                                              : _status.contains('completed')
                                              ? Colors.green
                                              : Colors.grey[700],
                                      fontStyle:
                                          _status.contains('Error')
                                              ? FontStyle.normal
                                              : FontStyle.italic,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 20),

                const Text(
                  'Your Downloads',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF2196F3),
                  ),
                ),
                const SizedBox(height: 12),
                _downloadedFiles.isEmpty
                    ? Card(
                      elevation: 4,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Center(
                          child: Text(
                            'No videos downloaded yet.\nStart downloading to see them here!',
                            style: TextStyle(
                              color: Colors.grey,
                              fontSize: 14,
                              height: 1.5,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    )
                    : ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _downloadedFiles.length,
                      itemBuilder: (context, index) {
                        final file = _downloadedFiles[index] as File;
                        final fileName = path.basename(file.path);
                        final fileSize = (file.statSync().size / (1024 * 1024))
                            .toStringAsFixed(2);
                        return Card(
                          elevation: 2,
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            leading: const Icon(
                              Icons.video_library,
                              color: Color(0xFF2196F3),
                              size: 40,
                            ),
                            title: Text(
                              fileName,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                                color: Colors.black87,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              'Size: $fileSize MB',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[600],
                              ),
                            ),
                            onTap: () {
                              // Optional: Add action to open/play the video
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Tapped: $fileName'),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            },
                          ),
                        );
                      },
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _fetchVideoAndShowStreams(String url) async {
    try {
      final yt = YoutubeExplode();
      final video = await yt.videos.get(url);
      final videoTitle = video.title;
      yt.close();
      await _showStreamSelectionDialog(url, videoTitle);
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
      });
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }
}
