// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'gallery_saver.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(gallerySaver)
final gallerySaverProvider = GallerySaverProvider._();

final class GallerySaverProvider
    extends $FunctionalProvider<GallerySaver, GallerySaver, GallerySaver>
    with $Provider<GallerySaver> {
  GallerySaverProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'gallerySaverProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$gallerySaverHash();

  @$internal
  @override
  $ProviderElement<GallerySaver> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  GallerySaver create(Ref ref) {
    return gallerySaver(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(GallerySaver value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<GallerySaver>(value),
    );
  }
}

String _$gallerySaverHash() => r'3a2c457491f9572e1c500afd13d9a584ba9e2ce1';
