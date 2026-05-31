import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:sensors_plus/sensors_plus.dart';

import '../../../core/database/database.dart';
import '../../../core/providers/database_provider.dart';
import '../../poi/providers/poi_provider.dart';
import '../providers/camera_provider.dart';

enum _CameraFrameMode { native, screenFill }

class _PhotoProcessRequest {
  final String inputPath;
  final String outputPath;
  final double cropAspectRatio;

  const _PhotoProcessRequest({
    required this.inputPath,
    required this.outputPath,
    required this.cropAspectRatio,
  });
}

/// Runs on a background isolate (via [compute]): bakes the EXIF orientation into
/// the pixels and centre-crops to the requested aspect ratio.
String? _bakeAndCropPhoto(_PhotoProcessRequest request) {
  final bytes = File(request.inputPath).readAsBytesSync();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;

  final oriented = img.bakeOrientation(decoded);
  final cropped = _cropToAspect(oriented, request.cropAspectRatio);
  File(
    request.outputPath,
  ).writeAsBytesSync(img.encodeJpg(cropped, quality: 92));
  return request.outputPath;
}

img.Image _cropToAspect(img.Image source, double targetAspectRatio) {
  final imageAspectRatio = source.width / source.height;

  var cropX = 0;
  var cropY = 0;
  var cropWidth = source.width;
  var cropHeight = source.height;

  if (imageAspectRatio > targetAspectRatio) {
    cropWidth = (source.height * targetAspectRatio).round();
    cropX = ((source.width - cropWidth) / 2).round();
  } else if (imageAspectRatio < targetAspectRatio) {
    cropHeight = (source.width / targetAspectRatio).round();
    cropY = ((source.height - cropHeight) / 2).round();
  }

  return img.copyCrop(
    source,
    x: cropX,
    y: cropY,
    width: cropWidth,
    height: cropHeight,
  );
}

class CameraScreen extends ConsumerStatefulWidget {
  final String? poiId;

