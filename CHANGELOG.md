# Changelog

## [0.4.5] - 2026-08-19

### Changed
- Publish the validated four-axis lane weight pair on every Gemini offering and reconcile weight-only changes atomically on the existing discovery cadence.
- Track initializing instances before readiness, rebuild weights from current settings at activation, and serialize activation, replacement, removal, and cache mutation behind one writer mutex.

### Fixed
- Report configured-but-unpublished Gemini weight keys once per dormant cycle without adding a settings callback or operator workflow.
- Render canonical system messages through the actual Gemini callable path as native `systemInstruction` payloads.

### Dependencies
- Raise the `lex-llm` floor from `>= 0.7.1` to `>= 0.7.6`; the `legion-settings` floor remains unchanged.

## [0.4.4] - 2026-08-18

### Fixed
- Remove synthetic-default discovery filtering and its once-per-boot warning; configured discovery now passes every instance entry through the normal claimability checks.

## [0.4.3] - 2026-08-17

### Changed
- **SSOT v3 fail-forward instance identity** - Instance identity is now the operator's config
  name (the key under `settings[:instances]`), published as `InstanceKey.instance_id`. The derived
  `host:port/ak:<8-char-SHA256-fingerprint>` id is demoted to the secondary `InstanceKey.physical_id`
  (dedup and diagnostics only; it never participates in identity). Two config names pointing at the
  same endpoint are now distinct instances.
- Every inventory publisher call threads the secondary `physical_id:` alongside `instance_id:`
  (`claim_instance`, `readiness_probe_started`, `readiness_succeeded`, `readiness_failed`,
  `activate_instance_snapshot`, `replace_instance_snapshot`, `remove_instance`).
- An instance config entry literally named `default` is never claimed: `default` is a reserved SSOT
  v3 instance identity that `Identity::InstanceKey` rejects, so the always-present synthetic
  provider_settings template can never be published under name-based identity. The skip is
  unconditional (every tick) and warns once per actor lifetime.
- Embedding-only models (whose `supportedGenerationMethods` contain only `embedContent`) publish
  `chat: :unsupported` and `stream_chat: :unsupported` alongside `embed: :supported`, so they are
  never routed to chat/completion traffic.

### Fixed
- **Single actor registration** - The provider module no longer extends `Core` at file level, so the
  boot-time submodule walk skips it and the gem's own top-level extension load is the sole actor
  registration (eliminates the double-claim / `FencedPublisherError`).

### Dependencies
- Raise `lex-llm` floor from `>= 0.7.0` to `>= 0.7.1` (SSOT v3 fail-forward `InstanceKey` with
  secondary `physical_id`).

## [0.4.2] - 2026-08-13

### Fixed
- **§1 rubocop disables — second remediation pass**: Removed all remaining inline
  `# rubocop:disable` directives from `provider.rb`, `gemini.rb`, and spec files.
  Resolved `Metrics/ClassLength` by extracting `MessageFormatter`, `ResponseParser`, and
  `OfferingBuilder` as sibling modules outside the `Provider` class body; resolved
  `Metrics/ParameterLists`/`Lint/UnusedMethodArgument` on `render_payload` by switching to
  `**opts` with explicit `fetch`/`[]` extraction and splitting assembly into `build_request_payload`;
  resolved `Metrics/AbcSize` on `normalize_instance_config` by extracting `symbolize_config_keys`,
  `promote_api_key`, and `promote_api_base` helpers.
- **§1 spec file path format**: Moved `capability_policy_spec.rb` to
  `provider_capability_policy_spec.rb` and `actors/fleet_worker_spec.rb` to
  `actor/fleet_worker_spec.rb` so paths satisfy `RSpec/SpecFilePathFormat`.
- **§provider-plan blanket chat support**: `Capabilities#supported?` no longer returns `true`
  for all non-embedding actions when `supportedGenerationMethods` is empty; an absent method
  list is now treated as unknown/unsupported for all actions except the embedding name heuristic.
- **§2 second publication engine removed**: Deleted `registry_publisher` class method and
  `attr_writer :registry_publisher` from `Provider`; removed all associated spec assertions.
- **§1 settings guards**: Removed chained `||` fallback in `api_base`; removed `defined?`
  guard in `provider_capability_config`; removed `respond_to?` guards in
  `instance_capability_config`, `model_capability_config`, and `resolve_models_config`.
- **§1 swallowed rescues**: All `rescue` blocks in `provider.rb` and `discovery_refresh.rb`
  now call `handle_exception`; removed silent `rescue StandardError; nil` in
  `resolve_models_config`; `extract_host_port` and `check_health` rescue blocks now log via
  `handle_exception` before returning degraded values.
- **§1 stdlib warn**: Replaced `warn(e.message) if $VERBOSE` in `LoadError` rescue blocks
  with silent rescues (the error is not actionable at file-load time and the defined-guard
  below provides the correct gating behavior).

## [0.4.1] - 2026-08-13

