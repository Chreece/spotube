import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:media_kit/media_kit.dart';
import 'package:spotube/models/track.dart'; // your Track model
import 'package:flutter/material.dart';

/// Convert your Spotube Track into an AudioService MediaItem.
MediaItem mediaItemFromTrack(Track track) => MediaItem(
  id: track.id,
  album: track.albumName,
  title: track.title,
  artist: track.artistNames.join(', '),
  duration: Duration(milliseconds: track.durationMs),
  artUri: Uri.parse(track.albumArtUrl),
  extras: {
    'uri': track.streamUrl,
  },
);

/// A bridge between media_kit's AudioPlayer and audio_service's AudioHandler.
class SpotubeAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final AudioPlayer _player;
  late final StreamSubscription<PlaybackEvent> _eventSub;

  SpotubeAudioHandler()
      : _player = AudioPlayer() {
    _eventSub = _player.playbackEventStream.listen(_broadcastState);
    queue.add([]);
  }

  void _broadcastState(PlaybackEvent event) {
    final playing = event.playing;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const { MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[event.processingState]!,
      playing: playing,
      updatePosition: event.position,
      bufferedPosition: event.bufferedPosition,
      speed: event.speed,
    ));
  }

  @override Future<void> play() => _player.play();
  @override Future<void> pause() => _player.pause();
  @override Future<void> stop() async { await _player.stop(); await super.stop(); }
  @override Future<void> seek(Duration pos) => _player.seek(pos);

  @override
  Future<void> skipToNext() async {
    final list = queue.value;
    final current = mediaItem.value!;
    final idx = list.indexOf(current);
    if (idx + 1 < list.length) await skipQueueItem(idx + 1);
  }

  @override
  Future<void> skipToPrevious() async {
    final list = queue.value;
    final current = mediaItem.value!;
    final idx = list.indexOf(current);
    if (idx > 0) await skipQueueItem(idx - 1);
  }

  @override
  Future<void> skipQueueItem(int index) async {
    final item = queue.value[index];
    mediaItem.add(item);
    final uri = item.extras?['uri'] as String;
    await _player.open(Media(uri));
    await play();
  }

  @override
  Future<void> addQueueItem(MediaItem item) async {
    final newQ = [...queue.value, item];
    queue.add(newQ);
  }

  @override
  Future<List<MediaItem>> getChildren(String parentId, [int? page, int? pageSize]) async {
    return queue.value;
  }

  @override Future<void> onTaskRemoved() async => stop();
  @override void dispose() { _eventSub.cancel(); _player.dispose(); super.dispose(); }
}

/// --------------------
/// Example Flutter widgets integrating AudioHandler with seek bar
/// --------------------

/// Displays a list of Spotube tracks and plays on tap.
class TrackListScreen extends StatefulWidget {
  final List<Track> tracks;
  const TrackListScreen({Key? key, required this.tracks}) : super(key: key);

  @override
  _TrackListScreenState createState() => _TrackListScreenState();
}

class _TrackListScreenState extends State<TrackListScreen> {
  late final SpotubeAudioHandler _audioHandler;

  @override
  void initState() {
    super.initState();
    _audioHandler = AudioService.init(
      builder: () => SpotubeAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.krtirtho.spotube.channel.audio',
        androidNotificationChannelName: 'Spotube Playback',
        androidNotificationOngoing: true,
      ),
    ) as SpotubeAudioHandler;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your Library')),
      body: ListView.builder(
        itemCount: widget.tracks.length,
        itemBuilder: (context, index) {
          final track = widget.tracks[index];
          final item = mediaItemFromTrack(track);
          return ListTile(
            leading: Image.network(track.albumArtUrl),
            title: Text(track.title),
            subtitle: Text(track.artistNames.join(', ')),
            onTap: () {
              _audioHandler.addQueueItem(item);
              _audioHandler.play();
            },
          );
        },
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          SeekBar(),
          PlaybackControls(),
        ],
      ),
    );
  }
}

/// A simple seek bar that shows current position and duration.
class SeekBar extends StatelessWidget {
  const SeekBar({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final handler = AudioService.instance;
    return StreamBuilder<PlaybackState>(
      stream: handler.playbackState,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final position = state?.updatePosition ?? Duration.zero;
        final duration = state?.processingState == AudioProcessingState.ready
            ? handler.mediaItem.value?.duration ?? Duration.zero
            : Duration.zero;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Slider(
            min: 0,
            max: duration.inMilliseconds.toDouble(),
            value: position.inMilliseconds.clamp(0, duration.inMilliseconds).toDouble(),
            onChanged: (value) => handler.seek(Duration(milliseconds: value.toInt())),
          ),
        );
      },
    );
  }
}

/// Simple playback controls bar with play/pause/skip
class PlaybackControls extends StatelessWidget {
  const PlaybackControls({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final handler = AudioService.instance;
    return StreamBuilder<PlaybackState>(
      stream: handler.playbackState,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final playing = state?.playing ?? false;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            IconButton(
              icon: const Icon(Icons.skip_previous),
              onPressed: handler.skipToPrevious,
            ),
            IconButton(
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              onPressed: playing ? handler.pause : handler.play,
            ),
            IconButton(
              icon: const Icon(Icons.skip_next),
              onPressed: handler.skipToNext,
            ),
          ],
        );
      },
    );
  }
}
