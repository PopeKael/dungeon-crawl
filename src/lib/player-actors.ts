import type { StoryCharacter, StoryMessage } from "@/lib/types";

export const RANDOM_EVENT_DIRECTIVE = "Introduce an unexpected but plausible event appropriate to the current scene, world and tone. Respect established facts and continuity. Do not choose or force actions, thoughts or dialogue for player characters. The event need not create combat. Narrate the event, then leave the players free to respond.";

export function playerCharacters(characters: StoryCharacter[]) {
  return characters.filter((character) => character.controlType === "player");
}

export function selectedPlayerActor(characters: StoryCharacter[], selectedId: string) {
  const players = playerCharacters(characters);
  return players.find((character) => character.id === selectedId) ||
    (players.length === 1 ? players[0] : undefined);
}

export function actorLabel(message: Pick<StoryMessage, "actorCharacterId" | "actorCharacterName">, characters: StoryCharacter[]) {
  if (!message.actorCharacterId) return "";
  return message.actorCharacterName || characters.find((character) => character.id === message.actorCharacterId)?.name ||
    `Character ${message.actorCharacterId}`;
}

export function attributedInput(message: Pick<StoryMessage, "content" | "actorCharacterId" | "actorCharacterName" | "inputKind">, characters: StoryCharacter[]) {
  if (message.inputKind === "random-event") return RANDOM_EVENT_DIRECTIVE;
  if (!message.actorCharacterId) return message.content;
  return `[Acting player character: ${actorLabel(message, characters)}; character ID: ${message.actorCharacterId}]\n${message.content}`;
}

export function formatPlayerInput(mode: "do" | "say", text: string, actor?: StoryCharacter) {
  const trimmed = text.trim();
  if (mode === "say") {
    const quoted = /^["'"].*["'"]$/.test(trimmed) ? trimmed : `"${trimmed}"`;
    return `> ${actor ? `${actor.name} says` : "You say"} ${quoted}`;
  }
  return `> ${trimmed}`;
}