  const CameraScreen({super.key, this.poiId});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;
  FlashMode _flashMode = FlashMode.off;
  bool _isCameraReady = false;
  bool _isTakingPicture = false;
  Offset _gestureStartOffset = Offset.zero;
  Offset _gestureStartFocalPoint = Offset.zero;
  double _gestureStartScale = 1;
  double _minZoom = 1;
  double _maxZoom = 1;
  double _currentZoom = 1;
  double _gestureStartZoom = 1;
  DeviceOrientation _deviceOrientation = DeviceOrientation.portraitUp;
  StreamSubscription<AccelerometerEvent>? _accelerometerSub;
  final GlobalKey _previewBoundaryKey = GlobalKey();
  ui.Image? _frozenPreview;
  _CameraFrameMode _frameMode = _CameraFrameMode.native;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // The UI is locked to portrait, so the camera plugin never reports a
    // landscape device orientation. Read the physical orientation straight from
    // the accelerometer instead so the overlay and capture can follow it.
    _accelerometerSub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 200),
    ).listen(_handleAccelerometer);
    Future.microtask(() {
      ref.read(cameraProvider.notifier).initialize(widget.poiId);
      _initializeCameras();
    });
  }

  void _handleAccelerometer(AccelerometerEvent event) {
    final x = event.x;
    final y = event.y;
    final z = event.z;

    // Phone lying roughly flat (face up/down): keep the last orientation to
    // avoid jitter when neither horizontal axis dominates.
    if (z.abs() > 8.5 && x.abs() < 4 && y.abs() < 4) return;

    final DeviceOrientation next;
    // 1.5 m/s^2 hysteresis band so the overlay doesn't flip-flop near 45°.
    if (x.abs() > y.abs() + 1.5) {
      next = x > 0
          ? DeviceOrientation.landscapeRight
          : DeviceOrientation.landscapeLeft;
    } else if (y.abs() > x.abs() + 1.5) {
      next = y > 0
          ? DeviceOrientation.portraitUp
          : DeviceOrientation.portraitDown;
    } else {
      return;
    }

    if (next == _deviceOrientation || !mounted) return;
    setState(() => _deviceOrientation = next);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      if (mounted) setState(() => _isCameraReady = false);
      _controller = null;
      controller.dispose();
    } else if (state == AppLifecycleState.resumed && _cameras.isNotEmpty) {
      _initializeCamera(_cameras[_cameraIndex]);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _accelerometerSub?.cancel();
    _frozenPreview?.dispose();
    _controller?.dispose();
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _initializeCameras() async {
    try {
      final cameras = await availableCameras();
      if (!mounted) return;

      if (cameras.isEmpty) {
        ref.read(cameraProvider.notifier).setCameraError('No camera found.');
        return;
      }

      final backCameraIndex = cameras.indexWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
      );

      _cameras = cameras;
      _cameraIndex = backCameraIndex == -1 ? 0 : backCameraIndex;
      await _initializeCamera(_cameras[_cameraIndex]);
    } on CameraException catch (e) {
      if (!mounted) return;
      ref
          .read(cameraProvider.notifier)
          .setCameraError('Camera unavailable: ${e.description ?? e.code}');
    } catch (e) {
      if (!mounted) return;
      ref.read(cameraProvider.notifier).setCameraError('Camera error: $e');
    }
  }

  Future<void> _initializeCamera(CameraDescription camera) async {
    if (!mounted) return;
    setState(() => _isCameraReady = false);
    await _controller?.dispose();

    final controller = CameraController(
      camera,
      ResolutionPreset.max,
      enableAudio: false,
    );

    _controller = controller;

    try {
      await controller.initialize();
      await controller.setFlashMode(_flashMode);
      final minZoom = await controller.getMinZoomLevel();
      final maxZoom = await controller.getMaxZoomLevel();
      final initialZoom = math.max(1, minZoom).clamp(minZoom, maxZoom);
      await controller.setZoomLevel(initialZoom.toDouble());
      if (!mounted) return;
      setState(() {
        _minZoom = minZoom;
        _maxZoom = maxZoom;
        _currentZoom = initialZoom.toDouble();
        _isCameraReady = true;
      });
    } on CameraException catch (e) {
      if (!mounted) return;
      ref
          .read(cameraProvider.notifier)
          .setCameraError('Camera unavailable: ${e.description ?? e.code}');
    }
  }

  Future<void> _takePicture() async {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        _isTakingPicture) {
      return;
    }

    try {
      // Snapshot the live preview and freeze it underneath the spinner so the
      // camera feed doesn't visibly jump back to portrait while we process.
      await _freezePreview();
      if (!mounted) return;
      setState(() => _isTakingPicture = true);
      HapticFeedback.mediumImpact();
      final screenSize = MediaQuery.sizeOf(context);
      // The UI is locked to portrait, so MediaQuery always reports a portrait
      // size. When the device is held in landscape, invert the ratio so the
      // captured frame matches what the user actually sees.
      final rawAspectRatio = screenSize.width / screenSize.height;
      final screenAspectRatio = _isDeviceLandscape
          ? 1 / rawAspectRatio
          : rawAspectRatio;
      // Lock to the orientation we detected from the accelerometer (the plugin's
      // own value stays portrait because the UI is orientation-locked).
      await controller.lockCaptureOrientation(_captureOrientation);
      final file = await controller.takePicture();
      if (!mounted) return;
      final photoFile = File(file.path);
      // Bake the capture orientation into the pixels (and crop in Fill mode) so
      // the saved file is stored in the same orientation it was shot in,
      // regardless of whether downstream viewers honor EXIF.
      final visiblePhoto = await _processCapturedPhoto(
        photoFile,
        cropAspectRatio: _frameMode == _CameraFrameMode.screenFill
            ? screenAspectRatio
            : null,
      );
      if (!mounted) return;
      ref.read(cameraProvider.notifier).setCapturedPhoto(visiblePhoto);
    } on CameraException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Capture failed: ${e.description ?? e.code}')),
      );
    } finally {
      await _unlockCaptureOrientation(controller);
      if (mounted) {
        setState(() {
          _frozenPreview?.dispose();
          _frozenPreview = null;
          _isTakingPicture = false;
        });
      }
    }
  }

  Future<void> _freezePreview() async {
    try {
      final boundary =
          _previewBoundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return;

      final image = await boundary.toImage(
        pixelRatio: MediaQuery.devicePixelRatioOf(context),
      );
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _frozenPreview?.dispose();
        _frozenPreview = image;
      });
    } catch (_) {
      // Best-effort freeze; fall back to the live preview if the snapshot fails.
    }
  }

  Future<void> _unlockCaptureOrientation(CameraController controller) async {
    if (!controller.value.isInitialized) return;

    try {
      await controller.unlockCaptureOrientation();
    } on CameraException {
      // Capture has already finished; failing to unlock should not block the UI.
    }
  }

  Future<File> _processCapturedPhoto(
    File photoFile, {
    double? cropAspectRatio,
  }) async {
    // Native mode: the capture already carries the correct EXIF orientation, so
    // skip the expensive full-resolution decode/re-encode entirely and use the
    // file as-is. Image.file honours EXIF, so it still displays upright.
    if (cropAspectRatio == null) return photoFile;

    // Fill mode needs an actual pixel crop, so bake orientation + crop, but do
    // it on a background isolate so the heavy work doesn't jank the UI thread.
    try {
      final outFile = File(
        photoFile.path.replaceFirst(
          RegExp(r'\.(jpe?g|png)$', caseSensitive: false),
          '_oriented.jpg',
        ),
      );
      final result = await compute(
        _bakeAndCropPhoto,
        _PhotoProcessRequest(
          inputPath: photoFile.path,
          outputPath: outFile.path,
          cropAspectRatio: cropAspectRatio,
        ),
      );
      return result == null ? photoFile : File(result);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Photo processing failed, using original: $e')),
        );
      }
      return photoFile;
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2) return;

    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _initializeCamera(_cameras[_cameraIndex]);
  }

  Future<void> _toggleFlash() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final nextMode = _flashMode == FlashMode.off
        ? FlashMode.auto
        : FlashMode.off;

    try {
      await controller.setFlashMode(nextMode);
      if (!mounted) return;
      setState(() => _flashMode = nextMode);
    } on CameraException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Flash unavailable: ${e.description ?? e.code}'),
        ),
      );
    }
  }

  Future<void> _setZoom(double zoom) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final nextZoom = zoom.clamp(_minZoom, _maxZoom).toDouble();

    try {
      await controller.setZoomLevel(nextZoom);
      if (!mounted) return;
      setState(() => _currentZoom = nextZoom);
    } on CameraException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Zoom unavailable: ${e.description ?? e.code}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final camState = ref.watch(cameraProvider);

    if (camState.error != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  camState.error!,
                  style: const TextStyle(color: Colors.red, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    'Go Back',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (camState.capturedPhoto != null) {
      return _buildComparisonScreen(camState);
    }

    return _buildCameraScreen(camState);
  }

  Widget _buildCameraScreen(CameraState camState) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            key: _previewBoundaryKey,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildCameraPreview(camState),
                if (camState.referenceImage != null)
                  _buildReferenceOverlay(camState),
              ],
            ),
          ),
          // Frozen snapshot shown over the live feed while a capture is in
          // progress, so the preview appears to pause instead of flickering.
          if (_frozenPreview != null)
            Positioned.fill(
              child: RawImage(image: _frozenPreview, fit: BoxFit.cover),
            ),
          _buildTopBar(camState),
          _buildBottomControls(camState),
          if (_isTakingPicture)
            Container(
              color: Colors.black.withValues(alpha: 0.18),
              child: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCameraPreview(CameraState camState) {
    final controller = _controller;

    if (!_isCameraReady ||
        controller == null ||
        !controller.value.isInitialized) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onScaleStart: camState.referenceImage == null
          ? (_) => _gestureStartZoom = _currentZoom
          : null,
      onScaleUpdate: camState.referenceImage == null
          ? (details) => _setZoom(_gestureStartZoom * details.scale)
          : null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final previewAspectRatio = _cameraPreviewAspectRatio(
            controller,
            Size(constraints.maxWidth, constraints.maxHeight),
          );
          final preview = AspectRatio(
            aspectRatio: previewAspectRatio,
            child: CameraPreview(controller),
          );

          if (_frameMode == _CameraFrameMode.native) {
            return Center(child: preview);
          }

          return ClipRect(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: constraints.maxWidth,
                height: constraints.maxWidth / previewAspectRatio,
                child: preview,
              ),
            ),
          );
        },
      ),
    );
  }

  double _cameraPreviewAspectRatio(CameraController controller, Size viewport) {
    final nativeAspectRatio = controller.value.aspectRatio;
    final isViewportLandscape = viewport.width >= viewport.height;
    final isPreviewLandscape = nativeAspectRatio >= 1;

    if (isViewportLandscape == isPreviewLandscape) {
      return nativeAspectRatio;
    }

    return 1 / nativeAspectRatio;
  }

  int get _cameraUiQuarterTurns {
    // Quarter turns needed to keep the portrait-locked UI upright for the user
    // given the physical device orientation.
    switch (_deviceOrientation) {
      case DeviceOrientation.landscapeRight:
        return 1;
      case DeviceOrientation.landscapeLeft:
        return 3;
      case DeviceOrientation.portraitDown:
        return 2;
      case DeviceOrientation.portraitUp:
        return 0;
    }
  }

  bool get _isDeviceLandscape =>
      _deviceOrientation == DeviceOrientation.landscapeLeft ||
      _deviceOrientation == DeviceOrientation.landscapeRight;

  // The platform's capture-orientation lock interprets the two landscape values
  // opposite to how the UI is rotated, so flip them here to keep saved photos
  // the right way up.
  DeviceOrientation get _captureOrientation {
    switch (_deviceOrientation) {
      case DeviceOrientation.landscapeLeft:
        return DeviceOrientation.landscapeRight;
      case DeviceOrientation.landscapeRight:
        return DeviceOrientation.landscapeLeft;
      case DeviceOrientation.portraitUp:
      case DeviceOrientation.portraitDown:
        return _deviceOrientation;
    }
  }

  Widget _buildReferenceOverlay(CameraState camState) {
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewport = Size(constraints.maxWidth, constraints.maxHeight);
          final boundedOffset = _clampOverlayOffset(
            camState.overlayOffset,
            viewport,
          );
          final overlayConstraints = _overlayConstraints(viewport);

          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onScaleStart: (details) {
              _gestureStartOffset = boundedOffset;
              _gestureStartFocalPoint = details.focalPoint;
              _gestureStartScale = camState.overlayScale;
            },
            onScaleUpdate: (details) {
              final nextOffset =
                  _gestureStartOffset +
                  (details.focalPoint - _gestureStartFocalPoint);

              ref
                  .read(cameraProvider.notifier)
                  .updateOverlayTransform(
                    offset: _clampOverlayOffset(nextOffset, viewport),
                    scale: _gestureStartScale * details.scale,
                  );
            },
            onDoubleTap: () => ref.read(cameraProvider.notifier).resetOverlay(),
            child: Center(
              child: Transform.translate(
                offset: boundedOffset,
                child: Transform.scale(
                  scale: camState.overlayScale,
                  child: Opacity(
                    opacity: camState.overlayOpacity,
                    child: _RotatingCameraUi(
                      quarterTurns: _cameraUiQuarterTurns,
                      child: Container(
                        constraints: overlayConstraints,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white70, width: 1.5),
                        ),
                        child: Image.file(
                          camState.referenceImage!,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  BoxConstraints _overlayConstraints(Size viewport) {
    // When the device is held in landscape the overlay is rotated a quarter
    // turn, so its pre-rotation box maps the screen axes the other way round:
    // its width ends up along the screen's long (vertical) axis and its height
    // along the short (horizontal) axis. Swap the viewport extents to match.
    if (_isDeviceLandscape) {
      return BoxConstraints(
        maxWidth: viewport.height * 0.82,
        maxHeight: viewport.width * 0.86,
      );
    }

    return BoxConstraints(
      maxWidth: viewport.width * 0.86,
      maxHeight: viewport.height * 0.58,
    );
  }

  Offset _clampOverlayOffset(Offset offset, Size viewport) {
    final maxDx = viewport.width * 0.48;
    final maxDy = viewport.height * 0.48;

    return Offset(
      offset.dx.clamp(-maxDx, maxDx).toDouble(),
      offset.dy.clamp(-maxDy, maxDy).toDouble(),
    );
  }

  Widget _buildTopBar(CameraState camState) {
    final controls = <Widget>[
      _CameraIconButton(
        icon: Icons.arrow_back,
        onTap: () => Navigator.pop(context),
      ),
      if (camState.referenceImage != null)
        _CameraIconButton(
          icon: Icons.center_focus_strong,
          onTap: () => ref.read(cameraProvider.notifier).resetOverlay(),
        ),
      _CameraIconButton(
        icon: Icons.photo_library_outlined,
        onTap: _pickPoiReferenceImage,
      ),
      _FrameModeToggle(
        mode: _frameMode,
        onChanged: (mode) => setState(() => _frameMode = mode),
      ),
      _CameraIconButton(
        icon: _flashMode == FlashMode.off ? Icons.flash_off : Icons.flash_auto,
        onTap: _toggleFlash,
      ),
    ];

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              controls.first,
              const Spacer(),
              for (final control in controls.skip(1)) ...[
                control,
                if (control != controls.last) const SizedBox(width: 10),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomControls(CameraState camState) {
    final uiQuarterTurns = _cameraUiQuarterTurns;
    final sliderControls = <Widget>[
      if (camState.referenceImage != null)
        _CameraSliderControl(
          icon: Icons.layers,
          value: camState.overlayOpacity,
          min: 0.1,
          max: 1,
          onChanged: (value) =>
              ref.read(cameraProvider.notifier).setOverlayOpacity(value),
          trailing: _CameraIconButton(
            icon: Icons.visibility_off,
            size: 38,
            onTap: () =>
                ref.read(cameraProvider.notifier).clearReferenceImage(),
          ),
          quarterTurns: 0,
        ),
      if (_maxZoom > _minZoom)
        _CameraSliderControl(
          label: '${_currentZoom.toStringAsFixed(1)}x',
          value: _currentZoom.clamp(_minZoom, _maxZoom).toDouble(),
          min: _minZoom,
          max: _maxZoom,
          onChanged: (value) => _setZoom(value),
          trailing: _CameraIconButton(
            icon: Icons.center_focus_weak,
            size: 38,
            onTap: () => _setZoom(math.max(1, _minZoom)),
          ),
          quarterTurns: uiQuarterTurns,
        ),
    ];
    final mainControls = <Widget>[
      _ReferenceButton(
        referenceImage: camState.poiId == null ? camState.referenceImage : null,
        emptyIcon: camState.poiId == null
            ? Icons.image
            : Icons.file_upload_outlined,
        onTap: _pickReferenceImage,
      ),
      _ShutterButton(isBusy: _isTakingPicture, onTap: _takePicture),
      _CameraIconButton(
        icon: Icons.cameraswitch,
        size: 52,
        onTap: _cameras.length > 1 ? _switchCamera : null,
      ),
    ];

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                Colors.black.withValues(alpha: 0.82),
                Colors.black.withValues(alpha: 0.38),
                Colors.transparent,
              ],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final control in sliderControls) control,
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: mainControls,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildComparisonScreen(CameraState camState) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: const Text('Compare Shot'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => ref.read(cameraProvider.notifier).clearCapture(),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header copy hidden for now — kept commented for easy re-add.
              // Text(
              //   camState.referenceImage == null
              //       ? 'Review your photo'
              //       : 'Reference and your shot',
              //   style: theme.textTheme.headlineSmall?.copyWith(
              //     fontWeight: FontWeight.bold,
              //   ),
              // ),
              // const SizedBox(height: 6),
              // Text(
              //   camState.referenceImage == null
              //       ? 'Save it to the selected POI or retake.'
              //       : 'Check the framing before saving to this POI.',
              //   style: theme.textTheme.bodyMedium?.copyWith(
              //     color: theme.colorScheme.onSurfaceVariant,
              //   ),
              // ),
              // const SizedBox(height: 16),
              Expanded(
                child: _ComparisonLayout(
                  referenceImage: camState.referenceImage,
                  capturedPhoto: camState.capturedPhoto!,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          ref.read(cameraProvider.notifier).clearCapture(),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retake'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _savePhoto(camState),
                      icon: const Icon(Icons.save),
                      label: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickReferenceImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;

    final imageFile = File(picked.path);
    final camState = ref.read(cameraProvider);

    if (camState.poiId != null) {
      final db = ref.read(databaseProvider);
      final success = await ref
          .read(cameraProvider.notifier)
          .saveUploadedImage(db, imageFile);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(success ? 'Image uploaded!' : 'Upload failed')),
      );
      return;
    }

    ref.read(cameraProvider.notifier).setReferenceImage(imageFile);
  }

  Future<void> _pickPoiReferenceImage() async {
    final poiId = await _resolvePoiIdForReference();
    if (poiId == null) return;

    final assets = await ref.read(mediaAssetsByPoiProvider(poiId).future);
    final imageAssets = assets.where(_isReferenceAsset).toList();

    if (!mounted) return;
    if (imageAssets.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No POI images available.')));
      return;
    }

    final picked = await showModalBottomSheet<MediaAsset>(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (ctx) => ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: imageAssets.length,
        itemBuilder: (ctx, index) {
          final asset = imageAssets[index];
          final file = File(asset.localUri);

          return ListTile(
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 52,
                height: 52,
                child: Image.file(
                  file,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const ColoredBox(
                    color: Colors.black26,
                    child: Icon(Icons.broken_image, color: Colors.white54),
                  ),
                ),
              ),
            ),
            title: Text(
              p.basenameWithoutExtension(asset.localUri),
              style: const TextStyle(color: Colors.white),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              asset.type,
              style: const TextStyle(color: Colors.white54),
            ),
            onTap: () => Navigator.pop(ctx, asset),
          );
        },
      ),
    );

    if (picked == null) return;

    final file = File(picked.localUri);
    if (!await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Image file not found: ${picked.localUri}')),
      );
      return;
    }

    ref.read(cameraProvider.notifier).setReferenceImage(file);
  }

  Future<String?> _resolvePoiIdForReference() async {
    final currentPoiId = ref.read(cameraProvider).poiId;
    if (currentPoiId != null) return currentPoiId;

    final poisMap = await ref.read(allPoisProvider.future);
    final pois = poisMap.values.toList();

    if (!mounted) return null;
    if (pois.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No POIs yet. Create one first.')),
      );
      return null;
    }

    final picked = await showModalBottomSheet<Poi>(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (ctx) => ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: pois.length,
        itemBuilder: (ctx, index) {
          final poi = pois[index];

          return ListTile(
            leading: const Icon(Icons.location_on, color: Colors.white70),
            title: Text(poi.name, style: const TextStyle(color: Colors.white)),
            subtitle: poi.animeSeriesRef != null
                ? Text(
                    poi.animeSeriesRef!,
                    style: const TextStyle(color: Colors.white54),
                  )
                : null,
            onTap: () => Navigator.pop(ctx, poi),
          );
        },
      ),
    );

    if (picked == null) return null;

    ref.read(cameraProvider.notifier).setPoiId(picked.id);
    return picked.id;
  }

  bool _isReferenceAsset(MediaAsset asset) {
    final uri = asset.localUri.toLowerCase();
    final isKnownImageType =
        asset.type == 'user_photo' ||
        asset.type == 'uploaded_image' ||
        asset.type == 'reference_frame' ||
        asset.type == 'ticket_qr';
    final hasImageExtension =
        uri.endsWith('.jpg') ||
        uri.endsWith('.jpeg') ||
        uri.endsWith('.png') ||
        uri.endsWith('.webp') ||
        uri.endsWith('.gif') ||
        uri.endsWith('.heic');

    return isKnownImageType || hasImageExtension;
  }

  Future<void> _savePhoto(CameraState camState) async {
    if (camState.poiId == null) {
      await _showPoiPicker();
      return;
    }

    final db = ref.read(databaseProvider);
    final success = await ref.read(cameraProvider.notifier).savePhoto(db);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(success ? 'Photo saved!' : 'Save failed')),
      );
      if (success) {
        ref.read(cameraProvider.notifier).clearCapture();
      }
    }
  }

  Future<void> _showPoiPicker() async {
    final poisMap = await ref.read(allPoisProvider.future);
    final pois = poisMap.values.toList();

    if (!mounted) return;
    if (pois.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No POIs yet. Create one first.')),
      );
      return;
    }

    final picked = await showModalBottomSheet<Poi>(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (ctx) => ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: pois.length,
        itemBuilder: (ctx, i) => ListTile(
          leading: const Icon(Icons.location_on, color: Colors.white70),
          title: Text(
            pois[i].name,
            style: const TextStyle(color: Colors.white),
          ),
          subtitle: pois[i].animeSeriesRef != null
              ? Text(
                  pois[i].animeSeriesRef!,
                  style: const TextStyle(color: Colors.white54),
                )
              : null,
          onTap: () => Navigator.pop(ctx, pois[i]),
        ),
      ),
    );

    if (picked != null) {
      ref.read(cameraProvider.notifier).setPoiId(picked.id);
      final db = ref.read(databaseProvider);
      final success = await ref.read(cameraProvider.notifier).savePhoto(db);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              success ? 'Photo saved to ${picked.name}!' : 'Save failed',
            ),
          ),
        );
        if (success) {
          ref.read(cameraProvider.notifier).clearCapture();
        }
      }
    }
  }
}

