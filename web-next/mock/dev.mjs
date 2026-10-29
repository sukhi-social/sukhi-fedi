// SPDX-License-Identifier: AGPL-3.0-or-later
// gateway なしで、入った状態を見る。
//
//   pnpm run dev:mock     # http://localhost:5174 — 偽の gateway(:4010)と、郵便局がいっしょに立つ
//
// 偽の返事は mock.mjs の respond() 一か所。SUKHI_DEV_TOKEN=mock で、入った状態から始まる。
// ここで押した ☆ や 投稿は、どこにも届かない(お預かりだけは、この間のメモリに覚えている)。

process.env.SUKHI_DEV_TOKEN ??= 'mock';
// :4000 は、本物の gateway が使っているかもしれない。偽のほうは :4010 に立てる。
const port = Number(process.env.MOCK_PORT ?? 4010);
process.env.GATEWAY_URL ??= `http://localhost:${port}`;

const { startApiServer } = await import('./api-server.mjs');
const api = await startApiServer({ port });
console.log(`[mock-api] http://localhost:${api.port}`);

await import('../server/main.ts');
