# Changelog

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
