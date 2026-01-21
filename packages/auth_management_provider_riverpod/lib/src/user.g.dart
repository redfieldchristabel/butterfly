// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'user.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(RiverpodUserState)
const riverpodUserStateProvider = RiverpodUserStateProvider._();

final class RiverpodUserStateProvider
    extends $NotifierProvider<RiverpodUserState, RiverpodUser?> {
  const RiverpodUserStateProvider._()
      : super(
          from: null,
          argument: null,
          retry: null,
          name: r'riverpodUserStateProvider',
          isAutoDispose: false,
          dependencies: null,
          $allTransitiveDependencies: null,
        );

  @override
  String debugGetCreateSourceHash() => _$riverpodUserStateHash();

  @$internal
  @override
  RiverpodUserState create() => RiverpodUserState();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(RiverpodUser? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<RiverpodUser?>(value),
    );
  }
}

String _$riverpodUserStateHash() => r'a635d76f357d5f7fd522f34e7b9a8b9a8e56614e';

abstract class _$RiverpodUserState extends $Notifier<RiverpodUser?> {
  RiverpodUser? build();
  @$mustCallSuper
  @override
  void runBuild() {
    final created = build();
    final ref = this.ref as $Ref<RiverpodUser?, RiverpodUser?>;
    final element = ref.element as $ClassProviderElement<
        AnyNotifier<RiverpodUser?, RiverpodUser?>,
        RiverpodUser?,
        Object?,
        Object?>;
    element.handleValue(ref, created);
  }
}
