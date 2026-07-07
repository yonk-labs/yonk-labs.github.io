# Yonk-Labs Website Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Yonk-Labs Hugo website with Blowfish theme, blog + project showcase, deployed via GitHub Actions to GitHub Pages.

**Architecture:** Hugo static site using Blowfish theme installed as a Hugo module. Content organized into blog posts and project showcases. GitHub Actions builds and deploys to GitHub Pages on push to `main`. Custom domain via CNAME.

**Tech Stack:** Hugo (>=0.141.0), Go (>=1.12, for Hugo modules), Blowfish theme, GitHub Actions, GitHub Pages

---

### Task 1: Install Hugo and Go

**Files:** None (system setup)

- [ ] **Step 1: Install Go**

```bash
sudo snap install go --classic
```

Verify:
```bash
go version
```
Expected: `go version go1.x.x linux/amd64`

- [ ] **Step 2: Install Hugo extended edition**

Hugo extended is required for Blowfish (SCSS processing). Install via snap for latest version:

```bash
sudo snap install hugo
```

Verify:
```bash
hugo version
```
Expected: Version >= 0.141.0 with `extended` in the output.

- [ ] **Step 3: Commit** — nothing to commit, system-level install.

---

### Task 2: Create GitHub Repo and Initialize Hugo Site

**Files:**
- Create: `hugo.toml` (temporary, replaced by config dir in Task 3)
- Create: `.gitignore`

- [ ] **Step 1: Create the GitHub repo**

```bash
gh repo create yonk-labs/yonk-labs.github.io --public --clone --description "Yonk-Labs website and blog"
```

This clones into `./yonk-labs.github.io`. We're working from `/home/yonk/website` so we need to move things or work in that directory.

```bash
cd /home/yonk/website
```

If the repo was cloned into a subdirectory, move its contents (including `.git`) into `/home/yonk/website`:
```bash
# Only if gh cloned into a subdirectory:
mv yonk-labs.github.io/.git . 2>/dev/null
rm -rf yonk-labs.github.io 2>/dev/null
```

- [ ] **Step 2: Initialize Hugo site**

```bash
hugo new site . --force
```

The `--force` flag allows creating in an existing non-empty directory.

- [ ] **Step 3: Initialize Hugo modules**

```bash
hugo mod init github.com/yonk-labs/yonk-labs.github.io
```

- [ ] **Step 4: Create .gitignore**

Write `.gitignore`:
```
/public/
/resources/_gen/
/.hugo_build.lock
.superpowers/
node_modules/
.DS_Store
```

- [ ] **Step 5: Commit**

```bash
git add hugo.toml go.mod .gitignore content/ archetypes/
git commit -m "chore: initialize Hugo site with module support"
```

---

### Task 3: Configure Blowfish Theme

**Files:**
- Delete: `hugo.toml` (replaced by config directory)
- Create: `config/_default/hugo.toml`
- Create: `config/_default/languages.en.toml`
- Create: `config/_default/menus.en.toml`
- Create: `config/_default/params.toml`
- Create: `config/_default/module.toml`

- [ ] **Step 1: Remove root hugo.toml and create config directory**

```bash
rm hugo.toml
mkdir -p config/_default
```

- [ ] **Step 2: Create `config/_default/module.toml`**

```toml
[[imports]]
  path = "github.com/nunocoracao/blowfish/v2"
```

- [ ] **Step 3: Create `config/_default/hugo.toml`**

```toml
baseURL = "https://yonk-labs.github.io/"
languageCode = "en"
title = "Yonk-Labs"

enableRobotsTXT = true
paginate = 10

[sitemap]
  changeFreq = "daily"
  priority = 0.5

[outputs]
  home = ["HTML", "RSS", "JSON"]
```

Note: `baseURL` will be updated to the custom domain once the user provides it.

- [ ] **Step 4: Create `config/_default/languages.en.toml`**

```toml
languageName = "English"
weight = 1
title = "Yonk-Labs"

[params.author]
  name = "Yonk-Labs"
  headline = "Building tools in the open"
  bio = "Open source tools and experiments from the Yonk-Labs team."
  links = [
    { github = "https://github.com/yonk-labs" },
  ]
```

- [ ] **Step 5: Create `config/_default/menus.en.toml`**

