import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {runtimeCall} from './runtime.mjs';

const execute = promisify(execFile);
const appPath = '/Applications/Grok Bot.app';
const profile = path.join(os.homedir(), 'Library/Application Support/Grok Bot');
const directory = path.join(os.homedir(), 'Library/Application Support/Grok Notch Bridge');
await fs.mkdir(directory, {recursive: true, mode: 0o700});
const lockFile = path.join(directory, 'bridge.pid');
try {
  const old = Number(await fs.readFile(lockFile, 'utf8'));
  if (Number.isSafeInteger(old) && old > 1) {
    try { process.kill(old, 0); console.error('Bridge already running.'); process.exit(0); } catch {}
  }
} catch {}
await fs.writeFile(lockFile, String(process.pid), {mode: 0o600});
const token = crypto.randomBytes(32).toString('hex');
let socket, socketURL, pending = new Map(), requestNumber = 0;
let connecting = null;
function closeSocket() {
  try { socket?.close(); } catch {}
  socket = undefined; socketURL = undefined;
  for (const job of pending.values()) { clearTimeout(job.timer); job.reject(new Error('Connexion à Grok Bot interrompue.')); }
  pending.clear();
}
async function connectCDP() {
  if (socket?.readyState === WebSocket.OPEN) return socket;
  if (connecting) return connecting;
  connecting = (async () => {
    let port;
    try { port = Number((await fs.readFile(path.join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0]); } catch {}
    if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Ouvrez la connexion à Grok Bot depuis les réglages du Droplet.');
    let targets;
    try { targets = await (await fetch(`http://127.0.0.1:${port}/json/list`, {signal: AbortSignal.timeout(2500)})).json(); }
    catch { throw new Error('Grok Bot est fermé ou son bridge doit être reconnecté.'); }
    const target = targets.find(t => t.type === 'page' && t.url.startsWith('file:') && decodeURIComponent(t.url).includes('/Grok Bot.app/Contents/Resources/app.asar/dist/renderer/index.html'));
    if (!target) throw new Error('La fenêtre principale de Grok Bot n’est pas disponible.');
    const url = new URL(target.webSocketDebuggerUrl);
    if (url.hostname !== '127.0.0.1' || Number(url.port) !== port) throw new Error('Adresse de diagnostic non locale refusée.');
    const ws = new WebSocket(url);
    await new Promise((resolve,reject) => {
      const timer = setTimeout(() => { ws.close(); reject(new Error('Connexion Grok Bot expirée.')); }, 4000);
      ws.addEventListener('open', () => { clearTimeout(timer); resolve(); }, {once: true});
      ws.addEventListener('error', () => { clearTimeout(timer); reject(new Error('Connexion Grok Bot impossible.')); }, {once: true});
    });
    ws.addEventListener('message', event => {
      let frame; try { frame = JSON.parse(event.data); } catch { return; }
      const job = pending.get(frame.id); if (!job) return;
      pending.delete(frame.id); clearTimeout(job.timer);
      const result = frame.result;
      if (frame.error || result?.exceptionDetails) {
        const reason = result?.exceptionDetails?.exception?.description?.split('\n')[0] || 'Échec de l’appel Grok Bot.';
        job.reject(new Error(reason.replace(/^Error: /, '')));
      } else job.resolve(result?.result?.value);
    });
    ws.addEventListener('close', () => { if (socket === ws) closeSocket(); });
    ws.addEventListener('error', () => { if (socket === ws) closeSocket(); });
    socket = ws; socketURL = url.href; return ws;
  })().finally(() => { connecting = null; });
  return connecting;
}
async function call(op, args) {
  const ws = await connectCDP();
  const id = ++requestNumber;
  const expression = `(${runtimeCall.toString()})(${JSON.stringify(op)},${JSON.stringify(args)})`;
  return new Promise((resolve,reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('Grok Bot met trop de temps à répondre.')); }, 20000);
    pending.set(id, {resolve,reject,timer});
    ws.send(JSON.stringify({id, method: 'Runtime.evaluate', params: {expression, returnByValue: true, awaitPromise: true}}));
  });
}
async function reconnect() {
  try { await call('state', {}); return {connected: true}; } catch {}
  closeSocket();
  const executable = `${appPath}/Contents/MacOS/Grok Bot`;
  const {stdout} = await execute('/bin/ps', ['-axo', 'pid=,args=']);
  const pids = stdout.split('\n').map(line => line.trim().match(/^(\d+)\s+(.+)$/))
    .filter(match => match && (match[2] === executable || match[2].startsWith(executable+' --remote-debugging-'))).map(match => Number(match[1]));
  for (const pid of pids) { try { process.kill(pid, 'SIGTERM'); } catch {} }
  for (let attempt=0; attempt<40 && pids.some(pid => { try { process.kill(pid,0); return true; } catch { return false; } }); attempt++) await new Promise(r=>setTimeout(r,200));
  await execute('/usr/bin/open', ['-a', appPath, '--args', '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0']);
  for (let attempt=0; attempt<35; attempt++) {
    try { await call('state', {}); return {connected:true}; } catch { await new Promise(r=>setTimeout(r,400)); }
  }
  throw new Error('Grok Bot doit être ouvert et connecté à votre compte.');
}
function authorized(req) {
  const auth = req.headers.authorization || '';
  const expected = `Bearer ${token}`;
  const received = Buffer.from(auth);
  return received.length === Buffer.byteLength(expected) && crypto.timingSafeEqual(received, Buffer.from(expected));
}
function respond(res, status, body) {
  res.writeHead(status, {'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});
  res.end(JSON.stringify(body));
}
async function jsonBody(req) {
  let bytes=0, chunks=[];
  for await (const chunk of req) { bytes+=chunk.length; if(bytes>64000) throw new Error('Requête trop longue.'); chunks.push(chunk); }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}
const submissions = new Map();
let lastUse = Date.now();
setInterval(() => { if (socket?.readyState === WebSocket.OPEN && Date.now()-lastUse>20000) { lastUse=Date.now(); call('release',{}).finally(closeSocket).catch(()=>{}); } },10000).unref();
const server = http.createServer(async (req,res) => {
  if (!authorized(req) || req.headers.origin) return respond(res,403,{error:'Accès refusé.'});
  try {
    lastUse = Date.now();
    const url = new URL(req.url,'http://127.0.0.1');
    if (req.method==='GET' && url.pathname==='/v1/state') {
      const args={};
      if(url.searchParams.has('botId')) args.botId=url.searchParams.get('botId');
      if(url.searchParams.has('sessionId')) args.sessionId=url.searchParams.get('sessionId');
      if(args.botId && !/^[a-zA-Z0-9_-]{1,100}$/.test(args.botId)) return respond(res,400,{error:'Bot invalide.'});
      return respond(res,200,await call('state',args));
    }
    if(req.method==='POST' && url.pathname==='/v1/connect') return respond(res,200,await reconnect());
    if(req.method==='POST' && url.pathname==='/v1/older') {
      const b=await jsonBody(req);
      if(typeof b.botId!=='string'||typeof b.sessionId!=='string') return respond(res,400,{error:'Conversation invalide.'});
      return respond(res,200,await call('older',b));
    }
    if(req.method==='POST' && url.pathname==='/v1/send') {
      const b=await jsonBody(req);
      if(typeof b.botId!=='string'||typeof b.text!=='string'||!b.text.trim()||b.text.length>8000||typeof b.requestId!=='string'||!/^[a-zA-Z0-9-]{16,100}$/.test(b.requestId)|| (b.sessionId!==undefined&&typeof b.sessionId!=='string')) return respond(res,400,{error:'Message ou identifiant invalide.'});
      const old=submissions.get(b.requestId);
      if(old && (old.botId!==b.botId || old.textHash!==crypto.createHash('sha256').update(b.text).digest('hex'))) return respond(res,409,{error:'Identifiant d’envoi déjà utilisé.'});
      if(!old) {
        if(submissions.size>2000) submissions.delete(submissions.keys().next().value);
        const promise=call('send',{botId:b.botId,sessionId:b.sessionId,text:b.text});
        submissions.set(b.requestId,{botId:b.botId,textHash:crypto.createHash('sha256').update(b.text).digest('hex'),promise});
      }
      return respond(res,200,await submissions.get(b.requestId).promise);
    }
    respond(res,404,{error:'Commande inconnue.'});
  } catch(error) { respond(res,503,{error:error.message || 'Bridge indisponible.'}); }
});
server.requestTimeout=25000; server.headersTimeout=10000;
server.listen(0,'127.0.0.1',async()=>{
  const config=path.join(directory,'connection.json');
  await fs.writeFile(config+'.tmp',JSON.stringify({port:server.address().port,token}),{mode:0o600});
  await fs.rename(config+'.tmp',config); await fs.chmod(config,0o600);
  console.log('Grok Notch bridge ready (loopback only; credentials are never logged).');
});
async function shutdown() {
  try { await call('release',{}); } catch {}
  closeSocket();server.close();
  await fs.unlink(lockFile).catch(()=>{});process.exit(0);
}
process.on('SIGTERM',()=>void shutdown());process.on('SIGINT',()=>void shutdown());
