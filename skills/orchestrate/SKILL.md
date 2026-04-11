---
name: orchestrate
description: Loads orchestrate mode — a disciplined delivery loop that enforces BDD specs in specs/, real integration tests (no mocks), PR CI and CodeRabbit babysitting, and mandatory end-user QA via computer-use or CLI dogfooding before anything is considered done. Use when starting any non-trivial implementation task, feature build, or delivery where you want the work driven from spec to proven-shipped state rather than stopping at "tests pass".
---

This skill loads orchestrate mode to guide you on the loop you are in

If you are on plan mode just plan like you normally would, if not, still do a plan for yourself, but regardless, the very first task of the plan should always be to write/update BDD specs on specs/

There should always be a specs/ folder at the root of the project for all the requirements and expected behaviors of the entire application on .feature files, which should always be kept up to date, with subfolders as the project get big.

Then, as you start the implementation, every implementation task should be intertwined with tests, most importantly actual integration tests, really proving everything works, no mocks. If it’s for the backend then it should really talk all the way to the database, no mocking, if it’s frontend, then react-testing-library tests should be used, really rendering that whole component tree, no shallow no mocks, and if it’s an agent, then it should use LangWatch scenario tests to prove the behaviour

Once you have something mostly done all tests passing all typechecks, you can open a PR to run the CI and get automated code reviews from coderabbit and so on which you should verify around every 5 minute again after having open the PR and pushed fixes and see if there is anything to address/reply why not valid

Then when you think you are done with the implementation, stop, you are NOT done until you’ve done QA ad-nauseum, it doesn’t matter how much green the tests are, you need to dogfood your work as a real user would, if you haven’t used it yourself, it’s the same as nothing.

So if the work at hand is something that can be accessed through the frontend at all, use computer use + Claude in chrome to really access the screen, navigate, see if everything works, evaluate the UX experience, the UI, look for edge cases and so on, if not, if it’s the CLI or so, still use it like a real user, build example applications to test it, use it for real from every way and angle, perfect the experience,m, do not worry about making the PR big

Do not save any screenshots to the repo except if for docs, put on a .claude or temp folder instead, and use the service https://img402.dev/ (`curl -F image=@screenshot.png https://img402.dev/api/free`) to upload it for the pull request

Only really say done after you have QAed, took screenshots, babysitted the PR for CI and coderabbit comments, added user docs for all of it as needed, then even so think again what haven’t you QAed, and open the screen and QA again, until really done, proved and proved again

If what you are doing is some kinda of small internal task and what I’m saying about QAing doesn’t make sense, still think how would the principle adapt to your context, really proving the delivery in a great shape.
