import { source } from '@/lib/source';
import { DocsLayout } from 'fumadocs-ui/layouts/docs';
import { baseOptions } from '@/lib/layout.shared';
import { PhotonSidebarActions } from 'fumadocs-theme-photon/sidebar';
import { gitConfig } from '@/lib/shared';

export default function Layout({ children }: LayoutProps<'/'>) {
  return (
    <DocsLayout
      tree={source.getPageTree()}
      {...baseOptions()}
      tabs={false}
      sidebar={{
        collapsible: true,
        defaultOpenLevel: 1,
        footer: (
          <PhotonSidebarActions
            repositoryUrl={`https://github.com/${gitConfig.user}/${gitConfig.repo}`}
          />
        ),
      }}
    >
      {children}
    </DocsLayout>
  );
}