class _FrameModeToggle extends StatelessWidget {
  final _CameraFrameMode mode;
  final ValueChanged<_CameraFrameMode> onChanged;

  const _FrameModeToggle({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: Colors.white12),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _FrameModeButton(
            label: 'Native',
            selected: mode == _CameraFrameMode.native,
            onTap: () => onChanged(_CameraFrameMode.native),
          ),
          _FrameModeButton(
            label: 'Fill',
            selected: mode == _CameraFrameMode.screenFill,
            onTap: () => onChanged(_CameraFrameMode.screenFill),
          ),
        ],
      ),
    );
  }
}

class _CameraSliderControl extends StatelessWidget {
  final IconData? icon;
  final String? label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final Widget trailing;
  final int quarterTurns;

  const _CameraSliderControl({
    this.icon,
    this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.trailing,
    required this.quarterTurns,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 42,
          child: Center(
            child: _RotatingCameraUi(
              quarterTurns: quarterTurns,
              child: icon == null
                  ? Text(
                      label ?? '',
                      style: const TextStyle(
                        color: Colors.white,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    )
                  : Icon(icon, color: Colors.white70, size: 18),
            ),
          ),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            activeColor: Colors.white,
            inactiveColor: Colors.white24,
            onChanged: onChanged,
          ),
        ),
        trailing,
      ],
    );
  }
}

