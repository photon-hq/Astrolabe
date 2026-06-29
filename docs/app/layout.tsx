import type { Metadata } from 'next';
import { Provider } from '@/components/provider';
import './global.css';

// Set NEXT_PUBLIC_SITE_URL (e.g. https://docs.example.com) in CI so OpenGraph
// image URLs resolve to the deployed origin instead of localhost.
export const metadata: Metadata = {
  metadataBase: new URL(process.env.NEXT_PUBLIC_SITE_URL ?? 'http://localhost:3000'),
  icons: {
    icon: '/astrolabe/favicon-128x128.png',
  },
};

export default function Layout({ children }: LayoutProps<'/'>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body className="flex flex-col min-h-screen">
        <Provider>{children}</Provider>
      </body>
    </html>
  );
}
