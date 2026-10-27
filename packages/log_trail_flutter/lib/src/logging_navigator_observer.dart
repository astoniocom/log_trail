import 'package:flutter/widgets.dart';
import 'package:log_trail/log_trail.dart';

/// Default tag of navigation transitions ([LoggingNavigatorObserver.tags]). Carries the library
/// prefix ([libraryLogTagPrefix]), like all its tags, and the same word as the transition fields
/// (`log_trail.navigation.*`); a short app tag is set via `tags`.
const String navigationLogTag = '${libraryLogTagPrefix}navigation';

/// Kind of transition logged by [LoggingNavigatorObserver].
enum NavigationLogAction { push, pop, remove, replace }

/// Navigator observer that logs route changes to [logger].
///
/// Each entry carries a human-readable message (`Nav push to /profile from /home`) and typed
/// attributes: [actionField], [routeField], [previousRouteField], so that entries can be filtered
/// by route (`LogQuery(filter: LogFilter(attributes: [LoggingNavigatorObserver.routeField('/profile')]))`)
/// instead of searched by text. Route names come from [RouteSettings.name]; without a name
/// `unnamed <route type>` is logged, and in a build with `--obfuscate` the type is unreadable:
/// give routes names.
///
/// ```dart
/// MaterialApp(navigatorObservers: [LoggingNavigatorObserver(logger.child(tags: {'app'}))]);
/// ```
class LoggingNavigatorObserver extends NavigatorObserver {
  LoggingNavigatorObserver(
    this.logger, {
    this.tags = const {navigationLogTag},
    this.argumentsFormatter,
  });

  /// Kind of transition.
  static const LogField<NavigationLogAction> actionField = LogField(
    'log_trail.navigation.action',
    EnumByNameCodec(NavigationLogAction.values),
  );

  /// Route the transition concerns, as in [NavigatorObserver]: the opened one on push, the closed
  /// one on pop, the removed one on remove, the new one on replace.
  static const LogField<String> routeField = LogField('log_trail.navigation.route', LogCodec.string);

  /// Second party of the transition, like `previousRoute` in [NavigatorObserver]: the route under
  /// the opened one on push, the one returned to on pop, the route under the removed one on
  /// remove, the replaced one on replace. Absent if there is no such route (first screen).
  static const LogField<String> previousRouteField = LogField(
    'log_trail.navigation.previous_route',
    LogCodec.string,
  );

  /// Route arguments at the transition ([argumentsFormatter]).
  static const LogField<String> argumentsField = LogField('log_trail.navigation.arguments', LogCodec.string);

  final Logger logger;
  final Set<String> tags;

  /// Turns route arguments into text for [argumentsField]; `null` means do not store.
  ///
  /// By default arguments are not stored: they may contain tokens and user data, and the log is
  /// stored on the device and goes into reports.
  final String? Function(Object arguments)? argumentsFormatter;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _log(
    NavigationLogAction.push,
    'Nav push to ${_name(route)} from ${_name(previousRoute)}',
    route: route,
    previousRoute: previousRoute,
    arguments: _arguments(route),
  );

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _log(
    NavigationLogAction.pop,
    'Nav pop to ${_name(previousRoute)} from ${_name(route)}',
    route: route,
    previousRoute: previousRoute,
  );

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _log(
    NavigationLogAction.remove,
    'Nav remove ${_name(route)}, previous: ${_name(previousRoute)}',
    route: route,
    previousRoute: previousRoute,
  );

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => _log(
    NavigationLogAction.replace,
    'Nav replace ${_name(oldRoute)} → ${_name(newRoute)}',
    route: newRoute,
    previousRoute: oldRoute,
    arguments: newRoute == null ? null : _arguments(newRoute),
  );

  void _log(
    NavigationLogAction action,
    String message, {
    required Route<dynamic>? route,
    required Route<dynamic>? previousRoute,
    LogAttribute<String>? arguments,
  }) => logger.log(
    message,
    tags: tags,
    attributes: [
      actionField(action),
      if (route != null) routeField(_name(route)),
      if (previousRoute != null) previousRouteField(_name(previousRoute)),
      ?arguments,
    ],
  );

  LogAttribute<String>? _arguments(Route<dynamic> route) {
    final arguments = route.settings.arguments;
    final formatter = argumentsFormatter;
    if (arguments == null || formatter == null) return null;
    final formatted = formatter(arguments);
    return formatted == null ? null : argumentsField(formatted);
  }

  String _name(Route<dynamic>? route) {
    if (route == null) return 'none';
    return route.settings.name ?? 'unnamed ${route.runtimeType}';
  }
}
