# lex-llm-gemini

LegionIO LLM provider extension for Google Gemini.

This gem lives under `Legion::Extensions::Llm::Gemini` and depends on `lex-llm` for shared provider-neutral routing, fleet, and schema primitives.

Load it with `require 'legion/extensions/llm/gemini'`.

## What It Provides

- `Legion::Extensions::Llm::Provider` registration as `:gemini`
- Gemini-native chat requests through `POST /v1beta/{model=models/*}:generateContent`
- Streaming chat support through `POST /v1beta/{model=models/*}:streamGenerateContent?alt=sse`
- Model discovery through `GET /v1beta/models`
- Embeddings through `POST /v1beta/{model=models/*}:embedContent`
- Normalized chat, streaming, vision, function calling, and embedding capability mapping from `supportedGenerationMethods`
- Best-effort `llm.registry` availability events published to AMQP when transport is loaded
- Shared fleet/default settings via `Legion::Extensions::Llm.provider_settings`

## File Map

| Path | Purpose |
|------|---------|
| `lib/legion/extensions/llm/gemini.rb` | Entry point; provider registration |
| `lib/legion/extensions/llm/gemini/provider.rb` | Gemini provider (chat, streaming, models, embeddings) |
| `lib/legion/extensions/llm/gemini/registry_event_builder.rb` | Builds sanitized lex-llm registry event envelopes |
| `lib/legion/extensions/llm/gemini/registry_publisher.rb` | Best-effort async publisher for model availability events |
| `lib/legion/extensions/llm/gemini/transport/exchanges/llm_registry.rb` | `llm.registry` AMQP topic exchange |
| `lib/legion/extensions/llm/gemini/transport/messages/registry_event.rb` | AMQP message wrapper for registry events |
| `lib/legion/extensions/llm/gemini/version.rb` | `VERSION` constant |

## Defaults

```ruby
Legion::Extensions::Llm::Gemini.default_settings
# {
#   provider_family: :gemini,
#   instances: {
#     default: {
#       endpoint: "https://generativelanguage.googleapis.com/v1beta",
#       tier: :frontier,
#       transport: :http,
#       credentials: { api_key: "env://GEMINI_API_KEY" },
#       usage: { inference: true, embedding: true },
#       limits: { concurrency: 4 }
#     }
#   }
# }
```

## Configuration

```ruby
Legion::Extensions::Llm.configure do |config|
  config.gemini_api_key = ENV.fetch("GEMINI_API_KEY")
  config.gemini_api_base = "https://generativelanguage.googleapis.com/v1beta"
  config.default_model = "gemini-2.0-flash"
  config.default_embedding_model = "gemini-embedding-001"
end
```

## Observability

Every module and class includes or extends `Legion::Logging::Helper`:

- **Info-level logging** on `list_models` and registry event publishing.
- **All rescue blocks** call `handle_exception(e, level:, handled:, operation:)` for structured exception telemetry.
- Registry publishing is best-effort; failures are handled at `:debug` or `:warn` level and never block the caller.

## Development

```bash
bundle install
bundle exec rspec       # 0 failures
bundle exec rubocop -A  # auto-fix
bundle exec rubocop     # lint check
```

## License

Apache-2.0
