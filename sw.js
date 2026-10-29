const CACHE='sempanela-v15';
const CORE=['/','/index.html','/manifest.webmanifest','/config.js','/vendor/supabase.js','/icons/icon-192.png','/icons/icon-512.png','/icons/apple-touch-icon.png'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(CACHE).then(c=>c.addAll(CORE)).then(()=>self.skipWaiting()));});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim()));});
self.addEventListener('fetch',e=>{
  const r=e.request; if(r.method!=='GET')return;
  const u=new URL(r.url);
  if(u.origin!==location.origin){
    if(u.host.endsWith('fonts.googleapis.com')||u.host.endsWith('fonts.gstatic.com'))
      e.respondWith(caches.match(r).then(m=>m||fetch(r).then(res=>{const c=res.clone();caches.open(CACHE).then(k=>k.put(r,c));return res;})));
    return; // Supabase e outros: sempre direto pela rede
  }
  // páginas do app (inclusive /convite/SP0001) usam o index; rede primeiro, cache se estiver offline
  const req=r.mode==='navigate'&&!u.pathname.startsWith('/download')?new Request('/index.html'):r;
  e.respondWith(fetch(r).then(res=>{if(res.ok){const c=res.clone();caches.open(CACHE).then(k=>k.put(req,c));}return res;}).catch(()=>caches.match(req).then(m=>m||caches.match('/index.html'))));
});
