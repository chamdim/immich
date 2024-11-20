import 'dart:async';
import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart' hide Store;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/entities/asset.entity.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/pages/common/video_viewer.page.dart';
import 'package:immich_mobile/providers/app_settings.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/current_asset.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/is_motion_video_playing.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_controls_provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_value_provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/app_settings.service.dart';
import 'package:immich_mobile/services/asset.service.dart';
import 'package:immich_mobile/utils/debounce.dart';
import 'package:immich_mobile/utils/hooks/interval_hook.dart';
import 'package:immich_mobile/widgets/asset_viewer/custom_video_player_controls.dart';
import 'package:logging/logging.dart';
import 'package:native_video_player/native_video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

@RoutePage()
class NativeVideoViewerPage extends HookConsumerWidget {
  final Asset asset;
  final Widget image;
  final bool showControls;

  const NativeVideoViewerPage({
    super.key,
    required this.asset,
    required this.image,
    this.showControls = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    /// TODO: Remove this when seeking remote videos on Android in the native video player is smooth.
    if (asset.isRemote && Platform.isAndroid) {
      return VideoViewerPage(
        asset: asset,
        image: image,
        showControls: showControls,
      );
    }

    final loopVideo = ref.watch(
      appSettingsServiceProvider.select(
        (settings) => settings.getSetting<bool>(AppSettingsEnum.loopVideo),
      ),
    );
    final controller = useState<NativeVideoPlayerController?>(null);
    final lastVideoPosition = useRef(-1);
    final isBuffering = useRef(false);
    final showMotionVideo = useState(false);

    // When a video is opened through the timeline, `isCurrent` will immediately be true.
    // When swiping from video A to video B, `isCurrent` will initially be true for video A and false for video B.
    // If the swipe is completed, `isCurrent` will be true for video B after a delay.
    // If the swipe is canceled, `currentAsset` will not have changed and video A will continue to play.
    final currentAsset = useState(ref.read(currentAssetProvider));
    final isCurrent = currentAsset.value == asset;

    // Used to show the placeholder during hero animations for remote videos to avoid a stutter
    final isVisible = useState(asset.isLocal || asset.isMotionPhoto);

    final log = Logger('NativeVideoViewerPage');

    ref.listen(isPlayingMotionVideoProvider, (_, value) async {
      final videoController = controller.value;
      if (!asset.isMotionPhoto || videoController == null || !context.mounted) {
        return;
      }

      showMotionVideo.value = value;
      try {
        if (value) {
          await videoController.seekTo(0);
          await videoController.play();
        } else {
          await videoController.pause();
        }
      } catch (error) {
        log.severe('Error toggling motion video: $error');
      }
    });

    Future<VideoSource?> createSource() async {
      if (!context.mounted) {
        return null;
      }

      try {
        final local = asset.local;
        if (local != null && !asset.isMotionPhoto) {
          final file = await local.file;
          if (file == null) {
            throw Exception('No file found for the video');
          }

          final source = await VideoSource.init(
            path: file.path,
            type: VideoSourceType.file,
          );
          return source;
        }

        // Use a network URL for the video player controller
        final serverEndpoint = Store.get(StoreKey.serverEndpoint);
        final String videoUrl = asset.livePhotoVideoId != null
            ? '$serverEndpoint/assets/${asset.livePhotoVideoId}/video/playback'
            : '$serverEndpoint/assets/${asset.remoteId}/video/playback';

        final source = await VideoSource.init(
          path: videoUrl,
          type: VideoSourceType.network,
          headers: ApiService.getRequestHeaders(),
        );
        return source;
      } catch (error) {
        log.severe(
          'Error creating video source for asset ${asset.fileName}: $error',
        );
        return null;
      }
    }

    final videoSource = useMemoized<Future<VideoSource?>>(() => createSource());
    final aspectRatio = useState<double?>(asset.aspectRatio);
    useMemoized(
      () async {
        if (!context.mounted || aspectRatio.value != null) {
          return null;
        }

        try {
          aspectRatio.value =
              await ref.read(assetServiceProvider).getAspectRatio(asset);
        } catch (error) {
          log.severe(
            'Error getting aspect ratio for asset ${asset.fileName}: $error',
          );
        }
      },
    );

    void checkIfBuffering() {
      if (!context.mounted) {
        return;
      }

      final videoPlayback = ref.read(videoPlaybackValueProvider);
      if ((isBuffering.value ||
              videoPlayback.state == VideoPlaybackState.initializing) &&
          videoPlayback.state != VideoPlaybackState.buffering) {
        ref.read(videoPlaybackValueProvider.notifier).value =
            videoPlayback.copyWith(state: VideoPlaybackState.buffering);
      }
    }

    // Timer to mark videos as buffering if the position does not change
    useInterval(const Duration(seconds: 5), checkIfBuffering);

    // When the volume changes, set the volume
    ref.listen(videoPlayerControlsProvider.select((value) => value.mute),
        (_, mute) async {
      final playerController = controller.value;
      if (playerController == null) {
        return;
      }

      final playbackInfo = playerController.playbackInfo;
      if (playbackInfo == null) {
        return;
      }

      try {
        if (mute && playbackInfo.volume != 0.0) {
          await playerController.setVolume(0.0);
        } else if (!mute && playbackInfo.volume != 0.9) {
          await playerController.setVolume(0.9);
        }
      } catch (error) {
        log.severe('Error setting volume: $error');
      }
    });

    // When the position changes, seek to the position
    // Debounce the seek to avoid seeking too often
    // But also don't delay the seek too much to maintain visual feedback
    final seekDebouncer = useDebouncer(
      interval: const Duration(milliseconds: 100),
      maxWaitTime: const Duration(milliseconds: 200),
    );
    ref.listen(videoPlayerControlsProvider.select((value) => value.position),
        (_, position) async {
      final playerController = controller.value;
      if (playerController == null) {
        return;
      }

      final playbackInfo = playerController.playbackInfo;
      if (playbackInfo == null) {
        return;
      }

      // Find the position to seek to
      final seek = position ~/ 1;
      if (seek != playbackInfo.position) {
        seekDebouncer.run(() => playerController.seekTo(seek));
      }
    });

    // // When the custom video controls pause or play
    ref.listen(videoPlayerControlsProvider.select((value) => value.pause),
        (_, pause) async {
      final videoController = controller.value;
      if (videoController == null || !context.mounted) {
        return;
      }

      // Make sure the last seek is complete before pausing or playing
      // Otherwise, `onPlaybackPositionChanged` can receive outdated events
      if (seekDebouncer.isActive) {
        await seekDebouncer.drain();
      }

      try {
        if (pause) {
          await videoController.pause();
        } else {
          await videoController.play();
        }
      } catch (error) {
        log.severe('Error pausing or playing video: $error');
      }
    });

    void onPlaybackReady() async {
      final videoController = controller.value;
      if (videoController == null || !isCurrent || !context.mounted) {
        return;
      }

      final videoPlayback =
          VideoPlaybackValue.fromNativeController(videoController);
      ref.read(videoPlaybackValueProvider.notifier).value = videoPlayback;

      try {
        if (asset.isVideo || showMotionVideo.value) {
          await videoController.play();
        }
        await videoController.setVolume(0.9);
      } catch (error) {
        log.severe('Error playing video: $error');
      }
    }

    void onPlaybackStatusChanged() {
      final videoController = controller.value;
      if (videoController == null || !context.mounted) {
        return;
      }

      final videoPlayback =
          VideoPlaybackValue.fromNativeController(videoController);
      // No need to update the UI when it's about to loop
      if (videoPlayback.state == VideoPlaybackState.completed && loopVideo) {
        return;
      }
      ref.read(videoPlaybackValueProvider.notifier).status =
          videoPlayback.state;
      if (videoPlayback.state == VideoPlaybackState.playing) {
        // Sync with the controls playing
        WakelockPlus.enable();
      } else {
        // Sync with the controls pause
        WakelockPlus.disable();
      }
    }

    void onPlaybackPositionChanged() {
      // When seeking, these events sometimes move the slider to an older position
      if (seekDebouncer.isActive) {
        return;
      }

      final videoController = controller.value;
      if (videoController == null || !context.mounted) {
        return;
      }

      final playbackInfo = videoController.playbackInfo;
      if (playbackInfo == null) {
        return;
      }

      ref.read(videoPlaybackValueProvider.notifier).position =
          Duration(seconds: playbackInfo.position);

      // Check if the video is buffering
      if (playbackInfo.status == PlaybackStatus.playing) {
        isBuffering.value = lastVideoPosition.value == playbackInfo.position;
        lastVideoPosition.value = playbackInfo.position;
      } else {
        isBuffering.value = false;
        lastVideoPosition.value = -1;
      }
    }

    void onPlaybackEnded() {
      final videoController = controller.value;
      if (videoController == null || !context.mounted) {
        return;
      }

      if (loopVideo) {
        try {
          videoController.play();
        } catch (error) {
          log.severe('Error looping video: $error');
        }
      } else {
        WakelockPlus.disable();
      }
    }

    void removeListeners(NativeVideoPlayerController controller) {
      controller.onPlaybackPositionChanged
          .removeListener(onPlaybackPositionChanged);
      controller.onPlaybackStatusChanged
          .removeListener(onPlaybackStatusChanged);
      controller.onPlaybackReady.removeListener(onPlaybackReady);
      controller.onPlaybackEnded.removeListener(onPlaybackEnded);
    }

    void initController(NativeVideoPlayerController nc) async {
      if (controller.value != null) {
        return;
      }
      ref.read(videoPlayerControlsProvider.notifier).reset();
      ref.read(videoPlaybackValueProvider.notifier).reset();

      final source = await videoSource;
      if (source == null) {
        return;
      }

      nc.onPlaybackPositionChanged.addListener(onPlaybackPositionChanged);
      nc.onPlaybackStatusChanged.addListener(onPlaybackStatusChanged);
      nc.onPlaybackReady.addListener(onPlaybackReady);
      nc.onPlaybackEnded.addListener(onPlaybackEnded);

      nc.loadVideoSource(source);
      controller.value = nc;
      Timer(const Duration(milliseconds: 200), checkIfBuffering);
    }

    ref.listen(currentAssetProvider, (_, value) {
      final playerController = controller.value;
      if (playerController != null && value != asset) {
        removeListeners(playerController);
      }

      final curAsset = currentAsset.value;
      if (curAsset == asset) {
        return;
      }

      // No need to delay video playback when swiping from an image to a video
      if (curAsset != null && !curAsset.isVideo) {
        currentAsset.value = value;
        onPlaybackReady();
        return;
      }

      // Delay video playback to avoid a stutter in the swipe animation
      Timer(const Duration(milliseconds: 300), () {
        if (!context.mounted) {
          return;
        }

        currentAsset.value = value;
        if (currentAsset.value == asset) {
          onPlaybackReady();
        }
      });
    });

    useEffect(
      () {
        // If opening a remote video from a hero animation, delay visibility to avoid a stutter
        final timer = isVisible.value
            ? null
            : Timer(
                const Duration(milliseconds: 300),
                () => isVisible.value = true,
              );

        return () {
          timer?.cancel();
          final playerController = controller.value;
          if (playerController == null) {
            return;
          }
          removeListeners(playerController);
          playerController.stop().catchError((error) {
            log.severe('Error stopping video: $error');
          });

          WakelockPlus.disable();
        };
      },
      const [],
    );

    return Stack(
      children: [
        // This remains under the video to avoid flickering
        // For motion videos, this is the image portion of the asset
        Center(key: ValueKey(asset.id), child: image),
        if (aspectRatio.value != null)
          Visibility.maintain(
            key: ValueKey(asset),
            visible:
                (asset.isVideo || showMotionVideo.value) && isVisible.value,
            child: Center(
              key: ValueKey(asset),
              child: AspectRatio(
                key: ValueKey(asset),
                aspectRatio: aspectRatio.value!,
                child: isCurrent
                    ? NativeVideoPlayerView(
                        key: ValueKey(asset),
                        onViewReady: initController,
                      )
                    : null,
              ),
            ),
          ),
        if (showControls) const Center(child: CustomVideoPlayerControls()),
      ],
    );
  }
}
