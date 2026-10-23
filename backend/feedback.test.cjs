const {test} = require('node:test');
const assert = require('node:assert/strict');
const {validatePayload,safeCell,canonicalPayload,doPost} = require('./Code.js');
const valid = () => ({submissionID:'7FAAAABB-1234-4567-8901-123456789012',source:'okiru-ios',appName:'Okiru',category:'bug',summary:' Test ',details:'Details',appVersion:'1.0',buildNumber:'1',osVersion:'iOS 26',displayLanguage:'zh-Hant'});
test('normalizes fields and stable idempotency key',()=> { const p=validatePayload(valid()); assert.equal(p.summary,'Test'); assert.equal(p.submissionID,'7faaaabb-1234-4567-8901-123456789012'); });
test('requires explicit supported source/category',()=> { for(const key of ['source','category','submissionID']) assert.throws(()=>validatePayload({...valid(),[key]:'wrong'})); });
test('rejects empty and oversized payload fields',()=> { for(const [key,value] of [['summary',' '],['summary','a'.repeat(161)],['details','a'.repeat(4001)],['details',{}]]) assert.throws(()=>validatePayload({...valid(),[key]:value})); });
test('optional email is validated',()=> { assert.equal(validatePayload(valid()).replyEmail,''); assert.throws(()=>validatePayload({...valid(),replyEmail:'not-an-email'})); });
test('formula prefixes are escaped including whitespace',()=> { for(const value of ['=IMPORTXML(1)',' +1','-2','@SUM(A1)','\t=1']) assert.equal(safeCell(value),"'"+value); assert.equal(safeCell('Hello'),'Hello'); });
test('retries ignore timestamp but changed text has a different digest input',()=> { assert.equal(canonicalPayload(validatePayload(valid())),canonicalPayload(validatePayload({...valid(),submittedAt:'tomorrow'}))); assert.notEqual(canonicalPayload(validatePayload(valid())),canonicalPayload(validatePayload({...valid(),details:'Changed'}))); });

function mockAppsScript({configured=true,flushFails=false,busy=false}={}) {
  const rows=[]; const cache=new Map(); let locked=false, released=false;
  const sheet={getLastRow:()=>rows.length,appendRow:row=>rows.push(row),getRange:(row,col)=>({
    getValue:()=>rows[row-1][col-1],
    createTextFinder:value=>({matchEntireCell:()=>({findNext:()=>{
      const index=rows.findIndex((r,i)=>i>0&&r[0]===value);
      return index<0?null:{getRow:()=>index+1};
    }})})
  })};
  global.ContentService={MimeType:{JSON:'json'},createTextOutput:text=>({setMimeType:()=>JSON.parse(text)})};
  global.Utilities={DigestAlgorithm:{SHA_256:'sha256'},Charset:{UTF_8:'utf8'},computeDigest:(_,text)=>Array.from(require('node:crypto').createHash('sha256').update(text).digest())};
  global.LockService={getScriptLock:()=>({tryLock:()=>locked=!busy,hasLock:()=>locked,releaseLock:()=>{locked=false;released=true;}})};
  global.PropertiesService={getScriptProperties:()=>({getProperty:()=>configured?'test-sheet':null})};
  global.SpreadsheetApp={openById:()=>({getSheetByName:()=>sheet}),flush:()=>{if(flushFails)throw Error('offline');}};
  global.CacheService={getScriptCache:()=>({get:key=>cache.get(key),put:(key,value)=>cache.set(key,value)})};
  return {rows,released:()=>released};
}
const post = payload => doPost({postData:{contents:JSON.stringify(payload)}});
test('successful submit and identical retry append once and release lock',()=>{
  const state=mockAppsScript(); const first=post(valid()); const retry=post(valid());
  assert.equal(first.ok,true); assert.equal(retry.ok,true); assert.equal(retry.duplicate,true);
  assert.equal(state.rows.length,2); assert.equal(state.released(),true);
});
test('same ID with changed payload is rejected without another row',()=>{
  const state=mockAppsScript(); post(valid()); const result=post({...valid(),details:'different'});
  assert.equal(result.ok,false); assert.equal(result.error,'id_conflict'); assert.equal(state.rows.length,2);
});
test('missing configuration, lock contention, and persistence failure never return success',()=>{
  for(const options of [{configured:false},{busy:true},{flushFails:true}]) {
    mockAppsScript(options); assert.equal(post(valid()).ok,false);
  }
});
test('Unicode scalar limits include emoji and combining marks',()=>{
  assert.equal(validatePayload({...valid(),summary:'😀'.repeat(160)}).summary.length,320);
  assert.throws(()=>validatePayload({...valid(),summary:'e\u0301'.repeat(81)}));
});
