import type { LayoutServerLoad } from './$types';

// hooks が決めた言語を、いちばん外の layout に渡す。layout はこれを
// 描く前に i18n に置く ── サーバの module state は請求をまたいで共有
// されるが、描くところ(render)は同期なので、置いてから描き終わるまでの
// あいだに別の請求が割り込むことはない。
export const load: LayoutServerLoad = ({ locals }) => ({ lang: locals.lang, site: locals.site });
