# GitHub Pages landing page

The static landing page lives in `site/`. The workflow at
`.github/workflows/pages.yml` uploads that directory and deploys it with GitHub
Pages whenever `site/` or the workflow changes on `main`. It can also be run
manually.

## Enable Pages for this repository

1. Commit and push `site/` and `.github/workflows/pages.yml` to `main`.
2. Open <https://github.com/peteriz/mancia/settings/pages>.
3. Under **Build and deployment**, set **Source** to **GitHub Actions**.
4. Open the repository's **Actions** tab and select
   **Deploy landing page to GitHub Pages**.
5. If it did not start after the push, choose **Run workflow** and run it from
   `main`.

After the deployment succeeds, the site is available at:

<https://peteriz.github.io/mancia/>

The workflow publishes only `site/`. The `.nojekyll` file keeps GitHub Pages
from applying Jekyll processing to the static artifact.
