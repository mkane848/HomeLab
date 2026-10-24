# Chat templates for llama-server seats

Jinja chat templates that a seat in `../models.ini` loads with `chat-template-file`, for weights whose own
embedded template is missing or unusable. The compose file mounts this folder read-only at `/config/templates`.

| File | Used by | Source | Why |
|---|---|---|---|
| `openai-gpt-oss-120b.jinja` | `[gpt-oss:20b]` | llama.cpp `models/templates/openai-gpt-oss-120b.jinja` at tag `b11561` (the server's build), byte for byte; MIT, Copyright (c) 2023-2026 The ggml authors | Ollama's `gpt-oss:20b` blob has no usable template: llama-server fell back to a generic ChatML one with no tool support, and the probe failed with the model's reasoning in its answer. With this file the probe passed (2026-10-23, `docs/roadmap.md` → "After the trial" item 9). |

Keep each file verbatim: a template is part of the model's input, so a change is a new era for its rows. When the
server's llama.cpp build moves, re-fetch from the new tag and re-probe.
