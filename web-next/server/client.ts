// SPDX-License-Identifier: AGPL-3.0-or-later
// OAuth の「アプリ登録」。ブラウザごとにではなく、この郵便局が一度だけ登録して、覚えておく。
// scope か戻り先が変わったときだけ、登録しなおす。

import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { config } from './config.ts';

export type ClientCreds = {
  client_id: string;
  client_secret: string;
  redirect_uri: string;
  scopes: string;
};

const file = `${config.dataDir}client.json`;
const redirect_uri = `${config.publicOrigin}/app/callback`;

// scope を、順番や空白の違いに寛容に比べる。
const norm = (s: string) => s.trim().split(/\s+/).filter(Boolean).sort().join(' ');

let cached: Promise<ClientCreds> | null = null;

export function getClient(): Promise<ClientCreds> {
  cached ??= load().catch((e) => {
    cached = null; // 失敗は覚えない。次にまた登録しにいく。
    throw e;
  });
  return cached;
}

async function load(): Promise<ClientCreds> {
  try {
    const c = JSON.parse(await readFile(file, 'utf8')) as ClientCreds;
    if (c.redirect_uri === redirect_uri && norm(c.scopes) === norm(config.scopes)) return c;
  } catch {
    // まだ無い。登録する。
  }

  const res = await fetch(`${config.gateway}/api/v1/apps`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      client_name: 'sukhi-fedi web (unpoly)',
      redirect_uris: redirect_uri,
      scopes: config.scopes,
      website: config.publicOrigin
    })
  });
  if (!res.ok) throw new Error(`app registration failed: ${res.status}`);
  const body = (await res.json()) as { client_id?: string; client_secret?: string };
  // 返事の中身も確かめる(空の返事を「登録できた」と覚えてしまわないように)。
  if (!body.client_id || !body.client_secret) throw new Error('app registration returned no credentials');
  const creds: ClientCreds = {
    client_id: body.client_id,
    client_secret: body.client_secret,
    redirect_uri,
    scopes: config.scopes
  };
  await mkdir(config.dataDir, { recursive: true });
  await writeFile(file, JSON.stringify(creds), { mode: 0o600 });
  return creds;
}
