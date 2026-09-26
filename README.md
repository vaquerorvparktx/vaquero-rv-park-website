# Vaquero RV Park — website

The public website for Vaquero RV Park, 772 Humble Camp Rd, Pleasanton, TX 78064.

**This repo is public. Never put financials, tenant names, partner details or bank information here.**
Those live in the private `vaquero-rv-park` knowledge base.

## How it works

| File | What it is |
|---|---|
| `index.html` | **The whole site.** Edit this one file. All content lives in the `SITE` object near the top of the `<script>` block. |
| `photos/` | Every image the site uses. Replace a file, keep the name, and the site updates. |
| `build.pl` | Generates `dist/` (what gets served) and the single-file copy used for email. |
| `dist/` | The built site. This is what the host serves. Rebuild after every change. |

## Making a change

1. Edit `index.html` (or drop a new photo into `photos/`).
2. Run the build:
   ```
   SITE_URL=https://your-domain.com perl build.pl
   ```
3. Commit and push. The host rebuilds the live site in about a minute.

## What to edit for common changes

- **Lot availability, rent, deposits** → the `LOTS` / `SPECIAL` data in `index.html`.
  Statuses are `available`, `pending`, `occupied`.
- **Rates and rental types** → `SITE.rentalTypes`.
- **Amenities** → `SITE.amenities`, each with status `live` or `soon`.
- **Phone, email, Facebook, application link** → the top of `SITE`.
- **The "sample data" banner** → set `SITE.demoMode` to `false` once real lot data is in.

## Before launch

- [ ] Add the Innago application URL to `SITE.applyUrl`
- [ ] Replace the sample lot records with the real rent roll
- [ ] Verify the drive times in `SITE.nearby`
- [ ] Set `SITE.demoMode = false`
- [ ] Point the domain at the host and rebuild with the real `SITE_URL`
- [ ] Create the Google Business Profile and link it to the site
