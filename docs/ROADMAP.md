# Development roadmap

Product intent is in [PRODUCT-VISION.md](PRODUCT-VISION.md); completed work and verification limits are in [PROJECT-STATUS.md](../PROJECT-STATUS.md). Items below are not implemented unless status explicitly says otherwise.

## Next checkpoint: local multi-participant story input

Introduce a participant with an ID, display name and optional linked `StoryCharacter` ID. No accounts, Discord integration or network multiplayer in this first pass.

Acceptance requirements:

- Select the acting participant/character before submitting a turn.
- Persist participant identity and the optional character link with each new message.
- Display the actor clearly in story history and send the identity explicitly to the storyteller.
- Distinguish simultaneous participants' intentions, such as Kael checking a door while Brom watches the corridor.
- Preserve existing messages without assigning invented authorship; keep old stories and the single-player path compatible and frictionless.
- Verify persistence across reload/resume, participant selection, narrator payload identity and legacy-story behaviour before adding transport.

Implementation begins only after the documentation/repository checkpoint has been completed and reported.

## Later checkpoints

1. **Stronger continuity:** structured world/character state, consequential changes, relationships, locations and unresolved events; improve and verify long-session memory before claiming reliable recall.
2. **World/lore packs:** interchangeable original or privately user-supplied world/campaign bibles, with bounded context injection and no redistributed proprietary settings.
3. **Voice performance and input:** evaluate integrated local narration, narrator voices and speech input; build on the current manual Speechify handoff.
4. **Scene illustrations:** validate local generation on the target hardware, reference continuity and deliberate scene-plate pacing. Preserve manual prompts as a usable option.
5. **Shared/Discord play:** add transport only after local identity is solid; define access control, session ownership and remote input boundaries first.

These are an ordered direction, not delivery dates. Story quality, meaningful choice, continuity and practical local operation remain the acceptance criteria.
