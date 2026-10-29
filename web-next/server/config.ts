// SPDX-License-Identifier: AGPL-3.0-or-later
// 環境からの設定。ここに集めて、ほかの場所は process.env を読まない。
//
//   PORT              待ち受けるポート(既定 5174)
//   GATEWAY_URL       Elixir gateway のもと(既定 http://localhost:4000)
//   PUBLIC_ORIGIN     ブラウザから見えるこのサイトの origin。OAuth の戻り先に使う
//   COOKIE_SECURE     1 のとき、cookie に Secure を付ける(https の裏に置くとき)
//   POST_DELAY_MIN    投稿が上がるまでの「見直しの余白」(分、既定 15 = 約四半刻)
//   NOTIFY_HOLD_MIN   通知をポツポツ届けるまでの間(分、既定 60 = 一刻のうち)
//   ABOUT_URL         はじめての人の行き先(既定 https://about.sukhi.social)。空にすると、ここの入口を見せる
//   SUKHI_DEV_TOKEN   dev のときだけ。入った状態から始める(mock 用)

import { fileURLToPath } from 'node:url';

const port = Number(process.env.PORT ?? 5174);
// URL.pathname は、日本語・韓国語のフォルダー名を %XX にしてしまう。ディスクのパスには fileURLToPath。
const here = (rel: string) => fileURLToPath(new URL(rel, import.meta.url));

export const config = {
  port,
  gateway: (process.env.GATEWAY_URL ?? 'http://localhost:4000').replace(/\/$/, ''),
  publicOrigin: (process.env.PUBLIC_ORIGIN ?? `http://localhost:${port}`).replace(/\/$/, ''),
  aboutUrl: (process.env.ABOUT_URL ?? 'https://about.sukhi.social').replace(/\/$/, ''),
  secureCookie: process.env.COOKIE_SECURE === '1',
  postDelayMin: Number(process.env.POST_DELAY_MIN ?? 15),
  notifyHoldMin: Number(process.env.NOTIFY_HOLD_MIN ?? 60),
  devToken: process.env.NODE_ENV === 'production' ? undefined : process.env.SUKHI_DEV_TOKEN,
  // 書き読みの scope。広げたら、登録しなおしになる(client.ts が比べる)。
  scopes: 'read write follow push',
  dataDir: here('../data/'),
  publicDir: here('../public/'),
  nodeModules: here('../node_modules/')
};
