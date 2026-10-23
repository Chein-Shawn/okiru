/* Okiru dedicated Apps Script web app. No credentials belong in this file.
 * Set SPREADSHEET_ID in Script Properties. Deploy as owner, access Anyone.
 * The public endpoint has input limits and idempotency, not caller authentication.
 */
const HEADERS = ['Submission ID', 'Payload hash', 'Received at', 'Category', 'Summary', 'Details', 'Reply email', 'App version', 'Build', 'OS', 'Language'];
function cleanText(value, max, required) {
  if (typeof value !== 'string') {
    if (!required && (value === undefined || value === null)) return '';
    throw new Error('invalid_field');
  }
  const text = value.trim();
  // Match the Swift client's Unicode scalar limit, including emoji sequences.
  if ((required && !text) || Array.from(text).length > max || /[\u0000\u0008\u000B\u000C]/.test(text)) throw new Error('invalid_field');
  return text;
}
function validatePayload(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('invalid_payload');
  const id = cleanText(input.submissionID, 36, true);
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) throw new Error('invalid_id');
  if (input.source !== 'okiru-ios' || input.appName !== 'Okiru') throw new Error('invalid_source');
  if (!['bug','idea','other'].includes(input.category)) throw new Error('invalid_category');
  const email = cleanText(input.replyEmail, 254, false);
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new Error('invalid_email');
  return {
    submissionID:id.toLowerCase(), category:input.category,
    summary:cleanText(input.summary,160,true), details:cleanText(input.details,4000,true), replyEmail:email,
    appVersion:cleanText(input.appVersion,32,true), buildNumber:cleanText(input.buildNumber,32,true),
    osVersion:cleanText(input.osVersion,160,true), displayLanguage:cleanText(input.displayLanguage,32,true)
  };
}
function safeCell(text) {
  // Prevent Sheets formulas, including formulas behind leading whitespace.
  return /^[\s]*[=+\-@]/.test(String(text)) ? "'" + text : String(text);
}
function canonicalPayload(payload) { return JSON.stringify(payload); }
function jsonReply(body) { return ContentService.createTextOutput(JSON.stringify(body)).setMimeType(ContentService.MimeType.JSON); }
function doGet() { return jsonReply({ok:true,service:'Okiru feedback',version:1}); }
function doPost(e) {
  let lock;
  try {
    if (!e || !e.postData || typeof e.postData.contents !== 'string' || e.postData.contents.length > 30000) throw new Error('invalid_payload');
    const payload = validatePayload(JSON.parse(e.postData.contents));
    const hash = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, canonicalPayload(payload), Utilities.Charset.UTF_8)
      .map(b => (b & 255).toString(16).padStart(2,'0')).join('');
    lock = LockService.getScriptLock();
    if (!lock.tryLock(10000)) return jsonReply({ok:false,error:'busy'});
    const id = PropertiesService.getScriptProperties().getProperty('SPREADSHEET_ID');
    if (!id) return jsonReply({ok:false,error:'not_configured'});
    const book = SpreadsheetApp.openById(id);
    const sheet = book.getSheetByName('Feedback') || book.insertSheet('Feedback');
    if (sheet.getLastRow() === 0) sheet.appendRow(HEADERS);
    const last = sheet.getLastRow();
    if (last > 1) {
      const match = sheet.getRange(2,1,last-1,1).createTextFinder(payload.submissionID).matchEntireCell(true).findNext();
      if (match) {
        const oldHash = sheet.getRange(match.getRow(),2).getValue();
        return jsonReply(oldHash === hash ? {ok:true,submissionID:payload.submissionID,duplicate:true} : {ok:false,error:'id_conflict'});
      }
    }
    // Public deployments also need abuse monitoring. Do not collect device IDs/IPs.
    // Global cap bounds accidental abuse without claiming per-person authentication.
    const cache = CacheService.getScriptCache();
    const bucket = 'minute:' + Math.floor(Date.now()/60000);
    const received = Number(cache.get(bucket) || 0);
    if (received >= 60) return jsonReply({ok:false,error:'rate_limited'});
    const fields = [payload.category,payload.summary,payload.details,payload.replyEmail,payload.appVersion,payload.buildNumber,payload.osVersion,payload.displayLanguage].map(safeCell);
    sheet.appendRow([payload.submissionID,hash,new Date().toISOString(),...fields]);
    SpreadsheetApp.flush(); // Confirm persistence before acknowledging success.
    cache.put(bucket,String(received+1),120);
    return jsonReply({ok:true,submissionID:payload.submissionID});
  } catch (_) {
    // Do not leak stack traces, spreadsheet IDs or submitted personal text.
    return jsonReply({ok:false,error:'rejected_or_unavailable'});
  } finally { if (lock && lock.hasLock()) lock.releaseLock(); }
}
if (typeof module !== 'undefined') module.exports = {validatePayload,safeCell,canonicalPayload,doPost};
