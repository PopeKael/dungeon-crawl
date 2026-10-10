// Exercise the real migration, persistence and story route in an isolated database.
// All model requests are captured locally; no live stories or inference are touched.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import Database from 'better-sqlite3';
import ts from 'typescript';

const require = createRequire(import.meta.url);
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'dungeon-actors-'));
process.env.SQLITE_DB_PATH = path.join(directory, 'legacy.sqlite');
const legacy = new Database(process.env.SQLITE_DB_PATH);
legacy.exec(`
 CREATE TABLE chats(id TEXT PRIMARY KEY,title TEXT NOT NULL,settings_json TEXT NOT NULL,created_at TEXT NOT NULL,updated_at TEXT NOT NULL);
 CREATE TABLE messages(id TEXT PRIMARY KEY,chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,role TEXT NOT NULL,content TEXT NOT NULL,attachments_json TEXT NOT NULL DEFAULT '[]',image_request_json TEXT,generated_image_json TEXT,created_at TEXT NOT NULL);
 CREATE TABLE characters(id TEXT PRIMARY KEY,chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,name TEXT NOT NULL,details TEXT NOT NULL DEFAULT '',inventory TEXT NOT NULL DEFAULT '',skills TEXT NOT NULL DEFAULT '',spells TEXT NOT NULL DEFAULT '',portrait_json TEXT,created_at TEXT NOT NULL,updated_at TEXT NOT NULL);
 INSERT INTO chats VALUES ('legacy','Legacy','{}','2026-01-01','2026-01-01');
 INSERT INTO messages VALUES ('old-message','legacy','user','> Check the door','[]',NULL,NULL,'2026-01-01');
 INSERT INTO characters VALUES ('old-npc','legacy','Mira','Guide','Lantern','Navigation','',NULL,'2026-01-01','2026-01-01');
`);
legacy.close();
const cache = new Map();
const env = { OLLAMA_BASE_URL:'http://127.0.0.1:11434', LOCAL_TEXT_CONTEXT:'65536', OPENROUTER_MAX_TOKENS:'512' };
function load(file) {
  file=path.resolve(file); if(cache.has(file))return cache.get(file).exports;
  const loaded={exports:{}}; cache.set(file,loaded);
  const localRequire=(id)=>{
    if(id==='@/lib/server-env')return {serverEnv:(key,fallback='')=>env[key]||fallback};
    if(id.startsWith('@/'))return load(`src/${id.slice(2)}.ts`);
    return require(id);
  };
  const compiled=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,esModuleInterop:true}});
  new Function('require','module','exports',compiled.outputText)(localRequire,loaded,loaded.exports);
  return loaded.exports;
}
const originalFetch=globalThis.fetch;
const requests=[];
globalThis.fetch=async (_url,options)=>{
  const body=JSON.parse(options.body); requests.push(body);
  const message={role:'assistant',content:'A distant bell rings beyond the quiet corridor.'};
  return new Response(body.stream ? JSON.stringify({message,done:false})+'\n'+JSON.stringify({done:true})+'\n' : JSON.stringify({message}),
    {headers:{'Content-Type':body.stream?'application/x-ndjson':'application/json'}});
};
try {
  const db=load('src/lib/db.ts');
  const actors=load('src/lib/player-actors.ts');
  const prompt=load('src/lib/story-prompt.ts');
  const route=load('src/app/api/story/route.ts');
  let chat=db.getChat('legacy');
  assert.equal(chat.messages[0].content,'> Check the door');
  assert.equal(chat.messages[0].actorCharacterId,undefined);
  assert.equal(chat.characters[0].controlType,'npc');
  assert.equal(chat.characters[0].playerName,'');
  assert.equal(chat.characters[0].inventory,'Lantern');
  assert.equal(actors.selectedPlayerActor(chat.characters,''),undefined);
  assert.equal(prompt.buildStoryMessages(chat.messages,'> Enter',chat.settings,chat.characters)[1].content,'> Check the door');
  assert.equal(actors.formatPlayerInput('say','Hello'),'> You say "Hello"');

  const kael=db.createCharacter(chat.id,{name:'Kael',controlType:'player',playerName:'Wazza',inventory:'Lockpicks',skills:'Traps'});
  const one=db.listCharacters(chat.id);
  assert.equal(actors.selectedPlayerActor(one,'')?.id,kael.id,'Single player automatically selected');
  assert.equal(actors.selectedPlayerActor(one,'old-npc')?.id,kael.id,'NPC cannot become actor');
  const brom=db.createCharacter(chat.id,{name:'Brom',controlType:'player',playerName:'Jack'});
  const several=db.listCharacters(chat.id);
  assert.deepEqual(new Set(actors.playerCharacters(several).map(c=>c.name)),new Set(['Kael','Brom']));
  assert.equal(actors.selectedPlayerActor(several,''),undefined,'Multiple players need an explicit choice');
  assert.equal(actors.selectedPlayerActor(several,brom.id).id,brom.id);
  assert.equal(actors.selectedPlayerActor(several,'old-npc'),undefined,'NPC excluded with multiple players');

  const settings={...chat.settings,textProvider:'custom',customBaseUrl:env.OLLAMA_BASE_URL+'/v1',customModel:'qwen3.5:4b',imageGenerationEnabled:false};
  async function turn(overrides={}) {
    return route.POST(new Request('http://localhost/api/story',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({chatId:chat.id,mode:'turn',input:'> Check the door',settings,messages:[],...overrides})}));
  }
  const initialCount=db.getChat(chat.id).messages.length;
  for(const actorCharacterId of ['old-npc','missing',db.createCharacter(db.createChat(settings,'Other').id,{name:'Outsider',controlType:'player'}).id]) {
    assert.equal((await turn({actorCharacterId})).status,400);
  }
  assert.equal(db.getChat(chat.id).messages.length,initialCount,'Invalid actors rejected before persistence');
  assert.equal(requests.length,0);
  assert.equal((await turn({userMessageId:'kael-turn',actorCharacterId:kael.id})).status,200);
  let sent=requests.at(-1).messages;
  assert.match(sent.at(-1).content,/Acting player character: Kael/);
  assert.ok(!JSON.stringify(sent).includes('Wazza'),'Real display name stays out of narration');
  const saved=db.getChat(chat.id).messages.find(m=>m.id==='kael-turn');
  assert.equal(saved.actorCharacterId,kael.id); assert.equal(saved.actorCharacterName,'Kael');
  assert.equal((await turn({userMessageId:'brom-turn',actorCharacterId:brom.id,input:actors.formatPlayerInput('say','Watch the corridor',brom),messages:[saved]})).status,200);
  sent=requests.at(-1).messages;
  assert.match(sent[1].content,/Acting player character: Kael/);
  assert.match(sent.at(-1).content,/Acting player character: Brom/);
  assert.match(sent.at(-1).content,/Brom says "Watch the corridor"/);

  db.updateCharacter(chat.id,kael.id,{name:'Kael the Bold',playerName:'Warren'});
  assert.equal(actors.actorLabel(saved,db.listCharacters(chat.id)),'Kael','Historical name survives renaming');
  db.deleteCharacter(chat.id,kael.id);
  assert.equal(actors.actorLabel(saved,db.listCharacters(chat.id)),'Kael','Historical name survives deletion');
  assert.equal((await turn({mode:'retry',retryOfMessageId:saved.id,input:'wrong text'})).status,200);
  assert.match(requests.at(-1).messages.at(-1).content,/Acting player character: Kael/);
  assert.equal(db.getChat(chat.id).messages.filter(m=>m.id===saved.id).length,1);
  assert.equal((await turn({userMessageId:'legacy-new'})).status,200);
  assert.equal(requests.at(-1).messages.at(-1).content,'> Check the door','Actorless input unchanged');

  const streamed=await turn({mode:'random-event',input:'Force combat',actorCharacterId:brom.id,userMessageId:'event',stream:true});
  const streamText=await streamed.text();
  assert.match(streamText,/"type":"delta"/); assert.match(streamText,/"type":"done"/);
  assert.equal(requests.at(-1).messages.at(-1).content,actors.RANDOM_EVENT_DIRECTIVE);
  const event=db.getChat(chat.id).messages.find(m=>m.id==='event');
  assert.equal(event.inputKind,'random-event'); assert.equal(event.actorCharacterId,undefined);
  assert.equal(event.content,'> Random Event');
  await turn({mode:'retry',retryOfMessageId:'event'});
  assert.equal(requests.at(-1).messages.at(-1).content,actors.RANDOM_EVENT_DIRECTIVE,'Retry repeats event request');
  assert.equal(prompt.buildStoryMessages([event],'Next',settings,several)[1].content,actors.RANDOM_EVENT_DIRECTIVE);

  const history=[{...saved,content:'Long passage '.repeat(20000)},{...saved,id:'brom-history',actorCharacterId:brom.id,actorCharacterName:'Brom',content:'I watch the corridor'},{...saved,id:'recent',content:'Wait here'}];
  const before=requests.length;
  await turn({messages:history});
  assert.equal(requests.length,before+2,'Evicted history triggers summary then narration');
  assert.match(requests[before].messages[1].content,/Acting player character: Kael/);
  assert.match(requests[before].messages[1].content,/Acting player character: Brom/);
  assert.equal(globalThis.__localRoleplayDb.pragma('integrity_check',{simple:true}),'ok');
  globalThis.__localRoleplayDb.close(); globalThis.__localRoleplayDb=undefined;
  chat=db.getChat('legacy');
  assert.equal(chat.messages.find(m=>m.id==='kael-turn').actorCharacterId,kael.id,'Identity survives DB reopen');
  assert.equal(chat.characters.find(c=>c.id===brom.id).playerName,'Jack');
  assert.equal(chat.messages.find(m=>m.id==='old-message').actorCharacterId,undefined);
  console.log('Passed: legacy migration/input, single-player auto-selection, multiple actors, NPC/cross-story rejection, persisted attribution, rename/delete/retry, random-event streaming/retry, compaction identity and database reopen. No live inference or story writes.');
} finally {
  globalThis.fetch=originalFetch;
  globalThis.__localRoleplayDb?.close(); globalThis.__localRoleplayDb=undefined;
  delete process.env.SQLITE_DB_PATH;
  fs.rmSync(directory,{recursive:true,force:true});
}
