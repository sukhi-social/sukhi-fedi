<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# bun/ — Node.js の検証用サイドカー

**名前に反して、Bun は使っていません。** Node.js 24+ で動く TypeScript
(`node --import @oxc-node/core/register`、pnpm) です。ディレクトリ名は
むかしの名前のまま残してあります。

## 何のためにあるか

本番の `fedify.*.v1` は **Elixir (`SukhiFedi.Fedi`) がネイティブに
答えています** (v0.3.0 から)。このディレクトリは本番の経路にはいません。
いまの役目は、ビルド時・テスト時の検証用です。

- **オラクル**: 本物の fedify (`@fedify/fedify`) で、ビルダーと署名を
  固定の鍵・固定の入力で走らせ、golden fixture を作ります
  (`scripts/dump_golden.ts` → `elixir/test/support/fixtures/fedify_golden.json`)。
  Elixir 側のテストは、その出力を受け入れられることで互換性を示します。
- **ロールバック経路**: `services/fedify_service.ts` は同じ NATS Micro の
  subject (`fedify-workers` queue group) に答える旧実装です。必要なら
  Elixir の代わりに立てられます。

## 使いかた

```sh
cd bun
pnpm install
pnpm run check   # tsc --noEmit (型のみ)
pnpm test        # node --test
```

fixture を作り直すとき:

```sh
node --import @oxc-node/core/register scripts/dump_golden.ts \
  > ../elixir/test/support/fixtures/fedify_golden.json
```

どこで動くか、なぜそう分けたかは `docs/ARCHITECTURE.md` が正本です。
