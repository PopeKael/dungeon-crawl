# Ollama model selector

Open **Text Model** in the story sidebar and choose from **Ollama model library**. The list reads the configured Ollama server; it is not a fixed catalogue. Refresh models reads the library again after models are added or removed. Selection applies to the next narration request and uses the existing story-settings autosave. Save & return explicitly saves it too. Existing app-wide defaults continue to remember the last saved selection for new stories; the environment fallback remains `qwen3.5:4b`.

The server-only GET `/api/models` reads `/api/tags` and each model's `/api/show` metadata. Only models with `completion` capability appear; embedding-only models are excluded. This does not download, load, unload or generate with models. Requests have five-second timeouts. If Ollama is unavailable the UI keeps the selected model, shows an error and offers Refresh models. The manual model field remains available for other compatible servers or custom IDs. The picker currently appears for Ollama's standard port 11434 and verifies the configured library server matches the story's backend URL.

API references: [Ollama model list](https://docs.ollama.com/api/tags), [Ollama model details and capabilities](https://github.com/ollama/ollama/blob/main/docs/api.md#show-model-information).

Library selections whose backend URL matches the configured `OLLAMA_BASE_URL` now generate through native `/api/chat`, with explicit `options.num_ctx` from `LOCAL_TEXT_CONTEXT` (65,536 in this installation). Saved custom-provider model selections need no migration. Both narration and rolling summaries use this allocation; the history budget follows it. Other OpenAI-compatible endpoints retain their protocol. See [context configuration](phase1-local.md#persistence-and-context-boundaries).

## Verified 10 October 2026

- Lint and production build passed.
- Live endpoint returned eight installed text models, including Qwen 3.5 4B and 9B; excluded nomic-embed-text.
- Selected 9B in the browser, saved, reloaded and resumed; the story retained the 9B selection.
- Restored 4B, refreshed the library, and confirmed both saved story and new-story defaults use 4B.
- All 35 messages remained unchanged; no narration was generated during this check.
- Screenshot: ignored `logs/ollama-model-selector.jpg`.

To reverse this interface addition, remove `/api/models`, `OllamaModelSelect` and its insertion in TextModelPanel, restoring the manual model field as the primary input. Saved model IDs remain compatible with the existing request route.
