# skills

My personal collection of [agent skills](https://agentskills.io) for Claude Code and other skills-compatible agents.

## Install

Globally (available in every project):

```bash
npx skills add rogeriochaves/skills -g
```

Into the current project only:

```bash
npx skills add rogeriochaves/skills
```

A single skill:

```bash
npx skills add rogeriochaves/skills --skill orchestrate -g
```

List what's in here without installing:

```bash
npx skills add rogeriochaves/skills --list
```

## Skills

| Skill | Description |
| --- | --- |
| [`orchestrate`](skills/orchestrate/SKILL.md) | Disciplined delivery loop: BDD specs → real integration tests (no mocks) → PR + CI/CodeRabbit babysitting → mandatory end-user QA via computer-use or CLI dogfooding before anything is called done. |

## Contributing (and live-editing locally)

Every skill lives at `skills/<name>/SKILL.md` and follows the [Agent Skills specification](https://agentskills.io/specification) — YAML frontmatter (`name`, `description`) followed by the instructions the agent loads when the skill activates.

For my own setup I don't want `npx skills add` because it copies files to `~/.agents/skills/` — edits to this repo wouldn't flow through until I reinstall. Instead I symlink each skill directory straight into `~/.claude/skills/` so changes here are picked up by every Claude Code session immediately:

```bash
git clone git@github.com:rogeriochaves/skills.git ~/Projects/skills
ln -s ~/Projects/skills/skills/orchestrate ~/.claude/skills/orchestrate
```

Repeat the `ln -s` line for each new skill. Verify with `ls -la ~/.claude/skills/`.
