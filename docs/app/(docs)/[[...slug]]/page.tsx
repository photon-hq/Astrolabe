import {
  getLLMText,
  getPageImage,
  getPageMarkdownUrl,
  source,
} from '@/lib/source';
import {
  DocsBody,
  DocsDescription,
  DocsPage,
  DocsTitle,
} from 'fumadocs-ui/layouts/docs/page';
import { notFound } from 'next/navigation';
import { getMDXComponents } from '@/components/mdx';
import type { Metadata } from 'next';
import { createRelativeLink } from 'fumadocs-ui/mdx';
import { gitConfig } from '@/lib/shared';
import { findNeighbour } from 'fumadocs-core/page-tree';
import { DocsPageActions } from '@/components/docs-page-actions';

export default async function Page(props: PageProps<'/[[...slug]]'>) {
  const params = await props.params;
  const page = source.getPage(params.slug);
  if (!page) notFound();

  const MDX = page.data.body;
  const markdownUrl = getPageMarkdownUrl(page).url;
  const githubUrl = `https://github.com/${gitConfig.user}/${gitConfig.repo}/blob/${gitConfig.branch}/docs/content/docs/${page.path}`;
  const pageText = await getLLMText(page);
  const neighbours = findNeighbour(source.getPageTree(), page.url);
  const previousPage = neighbours.previous
    ? {
        name:
          typeof neighbours.previous.name === 'string'
            ? neighbours.previous.name
            : 'Previous',
        url: neighbours.previous.url,
      }
    : undefined;
  const nextPage = neighbours.next
    ? {
        name:
          typeof neighbours.next.name === 'string' ? neighbours.next.name : 'Next',
        url: neighbours.next.url,
      }
    : undefined;

  return (
    <DocsPage toc={page.data.toc} full={page.data.full}>
      <div className="astrolabe-docs-header">
        <div className="astrolabe-docs-heading">
          <DocsTitle className="astrolabe-docs-title">{page.data.title}</DocsTitle>
          <DocsDescription className="astrolabe-docs-description">
            {page.data.description}
          </DocsDescription>
        </div>
        <DocsPageActions
          pageText={pageText}
          pageUrl={page.url}
          markdownUrl={markdownUrl}
          githubUrl={githubUrl}
          previous={previousPage}
          next={nextPage}
        />
      </div>
      <DocsBody>
        <MDX
          components={getMDXComponents({
            // this allows you to link to other pages with relative file paths
            a: createRelativeLink(source, page),
          })}
        />
      </DocsBody>
    </DocsPage>
  );
}

export async function generateStaticParams() {
  return source.generateParams();
}

export async function generateMetadata(props: PageProps<'/[[...slug]]'>): Promise<Metadata> {
  const params = await props.params;
  const page = source.getPage(params.slug);
  if (!page) notFound();

  return {
    title: page.data.title,
    description: page.data.description,
    openGraph: {
      images: getPageImage(page).url,
    },
  };
}
