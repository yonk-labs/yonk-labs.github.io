# Yonk-Labs Website Design Spec

## Overview

A public-facing website for the Yonk-Labs GitHub organization (`github.com/yonk-labs`). The site serves as both a technical blog and a project showcase for open source repositories. Built with Hugo and the Blowfish theme, hosted on GitHub Pages with a custom domain.

## Goals

- Publish technical blog posts (tutorials, deep dives, project write-ups)
- Publish video content (YouTube/Vimeo embeds with show notes)
- Publish podcast episodes (audio embeds or links with episode notes)
- Share sample code (highlighted code examples and snippets)
- Showcase open source projects and repos from the yonk-labs org
- Support scheduled publishing — future-dated posts can be committed/pushed but won't appear live until their date
- Present a minimal, clean aesthetic with dark/light mode support
- Deploy automatically on push — no manual steps

## Architecture

### Stack

- **Static site generator:** Hugo
- **Theme:** Blowfish (installed as a Hugo module)
- **Hosting:** GitHub Pages
- **CI/CD:** GitHub Actions (auto-deploy on push to `main`)
- **Repository:** `yonk-labs/yonk-labs.github.io`

### Directory Structure

```
yonk-labs.github.io/
├── hugo.toml                    # Site configuration
├── content/
│   ├── _index.md                # Homepage
│   ├── blog/
│   │   ├── _index.md            # Blog list page
│   │   └── example-post.md      # Sample blog post
│   ├── videos/
│   │   ├── _index.md            # Videos list page
│   │   └── example-video.md     # Sample video page
│   ├── podcasts/
│   │   ├── _index.md            # Podcasts list page
│   │   └── example-episode.md   # Sample episode page
│   ├── samples/
│   │   ├── _index.md            # Sample code list page
│   │   └── example-sample.md    # Sample code page
│   ├── projects/
│   │   ├── _index.md            # Projects list page
│   │   └── example-project.md   # Sample project page
│   └── about.md                 # About page
├── layouts/                     # Custom template overrides (if needed)
├── static/
│   └── CNAME                    # Custom domain for GitHub Pages
├── assets/                      # Custom CSS/JS overrides (if needed)
└── .github/
    └── workflows/
        └── deploy.yml           # GitHub Actions deploy workflow
```

## Content Types

### Blog Posts (`content/blog/`)

Markdown files with frontmatter:

```yaml
---
title: "Post Title"
date: 2026-04-12
draft: false
tags: ["go", "cli", "open-source"]
summary: "A short summary for the list page"
---
```

Features: syntax highlighting, table of contents, tags/categories, reading time.

### Projects (`content/projects/`)

Markdown files with frontmatter:

```yaml
---
title: "Project Name"
date: 2026-04-12
draft: false
tags: ["python", "api"]
summary: "One-line project description"
externalUrl: "https://github.com/yonk-labs/project-name"
---
```

Each project page includes: description, tech stack, links to GitHub repo and live demo (if applicable), and current status.

### Videos (`content/videos/`)

Markdown files with frontmatter:

```yaml
---
title: "Video Title"
date: 2026-04-12
draft: false
tags: ["tutorial", "go"]
summary: "What this video covers"
---
```

Body contains a YouTube/Vimeo embed (using Blowfish's built-in `youtube` shortcode or raw iframe) followed by show notes and description.

### Podcasts (`content/podcasts/`)

Markdown files with frontmatter:

```yaml
---
title: "Episode Title"
date: 2026-04-12
draft: false
tags: ["interview", "open-source"]
summary: "Episode description"
---
```

Body contains an audio player embed (HTML5 `<audio>` tag or podcast platform embed) followed by episode notes, links, and transcript if available.

### Sample Code (`content/samples/`)

Markdown files with frontmatter:

```yaml
---
title: "Sample Title"
date: 2026-04-12
draft: false
tags: ["go", "cli"]
summary: "What this code demonstrates"
---
```

Body contains code blocks with syntax highlighting, explanation, and usage instructions. Links to full source on GitHub where applicable.

### Static Pages

- **Homepage** (`content/_index.md`): Hero section with Yonk-Labs branding, tagline, recent blog posts, and featured projects. Uses Blowfish's hero or profile homepage layout.
- **About** (`content/about.md`): What Yonk-Labs is, who's behind it, what's being built.

## Theme Configuration

### Blowfish Settings

- **Color scheme:** Minimal/clean, leveraging Blowfish's built-in schemes
- **Dark/light toggle:** Enabled
- **Search:** Enabled (Blowfish uses Fuse.js)
- **Syntax highlighting:** Enabled for code blocks
- **Table of contents:** Enabled on blog posts
- **Homepage layout:** Hero layout with background image/gradient and branding
- **Taxonomy:** Tags enabled for both blog posts and projects

### Navigation

Top navigation bar with:
- Blog
- Videos
- Podcasts
- Samples
- Projects
- About
- GitHub icon link → `https://github.com/yonk-labs`

## Deployment

### GitHub Actions Workflow

Triggered on push to `main` AND on a daily cron schedule (for scheduled publishing). Steps:
1. Checkout repository
2. Setup Hugo (pinned version)
3. Build site (`hugo --minify`) — Hugo excludes future-dated posts by default
4. Deploy to GitHub Pages via `actions/deploy-pages`

### Scheduled Publishing

Posts with a future `date` in frontmatter are automatically excluded from Hugo builds. Authors can commit and push future-dated content at any time. A daily cron trigger (`schedule: cron: '0 6 * * *'`) rebuilds the site, picking up any posts whose date has arrived. No manual intervention needed.

### Custom Domain

- A `CNAME` file in `static/` containing the custom domain name
- DNS configuration: either A records pointing to GitHub's IPs (`185.199.108-111.153`) or a CNAME record pointing to `yonk-labs.github.io`
- GitHub automatically provisions HTTPS via Let's Encrypt
- Domain name TBD — user will provide at setup time

## Reference

- Prior project with similar setup: [opensourcebusiness.community](https://github.com/osb-community/opensourcebusiness.community) (Hugo + Terminal theme + GitHub Pages)
- Key differences from reference: Blowfish theme instead of Terminal, Hugo modules instead of git submodules, GitHub Actions instead of manual deploy script, project showcase as a first-class content type
