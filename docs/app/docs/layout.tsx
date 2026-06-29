import { source } from '@/lib/source';
import { DocsLayout } from 'fumadocs-ui/layouts/notebook';
import { baseOptions } from '@/lib/layout.shared';

export default function Layout({ children }: LayoutProps<'/docs'>) {
  const options = baseOptions();

  return (
    <DocsLayout
      tree={source.getPageTree()}
      {...options}
      tabs={false}
      nav={{ ...options.nav, mode: 'top' }}
      sidebar={{
        collapsible: true,
        defaultOpenLevel: 1,
      }}
    >
      {children}
    </DocsLayout>
  );
}