```toml
[[main]]
  name = "Blog"
  pageRef = "blog"
  weight = 10

[[main]]
  name = "Videos"
  pageRef = "videos"
  weight = 20

[[main]]
  name = "Podcasts"
  pageRef = "podcasts"
  weight = 30

[[main]]
  name = "Samples"
  pageRef = "samples"
  weight = 40

[[main]]
  name = "Projects"
  pageRef = "projects"
  weight = 50

[[main]]
  name = "About"
  pageRef = "about"
  weight = 60
```

- [ ] **Step 6: Create `config/_default/params.toml`**

```toml
colorScheme = "noir"
defaultAppearance = "dark"
autoSwitchAppearance = true

enableSearch = true
enableCodeCopy = true

[homepage]
  layout = "hero"
  homepageImage = ""
  showRecent = true
  showRecentItems = 5
  showMoreLink = true
  showMoreLinkDest = "/blog"
  cardView = false

[article]
  showDate = true
  showDateUpdated = false
  showAuthor = false
  showBreadcrumbs = true
  showReadingTime = true
  showTableOfContents = true
  showTaxonomies = true
  showWordCount = false
  showSummary = true
  sharingLinks = ["twitter", "reddit", "linkedin", "email"]

[list]
  showBreadcrumbs = true
  showSummary = true
  showTableOfContents = false
  groupByYear = true

[taxonomy]
  showTermCount = true
```

- [ ] **Step 7: Download the theme module**

```bash
hugo mod get -u
```

This downloads Blowfish and updates `go.mod` and `go.sum`.

- [ ] **Step 8: Verify the site builds**

```bash
hugo --minify
```

Expected: Build succeeds with no errors. Output shows pages generated.

- [ ] **Step 9: Commit**

```bash
git add config/ go.mod go.sum
git rm hugo.toml 2>/dev/null
git commit -m "feat: add Blowfish theme with site configuration"
```

---

### Task 4: Create Content Pages

**Files:**
- Create: `content/_index.md`
- Create: `content/blog/_index.md`
- Create: `content/blog/hello-world.md`
- Create: `content/videos/_index.md`
- Create: `content/videos/example-video.md`
- Create: `content/podcasts/_index.md`
- Create: `content/podcasts/example-episode.md`
- Create: `content/samples/_index.md`
- Create: `content/samples/example-sample.md`
- Create: `content/projects/_index.md`
- Create: `content/projects/example-project.md`
- Create: `content/about.md`

- [ ] **Step 1: Create homepage `content/_index.md`**

```markdown
---
title: "Yonk-Labs"
description: "Open source tools and experiments"
---

Welcome to **Yonk-Labs** — we build open source tools and share what we learn along the way.

Explore our [blog](/blog/) for technical write-ups, watch our [videos](/videos/), listen to our [podcasts](/podcasts/), browse [sample code](/samples/), or check out our [projects](/projects/).
```

- [ ] **Step 2: Create blog section `content/blog/_index.md`**

```markdown
---
title: "Blog"
description: "Technical posts, tutorials, and project updates"
---
```

- [ ] **Step 3: Create sample blog post `content/blog/hello-world.md`**

```markdown
---
title: "Hello World"
date: 2026-04-12
draft: false
tags: ["meta"]
summary: "First post on the Yonk-Labs blog — what we're building and why."
---

This is the first post on the Yonk-Labs blog.

We started Yonk-Labs as a place to build open source tools and share what we learn. Expect technical deep dives, project announcements, and the occasional tutorial.

## What's coming

- Project showcases with technical breakdowns
- Tutorials and guides
- Lessons learned from building in the open

Stay tuned.
```

- [ ] **Step 4: Create videos section `content/videos/_index.md`**

```markdown
---
title: "Videos"
description: "Video tutorials, demos, and walkthroughs"
---
```

- [ ] **Step 5: Create sample video page `content/videos/example-video.md`**

```markdown
---
title: "Example Video"
date: 2026-04-12
draft: false
tags: ["example"]
summary: "A placeholder video to demonstrate the video section layout."
---

{{</* youtube dQw4w9WgXcQ */>}}

## Show Notes

This is an example video page. Replace the YouTube ID above with a real video.

Use Hugo's built-in `youtube` shortcode for YouTube embeds, or use a raw iframe for Vimeo and other platforms:

\`\`\`html
<iframe src="https://player.vimeo.com/video/VIDEO_ID" width="640" height="360" frameborder="0" allowfullscreen></iframe>
\`\`\`
```

