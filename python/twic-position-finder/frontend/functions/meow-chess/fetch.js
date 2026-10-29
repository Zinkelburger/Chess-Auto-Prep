// /meow-chess/fetch?url=… — fetches a page for Meow-Chess (/meow-chess/, the
// tournament director app), which cannot read US Chess, FIDE or club websites
// from the browser itself: they send no CORS headers. Cloudflare Pages runs
// this file as a Pages Function because it sits under functions/.
//
// Only HTTPS, only these hosts. Redirects are returned without their
// Location rather than followed, so an API key is never sent on to another
// host and the browser does not chase them either; the desktop app treats a
// redirect the same way.
const ALLOWED_HOSTS = new Set([
  'boylstonchess.org',
  'beta.boylstonchess.org',
  'ratings-api.uschess.org',
  'ratings.fide.com',
]);
const FORWARDED_HEADERS = ['accept', 'content-type', 'x-api-key'];

const refuse = (status, message) =>
  new Response(message, { status, headers: { 'content-type': 'text/plain; charset=utf-8' } });

export async function onRequest({ request }) {
  if (!['GET', 'HEAD', 'POST'].includes(request.method)) return refuse(405, 'Method not allowed');
  let target;
  try {
    target = new URL(new URL(request.url).searchParams.get('url') ?? '');
  } catch {
    return refuse(400, 'Pass the page as ?url=');
  }
  if (target.protocol !== 'https:' || target.username || target.password || !ALLOWED_HOSTS.has(target.hostname)) {
    return refuse(403, `Meow-Chess does not fetch from ${target.hostname || 'that address'}.`);
  }
  const headers = new Headers({ 'user-agent': 'Meow-Chess (https://chessautoprep.com/meow-chess/)' });
  for (const name of FORWARDED_HEADERS) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }
  let upstream;
  try {
    upstream = await fetch(target, {
      method: request.method,
      headers,
      body: request.method === 'POST' ? request.body : undefined,
      redirect: 'manual',
    });
  } catch {
    return refuse(502, `Could not reach ${target.hostname}.`);
  }
  const out = new Headers({ 'cache-control': 'no-store' });
  const type = upstream.headers.get('content-type');
  if (type) out.set('content-type', type);
  return new Response(upstream.body, { status: upstream.status, headers: out });
}
