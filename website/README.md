# CaliBar website

The public site is https://calibar.app. It uses Astro, TypeScript and CSS, with SF Text and a local Inter fallback.

```sh
npm ci
npm run dev -- --host 127.0.0.1 --port 4322
npm run check
npm run build
```

All download buttons point to `https://github.com/RobSwish/calibar/releases/latest/download/CaliBar.zip`. Set `PUBLIC_CALIBAR_DOWNLOAD_URL` at build time to override it.

## Deploy

The site deploys as static assets on Cloudflare Workers. `wrangler.jsonc` configures `calibar.app` and `www.calibar.app`; Cloudflare manages their DNS records and HTTPS certificates. No server or database is required.

With an authorized Cloudflare CLI session:

```sh
npm run check
npm run deploy
```

Keep credentials in the local Keychain, never in the repository. The website calendar badge uses the visitor’s local date and refreshes at midnight or when the tab becomes visible again.
