export const appName = 'Astrolabe';
export const docsBasePath = '/astrolabe';
export const docsRoute = '/';
export const docsImageRoute = '/og/docs';
export const docsContentRoute = '/llms.mdx/docs';

export function withDocsBasePath(path: string) {
  const normalizedPath = path.startsWith('/') ? path : `/${path}`;

  if (normalizedPath === '/') {
    return docsBasePath;
  }

  return `${docsBasePath}${normalizedPath}`;
}

export const gitConfig = {
  user: 'photon-hq',
  repo: 'Astrolabe',
  branch: 'main',
};