### Fixed
- **§8 health firewall**: `GeminiCallable#normalize_dispatch_error` now maps only an explicit
  Gemini `"status":"UNAVAILABLE"` response body to `:instance_unavailable`. Connection failures,
  timeouts, generic 5xx, 429, auth, and all other transient errors remain request-local and never
  mutate global instance availability.
- **§2 single publication engine**: Removed legacy `RegistryPublisher#publish_models_async` call
  from `Provider#list_models`. Discovery actor via `Inventory::Publisher` is now the sole
  publication path.
- **§1 settings guards**: Replaced `settings[:discovery_interval] || self.class.every_seconds`,
  `settings.dig(:credentials, :api_key)`, `settings[:endpoint] || ...`, and `settings[:tier] || ...`
  with direct registered-default access (`settings[:key]`).
- **§1 rubocop disables**: Removed all inline rubocop:disable annotations; resolved underlying
  `Metrics/ClassLength` by extracting private methods into helper modules
  (`EvidenceBuilder`, `ValueEvidenceBuilder`, `ModelDiscovery`, `ConfigResolver`, `HttpClient`,
  `ProbeRunner`, `HealthChecker`, `InstanceLifecycle`); resolved `Metrics/AbcSize` on
  `claim_and_activate_instance` by splitting into focused helpers; resolved swallowed
  `rescue nil` patterns in `run_cadence_probe` and `handle_reactive_probe` with proper
  `begin/rescue/handle_exception` blocks.
- **§11 conformance spec**: Replaced tautological `empty generation methods` test with a real
  assertion that calls the actor's `build_operation_evidence` method directly.

## [0.4.0] - 2026-08-13

### Changed
- **SSOT v3 provider migration** - Complete rewrite of the discovery actor to use the
  Inventory::Publisher/Registry contract. Replaces the old ScopedRefresher/Legion::LLM::Call::Registry
  discovery mechanism with exact-instance publication via InstanceKey, OfferingDraft snapshots,
  non-billable readiness probes, and normalized ProviderOutcome error classification.
- Introduce GeminiCallable wrapper implementing `disconnect` and `normalize_dispatch_error(error:)`
  contracts required by the SSOT v3 routing layer.
- Derive instance identity as `host:port/ak:<8-char-SHA256-fingerprint>` for API-key-based isolation.
- Operation evidence derived from Gemini `supportedGenerationMethods` array (`:provider_catalog` source).
- Readiness probing via `GET models?pageSize=1` (non-billable, no inference).
- Support coalesced reactive probes after dispatch-triggered `instance_unavailable` transitions.

### Removed
- `default_model: 'gemini-2.0-flash'` fallback from provider settings (SSOT v3 requires explicit
  model selection; no default model or provider inference).

### Dependencies
- Raise `lex-llm` floor from `>= 0.6.0` to `>= 0.7.0`.

## [0.3.18] - 2026-08-04

### Changed
- Prepare the Gemini provider standardization baseline for a patch release.

## [0.3.17] - 2026-07-02

### Fixed
- Emit canonical capability vocabulary (`:embedding`, `:tools`) from `Capabilities.critical_capabilities_for`. `lex-llm` 0.6.1+ retains both the raw and canonical forms on `Model::Info`, so the pre-canonical aliases (`embeddings`, `function_calling`) leaked duplicate tokens (e.g. `[:embeddings, :embedding]`) into discovered model capabilities.

## [0.3.16] - 2026-06-20

### Fixed
- Stub shared registry publishing through `RegistryPublisher#schedule` in specs so async availability-event coverage stays stable after the shared publisher moved off raw `Thread.new`.

## [0.3.15] - 2026-06-20

### Changed
- Align Gemini instance discovery with the shared `lex-llm` contract by preserving explicit tier overrides while defaulting unconfigured instances to `:cloud`.
- Expand instance-level capability override passthrough to the shared `enable_*` vocabulary, including `structured_output`.
- Normalize Gemini contract coverage around canonical `:tools` and `:embedding` capabilities.

## [0.3.14] - 2026-06-19

### Changed
- Adopt `Legion::Extensions::Llm::Inventory::ScopedRefresher` mixin (lex-llm 0.6.0). Discovery
  refresh actors now write directly to the live `Inventory` catalog via `Inventory.write_lane`.
- Pin `lex-llm >= 0.6.0` and `legion-llm >= 0.14.0` in gemspec.
- Standard `weight: 100` default added to provider instance settings schema.

## 0.3.13 - 2026-06-16

- Dependency updates, code quality improvements.

## 0.3.12 - 2026-06-15

- **CapabilityPolicy integration** — `supportedGenerationMethods` mapped to `:model_metadata`. Settings overrides at provider/instance/model level supported.

## 0.3.11 - 2026-06-13

- **Gemfile cleanup** — Remove local path overrides; dependencies resolve from gemspec via rubygems.
- **Dependency bump** — Require `lex-llm >= 0.5.0` for canonical types support.
- **Canonical tool support** — Use `ToolSchema.extract` and add `:tools` capability.
- **Bug fix** — Handle Array tool_calls in `tool_call_parts`.
- 22 examples, 0 failures; 13 files, 0 rubocop offenses.

