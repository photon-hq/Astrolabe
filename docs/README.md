This is a Next.js application generated with
[Create Fumadocs](https://github.com/fuma-nama/fumadocs).

It is a Next.js app with [Static Export](https://nextjs.org/docs/app/guides/static-exports) configured.

## Shared Photon theme

The reusable Fumadocs presentation layer is published as
[`@photon-hq/fumadocs-theme`](https://github.com/orgs/photon-hq/packages/npm/package/fumadocs-theme),
an internal GitHub Package.
Set `GITHUB_PACKAGES_TOKEN` to a classic GitHub personal access token with
`read:packages` before installing dependencies locally or in an external build
environment such as Cloudflare:

```bash
pnpm install --frozen-lockfile
```

The committed `.npmrc` maps the `@photon-hq` scope to GitHub Packages and reads
the token from the environment; it does not contain a credential. If the Photon
organization enforces SAML SSO, authorize the token for the organization.
Configure the same value as an encrypted `GITHUB_PACKAGES_TOKEN` build secret
in Cloudflare; prefer a service-account token limited to `read:packages`.

Astrolabe keeps its content, logo, font registration, routes, and deployment
configuration here; shared layout, provider, search, page actions, and styling
come from the version pinned in `package.json`.

Run development server:

```bash
npm run dev
# or
pnpm dev
# or
yarn dev
```

Open http://localhost:3000 with your browser to see the result.

## Explore

In the project, you can see:

- `lib/source.ts`: Code for content source adapter, [`loader()`](https://fumadocs.dev/docs/headless/source-api) provides the interface to access your content.
- `lib/layout.shared.tsx`: Shared options for layouts, optional but preferred to keep.

| Route                     | Description                                            |
| ------------------------- | ------------------------------------------------------ |
| `app/(home)`              | The route group for your landing page and other pages. |
| `app/docs`                | The documentation layout and pages.                    |
| `app/api/search/route.ts` | The Route Handler for search.                          |

### Fumadocs MDX

A `source.config.ts` config file has been included, you can customise different options like frontmatter schema.

Read the [Introduction](https://fumadocs.dev/docs/mdx) for further details.

## Learn More

To learn more about Next.js and Fumadocs, take a look at the following
resources:

- [Next.js Documentation](https://nextjs.org/docs) - learn about Next.js
  features and API.
- [Learn Next.js](https://nextjs.org/learn) - an interactive Next.js tutorial.
- [Fumadocs](https://fumadocs.dev) - learn about Fumadocs
