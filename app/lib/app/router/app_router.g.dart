// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_router.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// 全局唯一的 GoRouter 实例。
///
/// 挂成 Riverpod provider 而不是全局变量，是为了两件事：
/// 1. 测试里可以 `overrideWithValue` 塞一个内存路由，不用起真机；
/// 2. 后续做深链 / 通知跳转时，重定向逻辑可以读别的 provider（登录态、任务状态）。
/// `keepAlive` 必须开：路由器被回收会丢整棵导航栈。

@ProviderFor(appRouter)
final appRouterProvider = AppRouterProvider._();

/// 全局唯一的 GoRouter 实例。
///
/// 挂成 Riverpod provider 而不是全局变量，是为了两件事：
/// 1. 测试里可以 `overrideWithValue` 塞一个内存路由，不用起真机；
/// 2. 后续做深链 / 通知跳转时，重定向逻辑可以读别的 provider（登录态、任务状态）。
/// `keepAlive` 必须开：路由器被回收会丢整棵导航栈。

final class AppRouterProvider
    extends $FunctionalProvider<GoRouter, GoRouter, GoRouter>
    with $Provider<GoRouter> {
  /// 全局唯一的 GoRouter 实例。
  ///
  /// 挂成 Riverpod provider 而不是全局变量，是为了两件事：
  /// 1. 测试里可以 `overrideWithValue` 塞一个内存路由，不用起真机；
  /// 2. 后续做深链 / 通知跳转时，重定向逻辑可以读别的 provider（登录态、任务状态）。
  /// `keepAlive` 必须开：路由器被回收会丢整棵导航栈。
  AppRouterProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'appRouterProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$appRouterHash();

  @$internal
  @override
  $ProviderElement<GoRouter> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  GoRouter create(Ref ref) {
    return appRouter(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(GoRouter value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<GoRouter>(value),
    );
  }
}

String _$appRouterHash() => r'301e116bcef4038dbc61ff1eb69b6041332b1e8a';