- [ ] **Step 6: Create podcasts section `content/podcasts/_index.md`**

```markdown
---
title: "Podcasts"
description: "Podcast episodes and audio content"
---
```

- [ ] **Step 7: Create sample podcast episode `content/podcasts/example-episode.md`**

```markdown
---
title: "Episode 0: Welcome to Yonk-Labs"
date: 2026-04-12
draft: false
tags: ["example"]
summary: "A placeholder episode to demonstrate the podcast section layout."
---

<audio controls>
  <source src="/audio/episode-0.mp3" type="audio/mpeg">
  Your browser does not support the audio element.
</audio>

## Episode Notes

This is an example podcast episode page. Replace the audio source above with a real audio file or embed from a podcast platform.

For platform embeds (Spotify, Apple Podcasts, etc.), use an iframe:

\`\`\`html
<iframe src="https://open.spotify.com/embed/episode/EPISODE_ID" width="100%" height="152" frameborder="0"></iframe>
\`\`\`

## Links

- Resources mentioned in this episode
```

- [ ] **Step 8: Create samples section `content/samples/_index.md`**

```markdown
---
title: "Sample Code"
description: "Code examples, snippets, and reference implementations"
---
```

- [ ] **Step 9: Create sample code page `content/samples/example-sample.md`**

````markdown
---
title: "Hello World in Go"
date: 2026-04-12
draft: false
tags: ["go", "example"]
summary: "A simple Hello World example in Go."
---

A minimal Go program to get started.

## The Code

```go
package main

import "fmt"

func main() {
    fmt.Println("Hello from Yonk-Labs!")
}
```

## How to Run

```bash
go run main.go
```

## Full Source

