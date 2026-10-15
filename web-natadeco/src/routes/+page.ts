import { browser } from '$app/env';
import { listDecos } from '#lib/api.js';
import type { PageLoad } from './$types';

// 板の一覧。サーバでは匿名で取る(印は付かない)ので、入っている人は
// ブラウザ側で自分の分を取り直す ── `anonymous` がその合図。
export const load: PageLoad = async () => {
  try {
    return { decos: await listDecos(), anonymous: !browser };
  } catch {
    return { decos: null, anonymous: !browser };
  }
};
