---
name: browser-qa
description: Drive a real browser to QA a feature end-to-end as a user would. Loads the right mix of Playwright MCP, Claude-in-Chrome, and computer-use, plus the failure modes to avoid. Use whenever you need to verify a UI feature works in a browser, capture PR screenshots, repro a customer bug visually, or do end-of-task dogfooding before declaring something "done". This is the QA stage of orchestrate mode.
---

# Browser QA

You're about to drive a real browser to verify a feature. This skill exists because there are three browser stacks available (Playwright MCP, Claude-in-Chrome MCP, computer-use MCP), they have very different failure modes, and picking the wrong one for the wrong stage of work burns wall clock for no reason.

## First-time setup — DO THIS BEFORE ANYTHING ELSE

You will be blocked mid-task if you wait until you need a permission to ask for it. Ask for everything up front, in parallel, in the very first message of the QA phase:

1. **Request computer-use access for Chrome** by calling `mcp__computer-use__request_access` with `apps: ["Google Chrome"]` and a one-sentence reason. Chrome is a tier-"read" app — you'll be able to take screenshots through the OS compositor but not click. That's exactly what you want: real-Chrome screenshots without having to fight focus.
2. **Verify the Claude-in-Chrome extension is connected** by calling `mcp__claude-in-chrome__tabs_context_mcp` with `createIfEmpty: true`. If this returns an error, the extension isn't installed/enabled — stop and ask the user to install it rather than falling back to a worse stack.
3. **Verify Playwright MCP works** by calling `mcp__playwright__browser_close` once (no-op if no tab; surfaces "browser already in use" lock errors early so you can `pkill -f "mcp-chrome-"` before they bite you mid-task).

Do all three in parallel in one message. If anything is missing, surface it immediately — don't start QA half-blind.

## When to use which stack

**Use Playwright MCP for iterative dev-loop QA** — every "did this fix work?" check while you're still building. Reasons: snapshot-aware `wait_for`, fast happy paths (~10 s for a navigate + click + screenshot), failures are at the prompt layer (wrong URL, short wait threshold) and recoverable by retrying smarter. Headless Chromium screenshots are dense, clinical, and ideal for "is the UI correct?" reviews.

**Use Claude-in-Chrome + computer-use for end-of-task artefacts** — PR screenshots, demo GIFs, customer bug repros. Reasons: the captured surface is the *real* Chrome the user sees (tab strip, profile avatar, extensions, DEV stripe, the "Claude is active in this tab group" pill). That matches reviewer expectations. Don't use it for the inner dev loop — it's slower and has runtime-layer failures you can't fix from a prompt.

**Use computer-use directly only for native desktop apps** — anything that isn't a web app. For browsers, prefer the dedicated MCPs above; computer-use's role in browser QA is just the screenshot grab on top of CiC.

## Failure modes by stack (so you don't relearn them)

**Playwright MCP failures — all fixable from your side:**
- Stale browser lock from a previous session — `pkill -f "mcp-chrome-"` then retry.
- 404s from guessing URL paths — read the project's routing config (Next.js `pages/`/`app/`, React Router, file-based routers, etc.) before navigating. Don't assume the URL pattern from the feature name.
- `browser_take_screenshot` rejects subdir paths and `/tmp/` ("outside allowed roots") — use a flat filename in cwd, then `mv` it after.
- `wait_for` text undershoots portal-based components (Radix, Headless UI, Chakra v3, MUI Modal). Wait for the *content* of the portal (e.g. a field label, a heading inside the dialog), not the trigger that opened it.
- Clicking visible text via `evaluate` often doesn't trigger the right handler. Many component libraries (Chakra, Radix, shadcn/ui, MUI) attach click handlers to inner elements like a `<button>` or an icon trigger, not to the table row or list item the user *visually* sees. Walk up/down the DOM to find the actual interactive element — usually a `<button>` or `[role="button"]` — and click that.
- Cookie set in `evaluate` may be lost across navigations. If your app redirects unauthenticated requests, navigate first to a *non-redirecting* endpoint (a static asset, a JSON API route, anything that returns 200 without bouncing), set the cookie there, then navigate to the target.