See the complete example on [GitHub](https://github.com/yonk-labs).
````

- [ ] **Step 10: Create projects section `content/projects/_index.md`**

```markdown
---
title: "Projects"
description: "Open source projects from the Yonk-Labs org"
---
```

- [ ] **Step 11: Create sample project page `content/projects/example-project.md`**

```markdown
---
title: "Example Project"
date: 2026-04-12
draft: false
tags: ["example"]
summary: "A placeholder project to demonstrate the showcase layout."
externalUrl: "https://github.com/yonk-labs"
---

This is an example project page. Replace this with a real project from the yonk-labs org.

## Overview

Describe what the project does, why it exists, and how to use it.

## Tech Stack

- Language/framework
- Key dependencies

## Links

- [GitHub Repository](https://github.com/yonk-labs)
```

- [ ] **Step 12: Create about page `content/about.md`**

```markdown
---
title: "About"
description: "About Yonk-Labs"
showDate: false
showReadingTime: false
showAuthor: false
---

**Yonk-Labs** is an open source organization building tools and experiments in public.

We believe in learning by building and sharing what we learn along the way. Our projects span various domains — from developer tools to infrastructure utilities.

## Find us

- [GitHub](https://github.com/yonk-labs)
```

- [ ] **Step 13: Verify the site builds and serves**

```bash
hugo server --minify --bind 0.0.0.0 --baseURL http://192.168.1.206
```

Open `http://192.168.1.206:1313` in a browser. Verify:
- Homepage shows hero layout with "Yonk-Labs" branding
- Navigation has Blog, Videos, Podcasts, Samples, Projects, About links
- Blog list page shows the hello-world post
- Videos list page shows the example video
- Podcasts list page shows the example episode
- Samples list page shows the example code
- Projects list page shows the example project
- About page renders correctly
- Dark/light toggle works

Stop the server with Ctrl+C.

- [ ] **Step 14: Commit**

```bash
git add content/
git commit -m "feat: add homepage, blog, videos, podcasts, samples, projects, and about content"
```

---

### Task 5: Create GitHub Actions Deploy Workflow

**Files:**
- Create: `.github/workflows/deploy.yml`
- Create: `static/CNAME`

- [ ] **Step 1: Create `.github/workflows/deploy.yml`**

```yaml
name: Deploy Hugo site to GitHub Pages

on:
  push:
    branches: ["main"]
  schedule:
    # Daily rebuild at 6:00 AM UTC — picks up future-dated posts whose date has arrived
    - cron: '0 6 * * *'
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: "pages"
  cancel-in-progress: false

defaults:
  run:
    shell: bash

jobs:
  build:
    runs-on: ubuntu-latest
    env:
      HUGO_VERSION: "0.147.0"
    steps:
      - name: Install Hugo CLI
        run: |
          wget -O ${{ runner.temp }}/hugo.deb https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_extended_${HUGO_VERSION}_linux-amd64.deb \
          && sudo dpkg -i ${{ runner.temp }}/hugo.deb

      - name: Install Dart Sass
        run: sudo snap install dart-sass

      - name: Checkout
        uses: actions/checkout@v4
        with:
          submodules: recursive
          fetch-depth: 0

      - name: Setup Pages
        id: pages
        uses: actions/configure-pages@v5

      - name: Install Node.js dependencies
        run: "[[ -f package-lock.json || -f npm-shrinkwrap.json ]] && npm ci || true"

      - name: Setup Go
        uses: actions/setup-go@v5
        with:
          go-version: "stable"

      - name: Build with Hugo
        env:
          HUGO_CACHEDIR: ${{ runner.temp }}/hugo_cache
          HUGO_ENVIRONMENT: production
          TZ: America/New_York
        run: hugo --minify --baseURL "${{ steps.pages.outputs.base_url }}/"

      - name: Upload artifact
        uses: actions/upload-pages-artifact@v3
        with:
          path: ./public

  deploy:
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    runs-on: ubuntu-latest
    needs: build
    steps:
      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v4
```

- [ ] **Step 2: Create placeholder `static/CNAME`**

```
CUSTOM_DOMAIN_HERE
```

This file will be updated with the actual domain name when the user provides it. The CNAME file tells GitHub Pages which custom domain to serve.

- [ ] **Step 3: Verify the site still builds locally**

```bash
hugo --minify
```

Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/deploy.yml static/CNAME
git commit -m "feat: add GitHub Actions deploy workflow for GitHub Pages"
```

---

### Task 6: Push to GitHub and Verify Deployment

**Files:** None (git operations only)

- [ ] **Step 1: Set the remote origin**

If the remote isn't set already (depends on whether `gh repo create --clone` worked):

```bash
git remote get-url origin 2>/dev/null || git remote add origin git@github.com:yonk-labs/yonk-labs.github.io.git
```

- [ ] **Step 2: Push to GitHub**

```bash
git push -u origin main
```

- [ ] **Step 3: Enable GitHub Pages in repo settings**

```bash
gh api repos/yonk-labs/yonk-labs.github.io/pages -X POST -f build_type=workflow 2>/dev/null || echo "Pages may already be configured"
```

- [ ] **Step 4: Wait for the Actions workflow to complete**

```bash
gh run watch --repo yonk-labs/yonk-labs.github.io
```

Expected: Workflow completes successfully.

- [ ] **Step 5: Verify the live site**

```bash
echo "Site should be live at https://yonk-labs.github.io/"
```

Open the URL in a browser and verify:
- Homepage renders with Blowfish hero layout
- Blog post is accessible
- Projects page works
- Navigation functions correctly
- Dark/light toggle works

---

### Task 7: Configure Custom Domain (Manual Steps)

This task requires user input (domain name) and DNS provider access.

- [ ] **Step 1: User provides domain name**

Ask the user which domain they want to use.

- [ ] **Step 2: Update `static/CNAME`**

Replace `CUSTOM_DOMAIN_HERE` with the actual domain (e.g., `yonklabs.com`):

```
yonklabs.com
```

- [ ] **Step 3: Update `config/_default/hugo.toml` baseURL**

```toml
baseURL = "https://yonklabs.com/"
```

- [ ] **Step 4: Commit and push**

```bash
git add static/CNAME config/_default/hugo.toml
git commit -m "feat: configure custom domain"
git push
```

- [ ] **Step 5: Configure DNS (user action)**

The user needs to add these records at their DNS provider:

**Option A — Apex domain (e.g., `yonklabs.com`):**
```
A     @    185.199.108.153
A     @    185.199.109.153
A     @    185.199.110.153
A     @    185.199.111.153
CNAME www  yonk-labs.github.io.
```

**Option B — Subdomain (e.g., `www.yonklabs.com`):**
```
CNAME www  yonk-labs.github.io.
```

- [ ] **Step 6: Enable HTTPS in GitHub Pages settings**

```bash
gh api repos/yonk-labs/yonk-labs.github.io/pages -X PUT -f cname="DOMAIN_HERE" -F https_enforced=true
```

GitHub auto-provisions a Let's Encrypt certificate. May take a few minutes.
