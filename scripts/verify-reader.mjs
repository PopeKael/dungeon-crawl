import assert from 'node:assert/strict';
const base=process.env.APP_URL || 'http://127.0.0.1:3000';
async function probe(origin,body,extra={}) {
 const headers={'Content-Type':'application/json',...extra}; if(origin)headers.Origin=origin;
 return fetch(base+'/api/reader',{method:'POST',headers,body:JSON.stringify(body)});
}
const chats=await (await fetch(base+'/api/chats')).json();
const chatId=chats.chats[0].id;
const chat=await (await fetch(base+'/api/chats/'+chatId)).json();
const userMessage=chat.chat.messages.find(m=>m.role==='user');
assert.equal((await probe(undefined,{})).status,403);
assert.equal((await probe('https://unrelated.example',{})).status,403);
assert.equal((await probe(base,{}, {'Sec-Fetch-Site':'cross-site'})).status,403);
assert.equal((await probe(base,{})).status,400);
assert.equal((await probe(base,{chatId,messageId:crypto.randomUUID()})).status,404);
assert.equal((await probe(base,{chatId,messageId:userMessage.id})).status,404);
console.log('Reader boundaries: 6 passed. No clipboard or keyboard input invoked.');
