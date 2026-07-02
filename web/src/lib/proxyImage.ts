// gateway の remote media proxy (/proxy/{media,avatar,header}/:id) は、
// URL の拡張子 .avif / .webp を「この形式に変換して」の合図として読む
// (それ以外の拡張子は今までどおり CF cache に乗せるための飾り)。
// ここでは自分の origin の proxy URL だけを書き換えて、<picture> の
// avif → webp → 原本という三段に使う。gif / svg は触らない ─
// アニメーションやテキストのまま届くほうが良いものを、壊さないため
// (サーバ側 MediaTranscode にも同じ弁があるので、これは省エネの層)。

const PROXY_PATH = /^\/proxy\/(?:media|avatar|header)\/\d+(?:\.([a-z0-9]{2,5}))?$/;

export function proxyVariants(
  src: string | null | undefined
): { avif: string; webp: string } | null {
  if (!src) return null;
  let url: URL;
  try {
    url = new URL(src, location.origin);
  } catch {
    return null;
  }
  if (url.host !== location.host) return null;
  const m = url.pathname.match(PROXY_PATH);
  if (!m || m[1] === 'gif' || m[1] === 'svg') return null;

  const stem = url.pathname.replace(/\.[a-z0-9]{2,5}$/, '');
  const withExt = (ext: string) => {
    const u = new URL(url);
    u.pathname = `${stem}.${ext}`;
    return u.toString();
  };
  return { avif: withExt('avif'), webp: withExt('webp') };
}
