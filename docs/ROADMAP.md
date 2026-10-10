# Development roadmap

Product intent is in [PRODUCT-VISION.md](PRODUCT-VISION.md); completed work and verification limits are in [PROJECT-STATUS.md](../PROJECT-STATUS.md). Items below are not implemented unless status explicitly says otherwise.

## Implemented locally: first multi-participant story input

Use the existing `StoryCharacter` as the actor. Characters are NPCs or human-controlled Player Characters, with an optional real-player display name. There is no separate participant/account model, Discord integration or network multiplayer.

Acceptance requirements:

- Select the acting Player Character before submitting a Do or Say turn; one player auto-selects and NPCs are excluded.
- Persist `actorCharacterId` and a character-name snapshot with each attributed message.
- Display the actor clearly in story history and send the identity explicitly to the storyteller.
- Distinguish simultaneous participants' intentions, such as Kael checking a door while Brom watches the corridor.
- Preserve existing messages without assigning invented authorship; keep old stories and the single-player path compatible and frictionless.
- Verify persistence across reload/resume, actor selection, narrator payload identity and legacy-story behaviour before adding transport.
- Replace Story composer mode with Random Event, requesting a plausible surprise without forcing player actions or combat. Preserve Attach.

Implementation and isolated regression coverage are described in [Player Characters](player-characters.md). Further work should strengthen continuity before adding transport.

## Later checkpoints

1. **Stronger continuity:** structured world/character state, consequential changes, relationships, locations and unresolved events; improve and verify long-session memory before claiming reliable recall.
2. **World/lore packs:** interchangeable original or privately user-supplied world/campaign bibles, with bounded context injection and no redistributed proprietary settings.
3. **Voice performance and input:** evaluate integrated local narration, narrator voices and speech input; build on the current manual Speechify handoff.
4. **Scene illustrations:** validate local generation on the target hardware, reference continuity and deliberate scene-plate pacing. Preserve manual prompts as a usable option.
5. **Shared/Discord play:** add transport only after local identity is solid; define access control, session ownership and remote input boundaries first.

These are an ordered direction, not delivery dates. Story quality, meaningful choice, continuity and practical local operation remain the acceptance criteria.
