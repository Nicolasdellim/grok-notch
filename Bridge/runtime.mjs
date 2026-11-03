// Fixed, allowlisted calls executed inside the user's existing Grok Bot renderer.
export async function runtimeCall(op, args = {}) {
  function client() {
    const cached = globalThis.__grokNotchClient;
    if (cached?.boot?.get()?.status === 'ready') return cached;
    const root = [...document.querySelectorAll('*')].slice(0, 800)
      .find(e => Object.getOwnPropertyNames(e).some(k => k.startsWith('__reactFiber$')));
    if (!root) throw new Error('Grok Bot charge encore son interface.');
    const key = Object.getOwnPropertyNames(root).find(k => k.startsWith('__reactFiber$'));
    const stack = [root[key]], seen = new Set();
    while (stack.length && seen.size < 50000) {
      const fiber = stack.pop();
      if (!fiber || seen.has(fiber)) continue;
      seen.add(fiber);
      for (const value of [fiber.memoizedProps?.value, fiber.memoizedProps?.client, fiber.memoizedProps?.value?.client]) {
        if (value && typeof value === 'object' && value.roster && value.transcript && value.sendJournal) {
          globalThis.__grokNotchClient = value;
          return value;
        }
      }
      stack.push(fiber.return, fiber.child, fiber.sibling);
    }
    throw new Error('Interface Grok Bot incompatible avec cette version du bridge.');
  }
  const c = client();
  if (c.boot.get().status !== 'ready') throw new Error('Connectez votre compte dans Grok Bot.');
  if (op === 'release') {
    for (const reader of globalThis.__grokNotchReaders?.values() ?? []) { reader.release(); reader.sessionsRelease(); }
    globalThis.__grokNotchReaders = new Map();
    return {released: true};
  }
  const roster = c.roster.snapshots.get();
  const rows = roster.agents.rows.filter(a => !a.isRemovedFromSidebar);
  const selected = c.selection.snapshots.get();
  let botID = args.botId || selected.currentAgentId || rows[0]?.id;
  if (op !== 'send' && !rows.some(a => a.id === botID)) botID = selected.currentAgentId || rows[0]?.id;
  const agent = rows.find(a => a.id === botID);
  if (!agent) throw new Error('Ce bot n’est pas disponible dans le compte actif.');
  const baseSession = agent.viewerIsOwner === false ? agent.viewerSessionId ?? '' : '';
  const sessionID = args.sessionId === undefined
    ? (selected.currentAgentId === botID ? selected.currentSessionId ?? baseSession : baseSession)
    : (agent.viewerIsOwner === false && args.sessionId === '' ? baseSession : args.sessionId);
  if (!globalThis.__grokNotchReaders) globalThis.__grokNotchReaders = new Map();
  const key = `${botID}:${sessionID}`;
  const readers = globalThis.__grokNotchReaders;
  if (!readers.has(key)) {
    // Keep at most four retained transcripts; release old readers when switching bots.
    if (readers.size >= 4) {
      const [oldKey, old] = readers.entries().next().value;
      old.release(); old.sessionsRelease(); readers.delete(oldKey);
    }
    readers.set(key, {
      release: c.transcript.retain(botID, {sessionId: sessionID}),
      sessionsRelease: c.grokBotSessions.watch(botID),
      loadedAt: 0
    });
  }
  const reader = readers.get(key);
  if (op === 'send') {
    let nonce = '';
    await c.sendJournal.sendPrompt({
      agentId: botID, sessionId: sessionID, prompt: args.text, attachments: [],
      onNonceAssigned: value => { nonce = value.nonce; },
      onJournaled: value => { nonce = value.nonce; }
    });
    return {accepted: true, nonce};
  }
  if (op === 'older') {
    await c.transcript.loadOlder(botID, {sessionId: sessionID});
  } else if (Date.now() - reader.loadedAt > 4000) {
    await c.transcript.load(botID, {sessionId: sessionID, background: true});
    reader.loadedAt = Date.now();
  }
  const transcript = c.transcript.snapshotsFor(botID, {sessionId: sessionID}).get();
  if (transcript.loadState === 'failed' && transcript.entries.length === 0) {
    throw new Error('Grok Bot n’a pas pu charger cette conversation.');
  }
  const sessionsState = c.grokBotSessions.snapshotsFor(botID).get();
  const remoteSessions = sessionsState.value ?? sessionsState.previous ?? [];
  const sessions = [{id: baseSession, botID, title: 'Conversation principale'}];
  for (const item of Array.isArray(remoteSessions) ? remoteSessions : []) {
    const id = item.sessionId ?? item.id;
    if (typeof id !== 'string' || sessions.some(s => s.id === id)) continue;
    sessions.push({id, botID, title: item.title || item.name || item.label || 'Conversation'});
  }
  if (!sessions.some(s => s.id === sessionID)) sessions.push({id: sessionID, botID, title: 'Conversation ouverte'});
  const messages = [];
  for (const entry of transcript.entries) {
    if (entry.kind === 'message' && ['user','assistant'].includes(entry.role) && typeof entry.content === 'string' && entry.content.length) {
      messages.push({id: entry.id, isUser: entry.role === 'user', text: entry.content, isStreaming: !!entry.isStreaming});
    } else if (entry.kind === 'send-message' && entry.message?.type === 'text' && typeof entry.message.content === 'string') {
      messages.push({id: entry.id, isUser: false, text: entry.message.content, isStreaming: !!entry.streaming});
    } else if (entry.kind === 'send-message' && entry.message?.type === 'attachment') {
      messages.push({id: entry.id, isUser: false, text: '[Pièce jointe — ouvrir dans Grok Bot]', isStreaming: false});
    }
  }
  // Reuse Grok Bot's own avatar generator, including its ID-derived defaults.
  // The module is already loaded by this page; importing that exact preload URL
  // returns its existing exports without reading arbitrary files on the server.
  async function avatarModule() {
    const url = [...document.querySelectorAll('link[rel="modulepreload"]')]
      .map(node => node.href).find(value => /\/index\.eager-app-[^/]+\.js$/.test(value));
    if (!url) throw new Error('Avatar module unavailable');
    if (globalThis.__grokNotchAvatarModule?.url === url) return globalThis.__grokNotchAvatarModule.promise;
    const promise = import(url).then(module => {
      // These are the observed exports in Grok Bot 0.78.1. Validate their source
      // before using them so a future minifier reassignment cannot draw a fake mark.
      if (typeof module.jb !== 'function' || typeof module.B_ !== 'function' || typeof module.z_ !== 'function'
          || !String(module.B_).includes('avatarShape') || !String(module.z_).includes('avatarColor')) {
        throw new Error('Avatar module incompatible');
      }
      return {make: module.jb, shape: module.B_, color: module.z_};
    });
    globalThis.__grokNotchAvatarModule = {url, promise};
    return promise;
  }
  const avatarSurface = getComputedStyle(document.querySelector('aside') ?? document.body).backgroundColor;
  async function avatarPNG(a) {
    const cache = globalThis.__grokNotchAvatarPNGs ??= new Map();
    const signature = JSON.stringify(['notch-avatar-v3', avatarSurface, a.id, a.avatarVersion, a.avatarShape, a.avatarColor,
      a.avatarDataUrl, matchMedia('(prefers-color-scheme: dark)').matches]);
    const prior = cache.get(a.id);
    if (prior?.signature === signature) {
      if (prior.data) return prior.data;
      if (prior.pending) return prior.pending;
      if (Date.now() - prior.failedAt < 5000) return undefined;
    }
    const item = {signature, data: undefined, pending: null, failedAt: 0};
    cache.set(a.id, item);
    while (cache.size > 64) cache.delete(cache.keys().next().value);
    item.pending = (async () => {
      try {
        let source = typeof a.avatarDataUrl === 'string' ? a.avatarDataUrl : '';
        if (source) {
          // Only the application's own supplied local/photo URI is accepted.
          const protocol = new URL(source).protocol;
          if (!['data:', 'file:', 'sand-avatar:'].includes(protocol)) throw new Error('Unsupported avatar source');
          if (protocol === 'data:' && !/^data:image\//i.test(source)) throw new Error('Invalid avatar media');
        } else {
          const module = await avatarModule();
          source = module.make(a.id, {shape: module.shape(a), color: module.color(a)});
          if (typeof source !== 'string' || !source.startsWith('data:image/svg+xml')) throw new Error('Invalid generated avatar');
          // Grok's eye cut-outs reveal its sidebar underneath. Composite that
          // same surface INSIDE the original body so the eyes retain their app
          // appearance on Droppy's black, leaving the outer contour transparent.
          const comma = source.indexOf(',');
          const xml = source.slice(0, comma).includes(';base64')
            ? atob(source.slice(comma+1)) : decodeURIComponent(source.slice(comma+1));
          const documentSVG = new DOMParser().parseFromString(xml, 'image/svg+xml');
          for (const use of [...documentSVG.querySelectorAll('use[mask]')]) {
            const backing = use.cloneNode(true);
            backing.removeAttribute('mask'); backing.setAttribute('fill', avatarSurface);
            backing.style.setProperty('fill', avatarSurface);
            use.parentNode.insertBefore(backing, use);
          }
          source = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(new XMLSerializer().serializeToString(documentSVG));

        }
        const image = new Image();
        image.decoding = 'async';
        image.src = source;
        let timer;
        try {
          await Promise.race([image.decode(), new Promise((_, reject) => {
            timer = setTimeout(() => reject(new Error('Avatar decode timeout')), 4000);
          })]);
        } finally { clearTimeout(timer); }
        if (!image.naturalWidth || !image.naturalHeight) throw new Error('Empty avatar');
        const canvas = document.createElement('canvas');
        canvas.width = canvas.height = 96;
        const context = canvas.getContext('2d');
        if (!context) throw new Error('Avatar canvas unavailable');
        // Match the app's square avatar crop without stretching custom photos.
        const side = Math.min(image.naturalWidth, image.naturalHeight);
        context.drawImage(image, (image.naturalWidth - side) / 2, (image.naturalHeight - side) / 2,
          side, side, 0, 0, 96, 96);
        // Monochrome black marks need a light variant on the notch. Invert
        // only RGB, preserving the original silhouette, eyes and alpha. Photos
        // and all coloured bot identities remain untouched.
        const palette = await avatarModule().catch(() => null);
        if (!a.avatarDataUrl && palette && ['black', 'gray'].includes(palette.color(a))) {
          const pixels = context.getImageData(0, 0, 96, 96);
          for (let i = 0; i < pixels.data.length; i += 4) {
            pixels.data[i] = 255 - pixels.data[i];
            pixels.data[i+1] = 255 - pixels.data[i+1];
            pixels.data[i+2] = 255 - pixels.data[i+2];
          }
          context.putImageData(pixels, 0, 0);
        }
        const data = canvas.toDataURL('image/png');
        if (!data.startsWith('data:image/png;base64,') || data.length > 100000) throw new Error('Avatar output too large');
        item.data = data;
        return data;
      } catch {
        item.failedAt = Date.now();
        return undefined;
      } finally { item.pending = null; }
    })();
    return item.pending;
  }
  function messageMetadata(a) {
    const lastMessageID = typeof a.lastMessageId === 'string' && a.lastMessageId
      ? a.lastMessageId : typeof a.newestEntryId === 'string' ? a.newestEntryId : '';
    let lastMessageIsUser = a.lastEntry?.role === 'user' ? true : a.lastEntry?.role === 'assistant' ? false : undefined;
    let lastMessageIsStreaming;
    // Roster previews do not carry reliable authorship. Only an exact entry-ID
    // match in a transcript already retained by this bridge can establish it.
    if (lastMessageID) {
      for (const retainedKey of readers.keys()) {
        if (!retainedKey.startsWith(`${a.id}:`)) continue;
        const retainedSession = retainedKey.slice(a.id.length + 1);
        const cached = c.transcript.snapshotsFor(a.id, {sessionId: retainedSession}).get();
        const entry = cached.entries?.find(value => value.id === lastMessageID);
        if (entry?.kind === 'message' && ['user', 'assistant'].includes(entry.role)) {
          lastMessageIsUser = entry.role === 'user';
          lastMessageIsStreaming = !!entry.isStreaming;
          break;
        }
        if (entry?.kind === 'send-message') {
          lastMessageIsUser = false;
          lastMessageIsStreaming = !!entry.streaming;
          break;
        }
      }
    }
    return {
      preview: typeof a.lastMessagePreview === 'string' ? a.lastMessagePreview : '',
      lastMessageID,
      lastActivityAt: typeof a.lastActivityAt === 'number' && Number.isFinite(a.lastActivityAt) ? a.lastActivityAt : 0,
      hasUnread: a.hasUnread === true,
      unreadCount: typeof a.unreadCount === 'number' && Number.isFinite(a.unreadCount) ? Math.max(0, Math.floor(a.unreadCount)) : 0,
      lastMessageIsUser, lastMessageIsStreaming
    };
  }
  const avatarResults = await Promise.all(rows.map(avatarPNG));
  const avatarStyles = await avatarModule().catch(() => null);
  return {
    connected: true,
    bots: rows.map((a, index) => ({
      id: a.id, name: a.name || 'Bot', role: a.description || '',
      symbol: a.isGroup ? 'person.2' : 'sparkle',
      isRunning: !!(a.isRunningTurn || a.isComposingMessage || a.isRunning),
      awaitingApproval: !!a.awaitingUserResponse,
      ...messageMetadata(a),
      avatarNeedsContrast: !a.avatarDataUrl && avatarStyles ? ['black', 'gray'].includes(avatarStyles.color(a)) : false,
      ...(avatarResults[index] ? {avatarDataURL: avatarResults[index]} : {})
    })),
    selectedBotId: botID, selectedSessionId: sessionID,
    messages, sessions, hasOlder: !!transcript.hasOlder
  };
}
