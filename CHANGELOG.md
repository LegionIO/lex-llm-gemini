# Changelog

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
