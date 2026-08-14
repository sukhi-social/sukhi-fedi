// Volpeon絵文字の取得・フィルタリング（ナイフ・銃などの武器除外）・SQL生成スクリプト
import fs from 'node:fs';
import path from 'node:path';

const srcTmp = '/tmp/volpeon_emojis';
const outStatic = '/tmp/volpeon_static/emojis';

if (fs.existsSync('/tmp/volpeon_static')) {
  fs.rmSync('/tmp/volpeon_static', { recursive: true, force: true });
}
fs.mkdirSync(outStatic, { recursive: true });

const dirs = fs.readdirSync(srcTmp).filter((f) => fs.statSync(path.join(srcTmp, f)).isDirectory());
const weaponRegex = /(knife|knives|gun|guns|pistol|rifle|revolver|shotgun|sniper|stab|stabbed|blade|dagger|sword|weapon|grenade|bomb)/i;

let copiedCount = 0;
const sqlStatements = [];
const emojiRecords = [];
const excludedRecords = [];

for (const d of dirs) {
  const metaPath = path.join(srcTmp, d, 'meta.json');
  if (!fs.existsSync(metaPath)) continue;
  const meta = JSON.parse(fs.readFileSync(metaPath, 'utf8'));

  const outPackDir = path.join(outStatic, d);
  fs.mkdirSync(outPackDir, { recursive: true });

  for (const item of meta.emojis || []) {
    const texts = [item.emoji.name, item.fileName, ...(item.emoji.aliases || [])];
    if (texts.some((t) => weaponRegex.test(t))) {
      excludedRecords.push({ pack: d, name: item.emoji.name, fileName: item.fileName });
      continue;
    }

    const srcFile = path.join(srcTmp, d, item.fileName);
    const dstFile = path.join(outPackDir, item.fileName);
    if (fs.existsSync(srcFile)) {
      fs.copyFileSync(srcFile, dstFile);
      copiedCount++;
    }

    const sc = item.emoji.name;
    const cat = item.emoji.category || d;
    const rawAliases = item.emoji.aliases || [];
    const aliasesSql =
      rawAliases.length > 0
        ? `ARRAY[${rawAliases.map((a) => `'${a.replace(/'/g, "''")}'`).join(',')}]::varchar[]`
        : 'ARRAY[]::varchar[]';
    const imgUrl = `https://sukhi.f3liz.casa/static/emojis/${d}/${item.fileName}`;
    const staticUrl = imgUrl;

    emojiRecords.push({
      shortcode: sc,
      category: cat,
      aliases: rawAliases,
      image_url: imgUrl,
      static_url: staticUrl,
      pack: d,
      fileName: item.fileName
    });

    const escapedSc = sc.replace(/'/g, "''");
    const escapedCat = cat.replace(/'/g, "''");
    const escapedImg = imgUrl.replace(/'/g, "''");
    const escapedStatic = staticUrl.replace(/'/g, "''");

    sqlStatements.push(`INSERT INTO custom_emojis (shortcode, domain, image_url, static_url, category, aliases, visible_in_picker, created_at, last_fetched_at)
VALUES ('${escapedSc}', NULL, '${escapedImg}', '${escapedStatic}', '${escapedCat}', ${aliasesSql}, true, NOW(), NOW())
ON CONFLICT (shortcode, domain) DO UPDATE SET
  image_url = EXCLUDED.image_url,
  static_url = EXCLUDED.static_url,
  category = EXCLUDED.category,
  aliases = EXCLUDED.aliases,
  visible_in_picker = EXCLUDED.visible_in_picker,
  last_fetched_at = EXCLUDED.last_fetched_at;`);
  }
}

console.log(`Copied ${copiedCount} emoji image files.`);
console.log(`Excluded ${excludedRecords.length} weapon/knife/gun emojis.`);
console.log(`Generated ${sqlStatements.length} SQL insert statements.`);

fs.writeFileSync('/tmp/volpeon_import.sql', 'BEGIN;\n' + sqlStatements.join('\n') + '\nCOMMIT;\n');
fs.writeFileSync('/tmp/volpeon_emojis.json', JSON.stringify(emojiRecords, null, 2));
fs.writeFileSync('/tmp/volpeon_excluded.json', JSON.stringify(excludedRecords, null, 2));
