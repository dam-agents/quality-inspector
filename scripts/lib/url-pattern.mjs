// url-pattern.mjs — one pattern per page or API shape: ids, numbers and hashes in a path
// collapse to :id. Shared by ui-inventory.mjs (the map) and security-checks.mjs (its replay).

export const ID = /^(?:[0-9]+|[0-9a-f]{8,}|[0-9a-f-]{32,36}|[a-z]+-[0-9a-f]{12,}|[A-Za-z0-9_-]{20,})$/;
export const pattern = (u) => u.pathname.split('/').map((s) => (ID.test(s) ? ':id' : s)).join('/') || '/';
// Static files a page fetches are not API requests.
export const STATIC = /\.(js|mjs|css|map|json|svg|png|jpe?g|gif|webp|ico|woff2?|ttf|txt|html?)$/i;
// A path with its query, minus any parameter that could carry a secret (signed URLs, tokens).
export const examplePath = (u) => {
  const q = new URLSearchParams(u.search);
  for (const k of [...q.keys()]) if (/token|key|secret|sig|password|auth|session|code/i.test(k)) q.delete(k);
  const s = q.toString();
  return u.pathname + (s ? `?${s}` : '');
};
