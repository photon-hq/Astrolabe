import type { BaseLayoutProps } from 'fumadocs-ui/layouts/shared';
import { BrandTitle } from '@/components/brand';
import { gitConfig } from './shared';

export function baseOptions(): BaseLayoutProps {
  return {
    nav: {
      title: <BrandTitle />,
    },
    links: [
      {
        type: 'main',
        text: 'Docs',
        url: '/docs',
        active: 'nested-url',
      },
      {
        type: 'button',
        text: 'GitHub',
        url: `https://github.com/${gitConfig.user}/${gitConfig.repo}`,
        external: true,
        secondary: true,
      },
    ],
  };
}
