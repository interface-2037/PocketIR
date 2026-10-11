# Publishing the core

The [openFPGA Library](https://openfpga-library.github.io/analogue-pocket/) lists cores from a **public GitHub repo** and picks up the zip attached to its latest **GitHub release**. It's set up once, then each new version is just a new release.

## One-time setup

### 1. Create the empty repo on GitHub
1. Sign in at github.com, click **+** (top right) → **New repository**.
2. Name: `PocketIR`. Visibility: **Public**.
3. Leave **all** "Initialize" options off (no README, no .gitignore, no license). The repo must be empty or the first push is rejected.
4. Click **Create repository** and copy the URL, e.g. `https://github.com/<you>/PocketIR.git`.

### 2. Push the code (PowerShell, in the PocketIR folder)
```
git branch -M main
git remote add origin https://github.com/<you>/PocketIR.git
git push -u origin main
```
- `branch -M main` renames the local branch from `master` to `main`.
- `remote add` tells git where GitHub is; `push -u` uploads and remembers the link.
- A browser window may open to sign in to GitHub (Git Credential Manager). That's expected.
- If the push is refused with **"push declined due to email privacy restrictions"**: your commits carry your real email. Either untick *Settings → Emails → Block command line pushes that expose my email* on GitHub, or ask Claude to rewrite the author email to your GitHub `noreply` address before pushing.

### 3. Add the GPL-3.0 license on GitHub
1. On the repo page: **Add file → Create new file**, type the name `LICENSE`.
2. Click **Choose a license template** → **GNU General Public License v3.0** → **Review and submit** → **Commit changes**.
3. Bring that commit back to your PC: `git pull`

### 4. Submit to the library (once)
1. Make the first release (below) first, so the library has something to download.
2. Open https://github.com/openfpga-library/analogue-pocket/issues/new/choose → **Add Core**.
3. **GitHub Repository:** `<you>/PocketIR`. Leave *Asset Filter* and *Path* empty (each release has one zip).
4. Submit. The maintainers review it; it appears on the site after they accept it.

## Every release

1. Bump `version` and `date_release` in `core.json`, build (`tools\build.ps1`) and package (`python tools/package_core.py`). Test on the Pocket.
2. Commit and `git push`.
3. On GitHub: **Releases → Draft a new release**.
   - **Choose a tag** → type `v0.11.0` (the version) → *Create new tag on publish*.
   - Title: `v0.11.0`. Notes: what changed and what was tested on hardware.
   - Drag in **one** zip: `build/interface2037.PocketIR_<version>_<date>.zip`. One zip only, or the library needs an Asset Filter.
   - **Publish release**. The library picks it up automatically.
