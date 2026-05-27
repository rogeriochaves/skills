---
name: browser-qa
description: Drive a real browser to QA a feature end-to-end as a user would. Loads the Playwright MCP playbook plus the failure modes to avoid. Use whenever you need to verify a UI feature works in a browser, capture PR screenshots, repro a customer bug visually, or do end-of-task dogfooding before declaring something "done". This is the QA stage of orchestrate mode.
---

# Browser QA

You're about to drive a real browser to verify a feature. **Use Playwright MCP.** It's the only browser stack that pays off in practice — fast, scriptable, snapshot-aware, and failures are at the prompt layer so you can recover with smarter retries instead of restarting the runtime.

## First-time setup — DO THIS BEFORE ANYTHING ELSE

You will be blocked mid-task if you wait until you need a permission to ask for it. Surface anything missing in the very first message of the QA phase:

1. **Verify Playwright MCP works** by calling `mcp__playwright__browser_close` once. It's a no-op if there's no open tab, and surfaces "browser already in use" lock errors early so you can `pkill -f "mcp-chrome-"` before they bite you mid-task.
2. **Confirm your dev server is up.** A quick `curl -s -o /dev/null -w "%{http_code}\n" http://localhost:<port>/` saves a "Page Title: ECONNREFUSED" round-trip.

If anything is missing, surface it immediately — don't start QA half-blind.

> **Why Playwright?** It's fast, scriptable, and snapshot-aware, and its failures surface at the prompt layer so you can recover with smarter retries instead of restarting the runtime. Headless screenshots are dense and clinical, which is exactly what a reviewer wants. Stick to one stack and learn its sharp edges.

## Playwright MCP failure modes — all fixable from your side

- **Stale browser lock from a previous session.** `pkill -f "mcp-chrome-"` then retry.
- **404s from guessing URL paths.** Read the project's routing config (Next.js `pages/`/`app/`, Vite `routes.tsx`, React Router, file-based routers, etc.) before navigating. Don't assume the URL pattern from the feature name.
- **`browser_take_screenshot` "outside allowed roots" error.** The screenshot tool only writes inside its sandbox — usually `<cwd>` and `<cwd>/.playwright-mcp`. You **cannot** save directly to `~/Projects/pr-screenshots` or `/tmp`. Pass a *flat filename* (e.g. `drawer-light.png`) and the file lands in the worktree root; copy from there to the pr-screenshots clone afterwards. Don't burn cycles searching the filesystem for where the screenshot went — it's in `<cwd>` (or its `.playwright-mcp` subdir if you used a relative path with a slash).
- **`wait_for` text undershoots portal-based components** (Radix, Headless UI, Chakra v3, MUI Modal). Wait for the *content* of the portal (a field label, a heading inside the dialog), not the trigger that opened it.
- **Clicking visible text via `evaluate` often doesn't trigger the right handler.** Many component libraries (Chakra, Radix, shadcn/ui, MUI) attach click handlers to inner elements like a `<button>` or icon trigger, not the row or list item the user *visually* sees. Walk up/down the DOM to find the actual interactive element — usually a `<button>` or `[role="button"]` — and click that.
- **Cookie set in `evaluate` may be lost across navigations.** If your app redirects unauthenticated requests, navigate first to a *non-redirecting* endpoint (a static asset, a JSON API route, anything that returns 200 without bouncing), set the cookie there, then navigate to the target.
- **Color-mode (theme) toggling can't be done by writing localStorage + flipping a class.** Theme providers (`next-themes`, Chakra `ColorModeProvider`, etc.) read their state through React on mount — flipping the DOM directly after the page has hydrated does nothing to the rendered tree. Either:
  - Click the theme toggle button via `browser_click` (most reliable), or
  - Set the storage key *before* navigation, then reload — the provider re-hydrates from storage on mount.
  Take a screenshot to confirm the mode actually changed before assuming.
