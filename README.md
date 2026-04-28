# lex-llm-gemini

LegionIO LLM provider extension for Gemini.

This gem lives under `Legion::Extensions::Llm::Gemini` and depends on `lex-llm` for shared provider-neutral routing, fleet, and schema primitives.

## What It Provides

- `Legion::Extensions::Llm::Provider` registration as `:gemini`
- Gemini-native chat requests through `POST /v1beta/{model=models/*}:generateContent`
- streaming chat support through `POST /v1beta/{model=models/*}:streamGenerateContent?alt=sse`
- model discovery through `GET /v1beta/models`
- embeddings through `POST /v1beta/{model=models/*}:embedContent`
- shared fleet/default settings via `Legion::Extensions::Llm.provider_settings`

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
