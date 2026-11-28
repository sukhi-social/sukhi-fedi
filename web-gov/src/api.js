// SPDX-License-Identifier: AGPL-3.0-or-later
// gateway の口(/api/v1/join/info と /api/admin/join_applications*)への、ちいさな道具。
// トークンは、このタブの sessionStorage にだけ置く(閉じれば消える。localStorage には置かない)。

const KEY = 'gov.token';
const base = () => (import.meta.env?.VITE_API_BASE ?? '').replace(/\/$/, '');

export const token = {
  get() {
    try {
      return sessionStorage.getItem(KEY) ?? '';
    } catch {
      return '';
    }
  },
  set(v) {
    try {
      v ? sessionStorage.setItem(KEY, v) : sessionStorage.removeItem(KEY);
    } catch {
      // しまえなくても、この画面のあいだは使える。
    }
  }
};

// 失敗は ApiError に。status と、gateway の error ことばを持つ。
export class ApiError extends Error {
  constructor(status, code) {
    super(code);
    this.status = status;
    this.code = code;
  }
}

async function call(method, path, { body, auth } = {}) {
  const headers = {};
  if (body !== undefined) headers['content-type'] = 'application/json';
  if (auth) headers.authorization = `Bearer ${auth}`;
  let res;
  try {
    res = await fetch(base() + path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  } catch {
    throw new ApiError(0, 'network');
  }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new ApiError(res.status, data.error ?? `http_${res.status}`);
  return data;
}

// だれでも読める窓口: だれが見ていて、つぎはいつか。取れなければ null(頁は開く)。
export async function info() {
  try {
    return await call('GET', '/api/v1/join/info');
  } catch {
    return null;
  }
}

const admin = (method, path, body) => call(method, `/api/admin/join_applications${path}`, { body, auth: token.get() });
const id = (receipt) => encodeURIComponent(receipt);

export const applications = {
  list: () => admin('GET', ''),
  show: (receipt) => admin('GET', `/${id(receipt)}`),
  welcome: (receipt, note) => admin('POST', `/${id(receipt)}/welcome`, { note }),
  decline: (receipt, reason) => admin('POST', `/${id(receipt)}/decline`, { reason })
};

// 他のサーバーからの「配送のお休み」(FEP-f799)。id は URL なので、パスではなく本文で渡す。
const resting = (method, path, body) => call(method, `/api/admin/delivery_suspensions${path}`, { body, auth: token.get() });

export const suspensions = {
  list: () => resting('GET', ''),
  ignore: (noticeId) => resting('POST', '/ignore', { id: noticeId }),
  unignore: (noticeId) => resting('POST', '/unignore', { id: noticeId })
};

// 失敗を、そっと言える一文に。
export function sayError(e) {
  if (!(e instanceof ApiError)) return 'うまくいきませんでした。';
  switch (e.code) {
    case 'network':
      return 'つながりませんでした。すこし待って、もう一度。';
    case 'join_not_found':
      return 'この申し込みは、もうありません(迎えたか、見送ったか、消えたかです)。';
    case 'send_failed':
      return 'メールが出ませんでした。申し込みはそのままです。もう一度ためせます。';
    case 'validation_failed':
      return '長すぎるようです。500 字までに、してください。';
    case 'suspension_not_found':
      return 'このお休みは、もう記録にありません(期限が過ぎて、忘れられたようです)。';
    case 'admin_required':
      return 'このトークンの人は、管理する人ではありません。';
    case 'insufficient_scope':
      return 'このトークンには、この操作の力がありません(admin:read と admin:write が要ります)。';
    case 'rate_limited':
      return 'すこし多いようです。待ってから、もう一度。';
  }
  if (e.status === 401) return 'トークンが、合いませんでした。';
  if (e.status === 503) return 'いま、gateway につながっていません。';
  return 'うまくいきませんでした。';
}
