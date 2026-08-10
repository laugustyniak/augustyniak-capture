import '../../settings/domain/provider_profile.dart';
import 'price_book.dart';
import 'usage_event.dart';

/// The distinct model/provider keys the Config tab's PRICING section offers
/// a rate row for.
///
/// **Union of two sources, not just usage history.** A key reachable only
/// through [events] would mean no rate is editable — and no missing-rate
/// warning is possible — until the model has already been called once and
/// paid for at whatever the shipped table (or nothing) charged. An active
/// provider profile names the model it is *about* to call before any request
/// goes out, so its key belongs in the list on day one, database or no
/// database: a profile carries no dependency on the usage store having
/// opened.
///
/// Both sides key through [PriceBook.keyFor] — the one place the
/// blank-model-falls-back-to-provider-name rule is allowed to live — so an
/// event derived from a profile with no `model` set (a local server that
/// ignores the field) and that profile itself always agree on one key rather
/// than the profile contributing a second, `''`-keyed row nothing can ever
/// price.
List<String> usageModelKeys({
  required Iterable<UsageEvent> events,
  required Iterable<ProviderProfile> profiles,
}) {
  final Set<String> keys = <String>{
    for (final UsageEvent event in events)
      PriceBook.keyFor(event.model, event.provider),
    for (final ProviderProfile profile in profiles)
      PriceBook.keyFor(profile.model ?? '', profile.host),
  };
  return keys.toList()..sort();
}
