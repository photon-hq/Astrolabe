import { source } from '@/lib/source';
import { DocsLayout } from 'fumadocs-ui/layouts/docs';
import { baseOptions } from '@/lib/layout.shared';
import { SidebarActions } from '@/components/sidebar-actions';

export default function Layout({ children }: LayoutProps<'/'>) {
  return (
    <DocsLayout
      tree={source.getPageTree()}
      {...baseOptions()}
      tabs={false}
      sidebar={{
        collapsible: true,
        defaultOpenLevel: 1,
        footer: <SidebarActions />,
      }}
    >
      {children}
    </DocsLayout>
  );
}
