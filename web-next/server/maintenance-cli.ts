// SPDX-License-Identifier: AGPL-3.0-or-later
// メンテナンスの頁を作る、箱の上の道具。`scripts/sukhi-maintenance` が、コンテナの中で呼ぶ。
//
//   node server/maintenance-cli.ts snapshot
//       gateway の公開タイムライン(ご近所ではなく、このサーバーの人たち)から、頁に載せる分を選んで、
//       JSON を標準出力へ。取れなかったら `{"items":[]}` を出して、終了コード 3(頁は、一覧なしで作れる)。
//   node server/maintenance-cli.ts render --lang ja|ko|en [--why update|backup|migration|repair] [--about 分] < snapshot.json
//       一言語ぶんの HTML を標準出力へ。標準入力は snapshot の出力(空でもよい)。
//
// ファイルは書かない(コンテナに置き場を渡さなくてよい)。書くのは箱の側の `scripts/sukhi-maintenance`。
// 取りに行くのは **認証なしの公開の読み** だけ ── 閲覧者のトークンも、セッションも触らない。

import { parseArgs } from 'node:util';
import { config } from './config.ts';
import { isLocale } from './i18n.ts';
import { asItems, isWhy, pickItems, renderMaintenancePage, MAX_ITEMS } from './maintenance.ts';

const FETCH_MS = 8000;

async function snapshot(): Promise<number> {
  const url = `${config.gateway}/api/v1/timelines/public?local=1&limit=${MAX_ITEMS + 10}`;
  try {
    const res = await fetch(url, {
      headers: { accept: 'application/json', 'user-agent': 'sukhi-maintenance' },
      signal: AbortSignal.timeout(FETCH_MS)
    });
    if (!res.ok) throw new Error(`gateway answered ${res.status}`);
    process.stdout.write(JSON.stringify({ items: pickItems(await res.json()) }) + '\n');
    return 0;
  } catch (e) {
    process.stderr.write(`snapshot: ${e instanceof Error ? e.message : String(e)}\n`);
    process.stdout.write('{"items":[]}\n');
    return 3;
  }
}

async function readStdin(): Promise<string> {
  if (process.stdin.isTTY) return '';
  let s = '';
  for await (const chunk of process.stdin) s += chunk;
  return s;
}

async function render(argv: string[]): Promise<number> {
  const { values } = parseArgs({ args: argv, options: { lang: { type: 'string' }, why: { type: 'string' }, about: { type: 'string' } } });
  if (!isLocale(values.lang)) {
    process.stderr.write('render: --lang must be ja, ko or en\n');
    return 2;
  }
  if (values.why !== undefined && !isWhy(values.why)) {
    process.stderr.write('render: --why must be update, backup, migration or repair\n');
    return 2;
  }
  const aboutMin = values.about === undefined ? undefined : Number(values.about);
  if (aboutMin !== undefined && !Number.isFinite(aboutMin)) {
    process.stderr.write('render: --about must be a number of minutes\n');
    return 2;
  }

  let items: ReturnType<typeof asItems> = [];
  try {
    const raw = (await readStdin()).trim();
    if (raw) items = asItems(JSON.parse(raw));
  } catch {
    // 読めなければ一覧なし。頁そのものは出す(止めている最中に、頁が作れないのがいちばん困る)。
    process.stderr.write('render: snapshot unreadable, rendering without the list\n');
  }

  process.stdout.write(
    renderMaintenancePage({
      locale: values.lang,
      siteName: config.siteName,
      aboutUrl: config.aboutUrl,
      why: values.why as Parameters<typeof renderMaintenancePage>[0]['why'],
      aboutMin,
      items
    })
  );
  return 0;
}

const [cmd, ...rest] = process.argv.slice(2);
if (cmd === 'snapshot') process.exitCode = await snapshot();
else if (cmd === 'render') process.exitCode = await render(rest);
else {
  process.stderr.write('usage: maintenance-cli.ts snapshot | render --lang ja|ko|en [--why …] [--about 分]\n');
  process.exitCode = 2;
}
