// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'history_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// 历史记录（真实数据）。上层只要是 `List<HistoryItem>` 的消费者，一行都不用改。

@ProviderFor(HistoryItems)
final historyItemsProvider = HistoryItemsProvider._();

/// 历史记录（真实数据）。上层只要是 `List<HistoryItem>` 的消费者，一行都不用改。
final class HistoryItemsProvider
    extends $NotifierProvider<HistoryItems, List<HistoryItem>> {
  /// 历史记录（真实数据）。上层只要是 `List<HistoryItem>` 的消费者，一行都不用改。
  HistoryItemsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'historyItemsProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$historyItemsHash();

  @$internal
  @override
  HistoryItems create() => HistoryItems();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(List<HistoryItem> value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<List<HistoryItem>>(value),
    );
  }
}

String _$historyItemsHash() => r'117f9ef7321264f3bb70429c82e88dd239de09b7';

/// 历史记录（真实数据）。上层只要是 `List<HistoryItem>` 的消费者，一行都不用改。

abstract class _$HistoryItems extends $Notifier<List<HistoryItem>> {
  List<HistoryItem> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<List<HistoryItem>, List<HistoryItem>>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<List<HistoryItem>, List<HistoryItem>>,
              List<HistoryItem>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

/// 当前筛选（null = 全部）。用 Notifier 而不是 UI 里的 local state，
/// 是为了让「历史页筛选」将来能被深链或通知直接指定。

@ProviderFor(HistoryFilter)
final historyFilterProvider = HistoryFilterProvider._();

/// 当前筛选（null = 全部）。用 Notifier 而不是 UI 里的 local state，
/// 是为了让「历史页筛选」将来能被深链或通知直接指定。
final class HistoryFilterProvider
    extends $NotifierProvider<HistoryFilter, HistoryKind?> {
  /// 当前筛选（null = 全部）。用 Notifier 而不是 UI 里的 local state，
  /// 是为了让「历史页筛选」将来能被深链或通知直接指定。
  HistoryFilterProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'historyFilterProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$historyFilterHash();

  @$internal
  @override
  HistoryFilter create() => HistoryFilter();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(HistoryKind? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<HistoryKind?>(value),
    );
  }
}

String _$historyFilterHash() => r'10a57c15e8fd2826b17fa1f68ed0dee7106c54db';

/// 当前筛选（null = 全部）。用 Notifier 而不是 UI 里的 local state，
/// 是为了让「历史页筛选」将来能被深链或通知直接指定。

abstract class _$HistoryFilter extends $Notifier<HistoryKind?> {
  HistoryKind? build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<HistoryKind?, HistoryKind?>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<HistoryKind?, HistoryKind?>,
              HistoryKind?,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

/// 派生状态：筛选后的列表。数据或筛选一变就重算，UI 只 watch 这一个。

@ProviderFor(visibleHistory)
final visibleHistoryProvider = VisibleHistoryProvider._();

/// 派生状态：筛选后的列表。数据或筛选一变就重算，UI 只 watch 这一个。

final class VisibleHistoryProvider
    extends
        $FunctionalProvider<
          List<HistoryItem>,
          List<HistoryItem>,
          List<HistoryItem>
        >
    with $Provider<List<HistoryItem>> {
  /// 派生状态：筛选后的列表。数据或筛选一变就重算，UI 只 watch 这一个。
  VisibleHistoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'visibleHistoryProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$visibleHistoryHash();

  @$internal
  @override
  $ProviderElement<List<HistoryItem>> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  List<HistoryItem> create(Ref ref) {
    return visibleHistory(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(List<HistoryItem> value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<List<HistoryItem>>(value),
    );
  }
}

String _$visibleHistoryHash() => r'7adfc7185a1ca8c4770925de30b37781af9e4416';

/// 按 id 取单条（详情页用）。找不到返回 null，由页面决定怎么展示。

@ProviderFor(historyItemById)
final historyItemByIdProvider = HistoryItemByIdFamily._();

/// 按 id 取单条（详情页用）。找不到返回 null，由页面决定怎么展示。

final class HistoryItemByIdProvider
    extends $FunctionalProvider<HistoryItem?, HistoryItem?, HistoryItem?>
    with $Provider<HistoryItem?> {
  /// 按 id 取单条（详情页用）。找不到返回 null，由页面决定怎么展示。
  HistoryItemByIdProvider._({
    required HistoryItemByIdFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'historyItemByIdProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$historyItemByIdHash();

  @override
  String toString() {
    return r'historyItemByIdProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $ProviderElement<HistoryItem?> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  HistoryItem? create(Ref ref) {
    final argument = this.argument as String;
    return historyItemById(ref, argument);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(HistoryItem? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<HistoryItem?>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is HistoryItemByIdProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$historyItemByIdHash() => r'0e1acb42f2c93d6aee224650963120075eff2ea6';

/// 按 id 取单条（详情页用）。找不到返回 null，由页面决定怎么展示。

final class HistoryItemByIdFamily extends $Family
    with $FunctionalFamilyOverride<HistoryItem?, String> {
  HistoryItemByIdFamily._()
    : super(
        retry: null,
        name: r'historyItemByIdProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// 按 id 取单条（详情页用）。找不到返回 null，由页面决定怎么展示。

  HistoryItemByIdProvider call(String id) =>
      HistoryItemByIdProvider._(argument: id, from: this);

  @override
  String toString() => r'historyItemByIdProvider';
}