- **Modal/drawer over the toggle.** If you're trying to click a chrome control while a drawer/dialog is open, the dialog backdrop intercepts the click. Close the dialog first (Esc, X, or the store-level close call) before reaching for global UI.
- **Don't poll the filesystem for screenshot paths.** Playwright's response confirms `path: './<filename>.png'` — that's the truth. If you can't see the file, the working directory isn't where you think it is (`pwd` once, don't search).

## Performance expectations

On a real "settings → open drawer → screenshot" QA flow:

| Stack       | Happy path  | Worst observed | Failure modes |
|-------------|------------:|---------------:|---------------|
| Playwright  | ~12 s       | ~60 s (debug)  | Prompt-layer, retryable |

Tool-call counts are usually 8–9 for a single screenshot flow. Multi-state captures (light + dark, narrow + wide) batch nicely — flip viewport, take shot, repeat.

## The QA flow itself

1. **Pick a dev server port that isn't fighting other agents or hard-coded auth callbacks.** If the project uses an external auth provider (Auth0, Clerk, NextAuth with OAuth, Supabase, Cognito, etc.), pick a port that's already in the callback allowlist — making up an arbitrary port will silently fail the redirect. Otherwise, pick something out of the way (e.g. high four-digit) so you don't collide with whatever else the user has running.
2. **Seed test data via a script, not the UI.** Write a small setup script that creates whatever rows you need (user, session token, sample records) directly via the project's DB client, ORM, or seed mechanism. Faster than clicking through onboarding, repeatable across runs, and survives session expiry mid-task.
3. **Navigate → `wait_for` actual content → click → `wait_for` next content → screenshot.** Always wait for *something the user would see*, not just `document.readyState`.
4. **Take screenshots at the moments a reviewer would care about** — initial state, mid-flow, final state. For UI revamps: capture *both color modes* (light + dark) and *both layout breakpoints* (e.g., narrow vs wide). Three to six shots is usually enough; ten is noise.
5. **Verify the feature, then verify the unhappy paths.** "Happy path works" *and* "the obvious error case shows a clear message" *and* "form validation rejects bad input". The bug is almost always in the path you didn't QA.
6. **Don't claim the feature works until you saw it work in a browser screenshot.** Tests passing is necessary, not sufficient.

## Screenshot handling — MANDATORY

**Screenshots are not optional.** Every QA session must produce screenshots uploaded to the PR. A PR reported as "ready" without embedded screenshots is incomplete — go back and take them. Do this DURING QA, not as an afterthought.

- **Never commit screenshots to the working repo** unless they're explicitly user-facing docs assets. Put them in `.claude/`, `bench/`, or another gitignored location. (If you accidentally `git add -A` and a screenshot lands in a commit, amend it out before pushing.)
- **Publish via `langwatch/pr-screenshots`** (cloned at `~/Projects/pr-screenshots`):
  ```bash
  cd ~/Projects/pr-screenshots && git pull --rebase
  cp /path/to/shot.png pr-<PR#>/<section>/<name>.png
  git add . && git commit -m "pr-<PR#>: <what>" && git push origin main
  ```
  The raw URL is `https://raw.githubusercontent.com/langwatch/pr-screenshots/main/pr-<PR#>/<section>/<name>.png`.
- **Embed the raw URLs in the PR description** before reporting the PR as ready. Not as committed files, not as a comment — in the PR body itself.

## Ending the QA phase

You are done with browser QA when you can answer all of these "yes":

- I navigated through the feature like a user would, not just to the screen that proves my code path runs.
- I tried the unhappy paths (missing config, bad input, network failure simulation if relevant).
- I have screenshots of the happy path *and* the most important edge case.
- For UI work: screenshots in both color modes and (where the layout adapts) both breakpoints.
- **The screenshots are pushed to `langwatch/pr-screenshots` and embedded in the PR body** (not just taken locally — actually in the PR description right now).
- I noticed at least one rough UX edge during QA and either fixed it or filed it.

If you can't say yes to all of those, you haven't QA'd yet — you've smoke-tested. Go back and use the feature.

**HARD GATE:** Do not report "all CI green, PR ready" without screenshots in the PR. Screenshots first, then status report.
