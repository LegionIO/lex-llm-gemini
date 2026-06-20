# Changelog

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
