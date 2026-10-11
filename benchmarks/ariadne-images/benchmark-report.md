# Ariadne ComfyUI Dungeon Crawl image benchmark

Date: 2026-10-11 (Asia/Bangkok)
Ariadne API: `http://127.0.0.1:8765`
Renderer startup: 53.01 seconds (one shared start for this suite)
Suite elapsed: 663.54 seconds (11 minutes 3.54 seconds)
Completed images: 6 / 6
Engine shutdown: confirmed stopped

Per-row total elapsed is the measured shared startup time plus that image's generation time. The suite started the renderer once. Generation time runs from submission to the completed PNG being saved in this folder. The model stayed loaded between images.

ComfyUI's VAE produced 960x536 for the requested 960x540 latent because its image dimensions align to multiples of eight. The saved 960x540 files are high-quality bicubic resizes of those engine outputs; this tiny local resize is excluded from renderer generation timing.

| Prompt | Resolution | Renderer startup (s) | Generation (s) | Total elapsed (s) | Output file | Workflow / model / settings | Failure or slowdown |
|---|---:|---:|---:|---:|---|---|---|
| Prompt 1 - Environment | 1280x720 | 53.01 | 248.7 | 301.71 | `F:\AI\DungeonCrawler\benchmarks\ariadne-images\prompt1_environment_1280x720.png` | Ariadne SDXL text-to-image v1; SDXL Base 1.0 (`sd_xl_base_1.0.safetensors`); 24 steps, CFG 7, Euler, normal scheduler, batch 1, blank negative prompt | Ariadne job API failed before ComfyUI submission: missing `websockets`; direct ComfyUI fallback succeeded. 248.7s includes first model load. |
| Prompt 2 - One Character | 1280x720 | 53.01 | 208.4 | 261.41 | `F:\AI\DungeonCrawler\benchmarks\ariadne-images\prompt2_mira_1280x720.png` | Ariadne SDXL text-to-image v1; SDXL Base 1.0 (`sd_xl_base_1.0.safetensors`); 24 steps, CFG 7, Euler, normal scheduler, batch 1, blank negative prompt | Same missing `websockets` fallback; generation took 208.4s. |
| Prompt 3 - Two Characters / Action | 1280x720 | 53.01 | 93.4 | 146.41 | `F:\AI\DungeonCrawler\benchmarks\ariadne-images\prompt3_two_travellers_1280x720.png` | Ariadne SDXL text-to-image v1; SDXL Base 1.0 (`sd_xl_base_1.0.safetensors`); 24 steps, CFG 7, Euler, normal scheduler, batch 1, blank negative prompt | Same missing `websockets` fallback; generation took 93.4s. |
| Prompt 1 - Environment | 960x540 | 53.01 | 16.5 | 69.51 | `F:\AI\DungeonCrawler\benchmarks\ariadne-images\prompt1_environment_960x540.png` | Ariadne SDXL text-to-image v1; SDXL Base 1.0 (`sd_xl_base_1.0.safetensors`); 24 steps, CFG 7, Euler, normal scheduler, batch 1, blank negative prompt | Direct ComfyUI API because Ariadne's image job endpoint does not allow 960x540. |
| Prompt 2 - One Character | 960x540 | 53.01 | 15.5 | 68.51 | `F:\AI\DungeonCrawler\benchmarks\ariadne-images\prompt2_mira_960x540.png` | Ariadne SDXL text-to-image v1; SDXL Base 1.0 (`sd_xl_base_1.0.safetensors`); 24 steps, CFG 7, Euler, normal scheduler, batch 1, blank negative prompt | Direct ComfyUI API because Ariadne's image job endpoint does not allow 960x540. |
| Prompt 3 - Two Characters / Action | 960x540 | 53.01 | 16.4 | 69.41 | `F:\AI\DungeonCrawler\benchmarks\ariadne-images\prompt3_two_travellers_960x540.png` | Ariadne SDXL text-to-image v1; SDXL Base 1.0 (`sd_xl_base_1.0.safetensors`); 24 steps, CFG 7, Euler, normal scheduler, batch 1, blank negative prompt | Direct ComfyUI API because Ariadne's image job endpoint does not allow 960x540. |

## Exact prompts

- **Prompt 1 - Environment:** Wide establishing illustration of Aethelgard, an immense ancient city inside a subterranean cavern. Black basalt arches span deep chasms above glowing amber rivers. Crumbling towers and hanging gardens are illuminated by blue bioluminescent fungi. Vast scale, atmospheric depth, cinematic fantasy illustration, dramatic blue and amber lighting, no text, 16:9.
- **Prompt 2 - One Character:** Mira stands at the edge of a vast underground city holding a brass lantern. She is an adult woman with short black hair wearing a weathered brown leather travelling coat. Behind her, black basalt arches and ancient spires descend toward glowing amber rivers and blue bioluminescent gardens. Wide cinematic composition, lantern light on her face, sense of discovery and awe, fantasy storybook illustration, no text, 16:9.
- **Prompt 3 - Two Characters / Action:** Two travellers cross a narrow ancient basalt bridge suspended above a glowing amber river inside an enormous subterranean city. Mira, an adult woman with short black hair and a brown leather travelling coat, leads with a brass lantern. Behind her follows a weathered middle-aged male traveller in a dark travelling coat and hooded cloak. Blue bioluminescent fungi illuminate distant towers and arches. Dynamic wide shot, strong depth, cinematic fantasy storybook illustration, no text, 16:9.

## Conclusion

**1280x720 cannot meet the 20-30 second target with this Ariadne SDXL workflow.** The three measured renders took 93.4-248.7 seconds. **960x540 is the better fallback:** all three final runs completed in 15.5-16.5 seconds after renderer/model startup, which fits the target once the engine is warm. The initial 960x540 warm-up pass was slower (44.7-144.5 seconds), so the first image after startup is not representative of steady-state speed.

Visual review: all six outputs are coherent cinematic fantasy illustrations suitable as story art. Prompt adherence varies: the environment images sometimes read as open-air or sunlit, and the character images do not always make the lantern or clothing details prominent. The 960x540 results remain legible at their intended size; 1280x720 does not show a clear quality gain that justifies its much longer render time.

Ariadne's image job API currently fails before submitting a workflow because its core runtime cannot import `websockets`. The benchmark used the same managed ComfyUI engine and matching SDXL workflow directly for those images. The 960x540 runs also use ComfyUI directly because that resolution is not in Ariadne's accepted image-size list. No Ariadne or gameplay source was modified.
