import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

void main() {
  test('selection defaults to automatic and redacts a fixed ID', () {
    const automatic = YlVideoSelection();
    const fixed = YlVideoSelection(
      fixedTrackId: 'private-track-token',
      reason: YlVideoSelectionReason.user,
    );
    expect(automatic.isAutomatic, isTrue);
    expect(YlPlayerState().videoSelection, automatic);
    expect(fixed.isAutomatic, isFalse);
    expect(fixed.toString(), isNot(contains('private-track-token')));
    expect(
      YlPlayerState().copyWith(videoSelection: fixed).videoSelection,
      fixed,
    );
    expect(
      fixed,
      const YlVideoSelection(
        fixedTrackId: 'private-track-token',
        reason: YlVideoSelectionReason.user,
      ),
    );
    expect(
      fixed.hashCode,
      const YlVideoSelection(
        fixedTrackId: 'private-track-token',
        reason: YlVideoSelectionReason.user,
      ).hashCode,
    );
  });

  test('fixed state requires a reported video track and user reason', () {
    final fixed = YlPlayerState(
      videoTracks: const [YlMediaTrack(id: 'another', kind: YlTrackKind.video)],
      videoSelection: const YlVideoSelection(
        fixedTrackId: 'v0',
        reason: YlVideoSelectionReason.user,
      ),
    );
    expect(() => validateYlPlayerState(fixed), throwsArgumentError);
    expect(
      () => validateYlPlayerState(
        fixed.copyWith(
          videoTracks: const [YlMediaTrack(id: 'v0', kind: YlTrackKind.video)],
        ),
      ),
      returnsNormally,
    );
    expect(
      () => validateYlPlayerState(fixed.copyWith(videoTracks: const [])),
      throwsArgumentError,
    );
    expect(
      () => validateYlPlayerState(
        YlPlayerState(
          videoSelection: const YlVideoSelection(
            fixedTrackId: 'v0',
            reason: YlVideoSelectionReason.trackUnavailable,
          ),
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => validateYlPlayerState(
        YlPlayerState(
          videoSelection: const YlVideoSelection(
            reason: YlVideoSelectionReason.trackUnavailable,
          ),
        ),
      ),
      returnsNormally,
    );
  });
}