**Claude-in-Chrome failures — runtime-layer, harder to recover:**
- **Backgrounded-tab throttling.** Chrome aggressively pauses background tabs. If your CiC tab isn't the foreground tab in the user's Chrome window, React/Next will not hydrate, `document.querySelectorAll('p').length` will sit at 0, and your polling JS will return `{ timeout: true }` indefinitely. Once stuck, the next `javascript_tool` call typically hits a 45 s CDP `Runtime.evaluate` timeout. Mitigation: take a screenshot via `mcp__claude-in-chrome__computer` action `screenshot` *before* you start polling — that brings the tab to the front. Or open the LangWatch tab in its own Chrome window the user has visible.
- **Content filter redacts page text.** `document.body.innerText` and `outerHTML` come back as `[BLOCKED: Cookie/query string data]` when the page contains anything that looks like session state. Use targeted `querySelectorAll` checks instead (`Array.from(document.querySelectorAll('p')).some(p => p.innerText === 'X')`).
- **Cookie reads blocked, cookie writes work.** Don't try to read `document.cookie` to verify auth. Instead `fetch('/api/auth/session').then(r => r.json())` and check `user.email`.
- **Query-string URLs sometimes fail to render.** Direct navigation to `?drawer.open=...` URLs occasionally drops the query string. Click through the UI flow instead.
- **Distorted/blank screenshots.** When the viewport hasn't been laid out (because the tab was throttled), `computer-use__screenshot` returns a blank gradient. If that happens, the tab is frozen — re-navigate, don't retry the screenshot.
- **First screenshot of a fresh CiC session shows loading spinners.** The polling loop fires before tRPC queries resolve. Wait for actual content (e.g. a row label), not just `document.title`.

## Performance expectations

From a 3-runs-each benchmark on a real "settings → open drawer → screenshot" QA flow:

| Stack       | Happy path  | Worst observed | Failure modes |
|-------------|------------:|---------------:|---------------|
| Playwright  | ~12 s       | ~60 s (debug)  | Prompt-layer, retryable |
| CiC + CU    | ~9 s warm   | ~280 s frozen  | Runtime-layer, sometimes terminal |

Tool-call counts are identical on the happy path (8–9 calls). The difference is what each call returns and how often the runtime hangs. CiC's *warm* happy path is faster than PW's, but its tail is much worse — one CDP timeout costs you 45 s.

## The QA flow itself

1. **Pick a dev server port that isn't fighting other agents or hard-coded auth callbacks.** If the project uses an external auth provider (Auth0, Clerk, NextAuth with OAuth, Supabase, Cognito, etc.), pick a port that's already in the callback allowlist — making up an arbitrary port will silently fail the redirect. Otherwise, pick something out of the way (e.g. high four-digit) so you don't collide with whatever else the user has running.
2. **Seed test data via a script, not the UI.** Write a small setup script that creates whatever rows you need (user, session token, sample records) directly via the project's DB client, ORM, or seed mechanism. Faster than clicking through onboarding, repeatable across runs, and survives session expiry mid-task.
3. **For Playwright runs:** navigate → `wait_for` actual content → click → `wait_for` next content → screenshot. Always wait for *something the user would see*, not just `document.readyState`.
4. **For CiC runs:** `tabs_context_mcp` → `tabs_create_mcp` → `navigate` → take a screenshot immediately to defeat background-tab throttling → poll for content → click → poll for next content → screenshot.
5. **Take screenshots at the moments a reviewer would care about** — initial state, mid-flow, final state. Three is usually enough; ten is noise.
6. **Verify the feature, then verify the unhappy paths.** "Happy path works" *and* "the obvious error case shows a clear message" *and* "form validation rejects bad input". The bug is almost always in the path you didn't QA.
7. **Don't claim the feature works until you saw it work in a browser screenshot.** Tests passing is necessary, not sufficient.

## Screenshot handling — MANDATORY

**Screenshots are not optional.** Every QA session must produce screenshots uploaded to the PR. A PR reported as "ready" without embedded screenshots is incomplete — go back and take them. Do this DURING QA, not as an afterthought.

- **Never commit screenshots to the working repo** unless they're explicitly user-facing docs assets. Put them in `.claude/`, `bench/`, or another gitignored location.
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
- **The screenshots are pushed to `langwatch/pr-screenshots` and embedded in the PR body** (not just taken locally — actually in the PR description right now).
- I noticed at least one rough UX edge during QA and either fixed it or filed it.

If you can't say yes to all of those, you haven't QA'd yet — you've smoke-tested. Go back and use the feature.

**HARD GATE:** Do not report "all CI green, PR ready" without screenshots in the PR. Screenshots first, then status report.
