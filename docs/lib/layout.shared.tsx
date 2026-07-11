import type { BaseLayoutProps } from 'fumadocs-ui/layouts/shared';
import { AstrolabeMark } from '@/components/brand';
import { appName } from '@/lib/shared';
import { createPhotonBaseOptions } from 'fumadocs-theme-photon/layout';

export function baseOptions(): BaseLayoutProps {
  return createPhotonBaseOptions({
    name: appName,
    mark: <AstrolabeMark />,
    homeUrl: '/',
  });
}