class _ComparisonLayout extends StatelessWidget {
  final File? referenceImage;
  final File capturedPhoto;

  const _ComparisonLayout({
    required this.referenceImage,
    required this.capturedPhoto,
  });

  @override
  Widget build(BuildContext context) {
    final referenceImage = this.referenceImage;

    if (referenceImage == null) {
      return _ImageReviewCard(
        label: 'Your Shot',
        icon: Icons.camera_alt,
        imageFile: capturedPhoto,
      );
    }

    // Always stack the reference and the shot vertically.
    return Column(
      children: [
        Expanded(
          child: _ImageReviewCard(
            label: 'Reference',
            icon: Icons.image,
            imageFile: referenceImage,
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _ImageReviewCard(
            label: 'Your Shot',
            icon: Icons.camera_alt,
            imageFile: capturedPhoto,
          ),
        ),
      ],
    );
  }
}

class _ImageReviewCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final File imageFile;

  const _ImageReviewCard({
    required this.label,
    required this.icon,
    required this.imageFile,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
            child: Row(
              children: [
                Icon(icon, color: theme.colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Preview',
                  icon: const Icon(Icons.open_in_full),
                  onPressed: () => _showFullscreenImage(context),
                ),
              ],
            ),
          ),
          Expanded(
            child: ColoredBox(
              color: Colors.black,
              child: InteractiveViewer(
                minScale: 0.75,
                maxScale: 4,
                child: Center(
                  child: Image.file(imageFile, fit: BoxFit.contain),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showFullscreenImage(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            InteractiveViewer(
              minScale: 0.75,
              maxScale: 5,
              child: Center(child: Image.file(imageFile, fit: BoxFit.contain)),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: AppBar(
                  backgroundColor: Colors.black54,
                  foregroundColor: Colors.white,
                  title: Text(label),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FrameModeButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FrameModeButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _CameraIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final double size;

  const _CameraIconButton({
    required this.icon,
    required this.onTap,
    this.size = 44,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.35 : 1,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withValues(alpha: 0.42),
            border: Border.all(color: Colors.white12),
          ),
          child: Icon(icon, color: Colors.white, size: size * 0.48),
        ),
      ),
    );
  }
}

class _ReferenceButton extends StatelessWidget {
  final File? referenceImage;
  final IconData emptyIcon;
  final VoidCallback onTap;

  const _ReferenceButton({
    required this.referenceImage,
    required this.emptyIcon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: Colors.black.withValues(alpha: 0.42),
          border: Border.all(color: Colors.white30, width: 1.2),
        ),
        clipBehavior: Clip.antiAlias,
        child: referenceImage == null
            ? Icon(emptyIcon, color: Colors.white, size: 28)
            : Image.file(referenceImage!, fit: BoxFit.cover),
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  final bool isBusy;
  final VoidCallback onTap;

  const _ShutterButton({required this.isBusy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isBusy ? null : onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        opacity: isBusy ? 0.55 : 1,
        child: Container(
          width: 78,
          height: 78,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 4),
          ),
          child: Container(
            margin: const EdgeInsets.all(5),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _RotatingCameraUi extends StatelessWidget {
  final int quarterTurns;
  final Widget child;

  const _RotatingCameraUi({required this.quarterTurns, required this.child});

  @override
  Widget build(BuildContext context) {
    final normalizedTurns = quarterTurns % 4;
    if (normalizedTurns == 0) return child;

    return Transform.rotate(
      angle: normalizedTurns * math.pi / 2,
      alignment: Alignment.center,
      child: child,
    );
  }
}
