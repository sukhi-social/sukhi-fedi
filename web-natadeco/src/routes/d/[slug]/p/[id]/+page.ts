import { browser } from '$app/env';
import { getPost } from '#lib/api.js';
import type { PageLoad } from './$types';

export const load: PageLoad = async ({ params }) => {
  try {
    return { post: await getPost(params.id), anonymous: !browser };
  } catch {
    return { post: null, anonymous: !browser };
  }
};
