---
name: drive-pr
description: Drive a PR to mergeable state — check CodeRabbit and reviewer comments, address valid ones, reply and resolve invalid ones, fix CI failures (even pre-existing ones from main), push fixes, then loop every 4.5 minutes until two consecutive clean checks. Use after opening a PR when you want it babysitted to green.
---

Can you now check the PR for coderabbit or other comments, check if they are valid and address them, if valid then do the fix and push, if not then reply to the comment and mark it as resolved

Also check the CI jobs, fix any failures, if failures are like unit, lint, typecheck or even integration, try running it locally to make sure its fixed first before pushing and waiting again on the CI

If a failure is pre-existing on main and not related to our code, it doesn't matter, fix it all the same, unless you're spending too much time trying to fix it and the scope creep would be too large, just fix it, a good boy scout always leaves the place cleaner than they found

Then, after any push, wait 4.5 min (just below your cache expiration) and check for new comments by coderabbit or CI issues to be addressed, if nothing new twice, then just relax