## 0.3.10 - 2026-06-02

- Add per-provider scoped discovery refresh actor

## 0.3.9 - 2026-05-21

- api_base reads from settings[:endpoint] fallback
- Identity headers included via base provider


## 0.3.8 - 2026-05-08

- Accept keyword arguments in `list_models` to match the base provider contract called by `discover_offerings`.

## 0.3.7 - 2026-05-07

- Build Gemini content endpoint paths from the canonical model id when callers pass `Model::Info` objects.

## 0.3.6 - 2026-05-06

- Load provider-owned fleet actors through the LegionIO subscription base and the canonical Gemini provider root.
- Keep fleet runners anchored on the provider root namespace so provider constants and instance discovery are always loaded.
- Strip temporary generic API key fields from discovered Gemini instance configs after credential deduplication.
- Gate release publishing on the shared security workflow.

## 0.3.5 - 2026-05-06

- Keep the default Gemini endpoint on the versioned `v1beta` API base when instance settings are normalized.
- Refresh the README for the current `lex-llm >= 0.4.3` provider registry and fleet responder boundary.

## 0.3.4 - 2026-05-06

- Use the shared `lex-llm` fleet provider responder helper for provider-owned fleet workers.
- Remove the runtime `legion-llm` dependency and require `lex-llm >= 0.4.3` for responder-side fleet execution.

## 0.3.3 - 2026-05-06

- Remove require-time provider self-registration; `legion-llm` now owns adapter creation and registry writes from loaded provider discovery metadata.
- Bump dependency floors to `lex-llm >= 0.4.1` and `legion-llm >= 0.9.1`.

## 0.3.2 - 2026-05-06

- Add provider contract specs for the shared keyword-only `lex-llm` provider API.
- Move Gemini defaults back to `Legion::Extensions::Llm.provider_settings` with credentials and instance-level fleet responder settings.
- Add provider-owned fleet responder actor and runner backed by `legion-llm` fleet policy execution.
- Bump the transport dependency floor to `legion-transport >= 1.4.14`.

## 0.3.1 - 2026-05-03

- Normalize generic settings keys to Gemini provider config keys during instance discovery.

## 0.3.0 - 2026-05-01

- Add auto-discovery via CredentialSources and AutoRegistration from lex-llm 0.3.0
- Self-register discovered instances into Call::Registry at require-time
- Require lex-llm >= 0.3.0


## 0.2.0 - 2026-04-30

- **Breaking**: Adopt the base contract from lex-llm 0.1.9.
- Replace `default_settings` with a flat settings hash (enabled, default_model, api_key, whitelist/blacklist, tls, instances).
- Remove local `RegistryPublisher` and `RegistryEventBuilder`; use the parameterized base classes from lex-llm.
- Remove local `transport/` directory (exchanges and messages); the shared `llm.registry` transport in lex-llm is used instead.
- Remove the deprecated `Provider.register` call; configuration options are registered directly.
- Update `parse_list_models_response` to use the new `Model::Info` constructor (context_length, modalities_input/output, metadata for max_output_tokens).
- Require `lex-llm >= 0.1.9`.

## 0.1.7 - 2026-04-30

- Audit logging, rescue blocks, and README for full observability.
- Add `Legion::Logging::Helper` to every module and class in lib/.
- Replace all bare rescue blocks and custom `log_publish_failure` with `handle_exception(e, level:, handled:, operation:)`.
- Add info-level action logging for model listing and registry publishing.
- Update README to reflect registry event publishing and observability patterns.

## 0.1.6 - 2026-04-28

- Publish best-effort `llm.registry` discovered-model availability events when transport is already loaded.

## 0.1.5 - 2026-04-28

- Require current shared Legion JSON, logging, settings, and `lex-llm >= 0.1.5` runtime dependencies.

## 0.1.4 - 2026-04-28

- Read Gemini `supportedGenerationMethods` from discovered model metadata when mapping chat, streaming, and embedding capabilities.
- Cover embedding-only model discovery metadata for routing.

## 0.1.3 - 2026-04-28

- Remove the leftover compatibility entrypoint outside the Legion namespace.
- Load specs through the canonical `legion/extensions/llm/gemini` namespace path.
- Keep provider gemspec dependencies scoped to the shared `lex-llm` base gem.

## 0.1.2 - 2026-04-28

- Replace fork-era namespace references with the standard Legion::Extensions::Llm provider contract.
- Remove GitHub-based lex-llm Gemfile fallback so test installs use only a guarded local path or released gem dependency.
- Require lex-llm >= 0.1.3 for the cleaned Legion-native base extension.

## 0.1.1 - 2026-04-27

- Add the Gemini Legion::Extensions::Llm provider class with generateContent, streaming, model listing, and embedContent helpers.
- Use shared `Legion::Extensions::Llm.provider_settings` defaults from `lex-llm`.
- Remove the committed `Gemfile.lock`.

## 0.1.0 - 2026-04-26

- Initial Legion LLM Gemini provider extension scaffold.
