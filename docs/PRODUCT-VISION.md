# Dungeon Crawl: Local Interactive Storyteller

## An interactive audiobook and illustrated storybook

Dungeon Crawl began as a fork of [Open Dungeon by newideas99](https://github.com/newideas99/open-dungeon), under the MIT licence. Our direction is an entertainment experience: a storyteller or Dungeon Master creates an ongoing story in response to its participants. The engine should remain setting-agnostic.

The story is generated as people participate. The same starting framework can produce a different adventure every time. The ambition is an effectively unique book created while it is read and heard, across a continuing campaign or a single evening. Fantasy, mystery, horror, science fiction, post-apocalyptic fiction and user-defined worlds all fit.

This document describes product intent. [Project status](../PROJECT-STATUS.md) records what exists; the [roadmap](ROADMAP.md) orders the remaining work.

## The intended experience

Player speaks or types an action → storyteller knows who acted → persistent world and character state informs the response → story advances → prose streams → a voice performs it → important moments can receive scene art → players choose again.

At this checkpoint, typed turns, streamed prose, saved characters and stories, manual Speechify playback and manual illustration prompts work. Participant identity, speech input, integrated local voice performance, automatic state reconciliation and world-pack loading are future work. “Streams” describes progressive output once narration begins; model loading, prefill and compaction can still create an initial wait.

The player should experience a story with room to act, rather than an AI control panel. They can ignore expected paths, retreat, recruit someone, explore, negotiate or fight. Choices should change the adventure and remain consequential later.

## Product pillars

**Great story.** Engaging prose, pacing and atmosphere come first. Provider details, reasoning artefacts and tool syntax should stay out of the narration.

**Meaningful choice.** The storyteller responds to decisions rather than forcing a prewritten route. Failure can open a different path instead of simply ending play.

**Persistent characters and world.** Remember identity, possessions, skills and abilities, relationships, locations, discoveries, unresolved events and consequential choices. Existing character fields, history and summaries provide a starting point. A model being given those fields is not yet a reliable structured state-transition system.

**Voice.** Narration is part of the entertainment, beyond accessibility. Different narrator voices materially change a story's feel. Current Speechify playback is useful, but integrated local narration and voice input still need implementation and acceptance testing.

**Visual storytelling.** Images should be illustrated-book scene plates: new locations, major characters, important discoveries, dramatic encounters or substantial scene changes. The aim is a meaningful visual beat, not an image for every paragraph. Character references should help maintain continuity.

**Local-first.** Where practical, text inference, persistent state, voice and image generation should all be capable of running locally. The current text/state path is local; Speechify is an external reader and the active illustration path produces prompts for manual use. Optional remote backends should remain explicit choices, with clear data boundaries.

## World and lore packs

A world pack is intended to supply background knowledge and constraints describing how a universe operates. It could describe an original fantasy setting, a space-opera universe, a Viking survival world, or an established setting supplied privately by the user. The engine should not hard-code one setting.

Possible sources include compact world bibles, campaign bibles, user-supplied lore/source files and structured persistent state. Future design must distinguish established facts, uncertain information and newly generated events, and decide how relevant lore enters a bounded model context.

There is no interchangeable world-pack loader at this checkpoint. Editable world/scenario text and genre presets are the present entry points. No Forgotten Realms, Warhammer 40K, Valheim or other proprietary setting material should be added to this public repository. Supporting a user's own private source material does not require redistributing it.

## Rules serve the story

We do not aim to simulate every tabletop rule. Resolution should account for ability, equipment, accumulated skills, advantages and disadvantages, difficulty and previous events, while presenting the result primarily as prose.

Rather than stopping for “Roll d20 + 4 against AC 16”, a future resolution system could narrate: “The first strike glances from his breastplate, but your second catches the exposed joint beneath his arm.” Exceptional success and failure can still matter.

Combat needs tension and consequences. Risk, injury, failure and death can exist where narratively justified, but important established protagonists should not die casually through arbitrary model randomness. Continuity and earned character development matter. This is the intended philosophy; the current model prompt does not constitute an enforced combat engine or protagonist-protection guarantee.

## Shared stories begin with identity

The next checkpoint comes from a real use case: several people participating through Discord while one machine runs the storyteller. Before networking, the local application must know who submitted each action and which character it belongs to.

Wazza / Kael checking a door for traps and Jack / Brom watching the corridor must be understood as two separate actors. A small local participant model and explicit message identity are the foundation. Keep single-player friction low and preserve older stories without inventing historical authorship. Accounts and remote transport can wait.
