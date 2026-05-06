# lex-llm-gemini

LegionIO LLM provider extension for Google Gemini.

This gem lives under `Legion::Extensions::Llm::Gemini` and depends on `lex-llm >= 0.4.3` for shared provider-neutral routing, response normalization, fleet responder execution, and schema primitives. It does not require or call `legion-llm` at runtime; `legion-llm` owns adapter creation, routing, and registry writes after discovering loaded `lex-llm-*` provider gems.

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
| `lib/legion/extensions/llm/gemini.rb` | Entry point; provider discovery metadata and defaults |
| `lib/legion/extensions/llm/gemini/provider.rb` | Gemini provider (chat, streaming, models, embeddings) |
| `lib/legion/extensions/llm/gemini/actors/fleet_worker.rb` | Provider-owned fleet subscription actor |
| `lib/legion/extensions/llm/gemini/runners/fleet_worker.rb` | Fleet runner delegating to `Legion::Extensions::Llm::Fleet::ProviderResponder` |
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

## Fleet Responder

Provider instances can opt in to consuming Legion LLM fleet requests. The provider-owned fleet actor only starts when at least one discovered instance enables `fleet.respond_to_requests`, and execution delegates to `Legion::Extensions::Llm::Fleet::ProviderResponder` from `lex-llm`.

```yaml
extensions:
  llm:
    gemini:
      instances:
        local:
          fleet:
            enabled: true
            respond_to_requests: true
            capabilities:
              - chat
              - stream_chat
              - embed
```

## Observability

The Gemini entry point and provider use `Legion::Logging::Helper`:

- `list_models` logs model discovery activity and publishes availability through the shared `lex-llm` registry publisher.
- Fleet request execution is delegated to the shared responder helper so acking, response publishing, and responder failures stay inside the provider-neutral fleet boundary.
- Registry publishing is best-effort and must not block provider calls when transport is unavailable.

## Development

```bash
bundle install
bundle exec rspec --format json --out tmp/rspec_results.json --format progress --out tmp/rspec_progress.txt
bundle exec rubocop -A
```

## License

Apache-2.0
