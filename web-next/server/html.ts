// HTML をつくる、いちばん小さな道具。
//
//   html`<p>${name}</p>`     差し込んだ値は、かならずエスケープされる
//   raw(s)                   すでに安全だと分かっている HTML(サーバが sanitize 済みの本文、
//                            renderEmojis / renderMfm の返り値)だけを、そのまま通す
//
// エスケープをし忘れる道を、そもそも作らない。「そのまま出す」と書いた場所だけが、危ない場所。

export class SafeHtml {
  readonly value: string;
  constructor(value: string) {
    this.value = value;
  }
  toString(): string {
    return this.value;
  }
}

export function raw(s: string): SafeHtml {
  return new SafeHtml(s);
}

export function esc(s: unknown): string {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function render(v: unknown): string {
  if (v === null || v === undefined || v === false || v === true) return '';
  if (v instanceof SafeHtml) return v.value;
  if (Array.isArray(v)) return v.map(render).join('');
  return esc(v);
}

export function html(strings: TemplateStringsArray, ...values: unknown[]): SafeHtml {
  let out = strings[0];
  for (let i = 0; i < values.length; i++) out += render(values[i]) + strings[i + 1];
  return new SafeHtml(out);
}
