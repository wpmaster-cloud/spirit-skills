---
name: skill-creator
description: Create new skills and improve existing ones. Use when the user wants to create a skill from scratch, turn a workflow they just did into a reusable skill, edit or improve an existing skill, or sharpen a skill's description so it triggers at the right moments.
---

# Skill Creator

A skill for creating new skills and iteratively improving them.

At a high level, the process of creating a skill goes like this:

- Decide what you want the skill to do and roughly how it should do it
- Write a draft of the skill
- Try it on a couple of realistic test prompts — ideally on a fresh subagent that
  has the skill, compared against one that doesn't (see *Testing a skill*)
- Rewrite the skill based on what actually happened
- Repeat until you're satisfied

Your job when using this skill is to figure out where the user is in this process and then jump in and help them progress through these stages. So for instance, maybe they're like "I want to make a skill for X". You can help narrow down what they mean, write a draft, write the test cases, try them, and repeat.

On the other hand, maybe they already have a draft of the skill. In this case you can go straight to the test/iterate part of the loop.

Of course, you should always be flexible and if the user is like "I don't need to run a bunch of tests, just vibe with me", you can do that instead.

**Know where a skill lives.** A skill you write into your own `skills/<name>/`
works for *you* immediately — that is the fast loop, and it's where you should
iterate. Publishing it to the **shared catalog** (so other agents can
`curl "$RESOURCES_URL/skills/<name>/download"` it) means getting it into the
skills repo the resources server bakes in — that's the operator's move, not
something you can do from here. Say so when you hand a skill over; it is not
live for anyone else until then.

Cool? Cool.

## Communicating with the user

The skill creator is liable to be used by people across a wide range of familiarity with coding jargon. If you haven't heard (and how could you, it's only very recently that it started), there's a trend now where the power of Claude is inspiring plumbers to open up their terminals, parents and grandparents to google "how to install npm". On the other hand, the bulk of users are probably fairly computer-literate.

So please pay attention to context cues to understand how to phrase your communication! In the default case, just to give you some idea:

- "evaluation" and "benchmark" are borderline, but OK
- for "JSON" and "assertion" you want to see serious cues from the user that they know what those things are before using them without explaining them

It's OK to briefly explain terms if you're in doubt, and feel free to clarify terms with a short definition if you're unsure if the user will get it.

---

## Creating a skill

### Capture Intent

Start by understanding the user's intent. The current conversation might already contain a workflow the user wants to capture (e.g., they say "turn this into a skill"). If so, extract answers from the conversation history first — the tools used, the sequence of steps, corrections the user made, input/output formats observed. The user may need to fill the gaps, and should confirm before proceeding to the next step.

1. What should this skill enable Claude to do?
2. When should this skill trigger? (what user phrases/contexts)
3. What's the expected output format?
4. Should we set up test cases to verify the skill works? Skills with objectively verifiable outputs (file transforms, data extraction, code generation, fixed workflow steps) benefit from test cases. Skills with subjective outputs (writing style, art) often don't need them. Suggest the appropriate default based on the skill type, but let the user decide.

### Interview and Research

Proactively ask questions about edge cases, input/output formats, example files, success criteria, and dependencies. Wait to write test prompts until you've got this part ironed out.

Check available MCPs - if useful for research (searching docs, finding similar skills, looking up best practices), research in parallel via subagents if available, otherwise inline. Come prepared with context to reduce burden on the user.

### Write the SKILL.md

Based on the user interview, fill in these components:

- **name**: Skill identifier
- **description**: When to trigger, what it does. This is the primary triggering mechanism - include both what the skill does AND specific contexts for when to use it. All "when to use" info goes here, not in the body. Note: currently Claude has a tendency to "undertrigger" skills -- to not use them when they'd be useful. To combat this, please make the skill descriptions a little bit "pushy". So for instance, instead of "How to build a simple fast dashboard to display internal Anthropic data.", you might write "How to build a simple fast dashboard to display internal Anthropic data. Make sure to use this skill whenever the user mentions dashboards, data visualization, internal metrics, or wants to display any kind of company data, even if they don't explicitly ask for a 'dashboard.'"
- **compatibility**: Required tools, dependencies (optional, rarely needed)
- **the rest of the skill :)**

### Skill Writing Guide

#### Anatomy of a Skill

```
skill-name/
├── SKILL.md (required)
│   ├── YAML frontmatter (name, description required)
│   └── Markdown instructions
└── Bundled Resources (optional)
    ├── scripts/    - Executable code for deterministic/repetitive tasks
    ├── references/ - Docs loaded into context as needed
    └── assets/     - Files used in output (templates, icons, fonts)
```

#### Progressive Disclosure

Skills use a three-level loading system:
1. **Metadata** (name + description) - Always in context (~100 words)
2. **SKILL.md body** - In context whenever skill triggers (<500 lines ideal)
3. **Bundled resources** - As needed (unlimited, scripts can execute without loading)

These word counts are approximate and you can feel free to go longer if needed.

**Key patterns:**
- Keep SKILL.md under 500 lines; if you're approaching this limit, add an additional layer of hierarchy along with clear pointers about where the model using the skill should go next to follow up.
- Reference files clearly from SKILL.md with guidance on when to read them
- For large reference files (>300 lines), include a table of contents

**Domain organization**: When a skill supports multiple domains/frameworks, organize by variant:
```
cloud-deploy/
├── SKILL.md (workflow + selection)
└── references/
    ├── aws.md
    ├── gcp.md
    └── azure.md
```
Claude reads only the relevant reference file.

#### Principle of Lack of Surprise

This goes without saying, but skills must not contain malware, exploit code, or any content that could compromise system security. A skill's contents should not surprise the user in their intent if described. Don't go along with requests to create misleading skills or skills designed to facilitate unauthorized access, data exfiltration, or other malicious activities. Things like a "roleplay as an XYZ" are OK though.

#### Writing Patterns

Prefer using the imperative form in instructions.

**Defining output formats** - You can do it like this:
```markdown
## Report structure
ALWAYS use this exact template:
# [Title]
## Executive summary
## Key findings
## Recommendations
```

**Examples pattern** - It's useful to include examples. You can format them like this (but if "Input" and "Output" are in the examples you might want to deviate a little):
```markdown
## Commit message format
**Example 1:**
Input: Added user authentication with JWT tokens
Output: feat(auth): implement JWT-based authentication
```

### Writing Style

Try to explain to the model why things are important in lieu of heavy-handed musty MUSTs. Use theory of mind and try to make the skill general and not super-narrow to specific examples. Start by writing a draft and then look at it with fresh eyes and improve it.

### Test Cases

After writing the skill draft, come up with 2-3 realistic test prompts — the kind of thing a real user would actually say. Share them with the user: [you don't have to use this exact language] "Here are a few test cases I'd like to try. Do these look right, or do you want to add more?" Then run them.

Save test cases to `evals/evals.json`. Don't write assertions yet — just the prompts. You'll draft assertions in the next step while the runs are in progress.

```json
{
  "skill_name": "example-skill",
  "evals": [
    {
      "id": 1,
      "prompt": "User's task prompt",
      "expected_output": "Description of expected result",
      "files": []
    }
  ]
}
```

See `references/schemas.md` for the full schema (including the `assertions` field, which you'll add later).

## Testing a skill

You cannot spawn Claude Code subagents or open a browser-based review viewer
here — but you *can* do the thing that actually matters: **run a fresh agent on
a realistic prompt, with and without the skill, and read what it did.**

A fresh agent is just a folder (see the `agent-workshop` skill). The comparison
is the whole point: a skill that doesn't beat the baseline isn't earning its
place in the catalog.

```bash
# One test agent, WITH the skill.
name=eval-with
mkdir -p "$name"/_sessions "$name"/_logs
cp agent.sh "$name/agent.sh" && chmod +x "$name/agent.sh"
mkdir -p "$name/skills" && cp -R "skills/<skill-name>" "$name/skills/"

jq -Rsc --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{kind:"message", created_at:$t, role:"system", content:.}' \
  > "$name/_sessions/session.jsonl" <<'SEED'
You are a test agent. Your only tool is run_command (bash, from this folder).
Read skills/<skill-name>/SKILL.md and follow it when it applies to the task.
Do the task, then report what you did in one short paragraph.
SEED

# Run it detached — SESSION_FILE is mandatory (a bare run forks a ghost session).
cd "$name" && SESSION_FILE=_sessions/session.jsonl ./agent.sh -d "<the test prompt>"
```

Repeat with a `eval-without` agent that has **no** `skills/` dir and a seed that
doesn't mention the skill. Same prompt, same model. Then read both:

```bash
tail -n 60 eval-with/_logs/agent.log
tail -n 60 eval-without/_logs/agent.log
diff <(ls -R eval-without) <(ls -R eval-with)   # what did each actually produce?
```

What you are looking for:

- **Did it trigger?** If the with-skill agent ignored the SKILL.md, the
  `description` is the problem, not the body. That is the single most common
  failure and the cheapest to fix.
- **Did it help?** Compare the outputs, not the vibes. If the baseline did just
  as well, the skill is ceremony — cut it or sharpen it to the part that helped.
- **Did it repeat work?** If both runs hand-rolled the same helper script, that
  script belongs in the skill's `scripts/`. Write it once so no future
  invocation reinvents it.

Delete the test agents when you're done (`rm -rf eval-with eval-without`) — they
are scratch, and a stray agent folder with `agent: true` shows up in the app.

Keep the loop cheap: 2–3 realistic prompts, read the logs, fix the skill, repeat.
Resist building a benchmark harness; the reading is where the signal is.

## Validate and package

Two bundled scripts run standalone here:

```bash
python3 scripts/quick_validate.py <skill-path>    # frontmatter + structure sanity
python3 scripts/package_skill.py <skill-path>     # bundle it up for handoff
```

> The other scripts (`run_eval.py`, `run_loop.py`, `improve_description.py`) and
> the `eval-viewer/` + `agents/` directories drive the **Claude Code** harness —
> they shell out to the `claude` CLI and expect a `.claude/` project root, neither
> of which exists in this runtime. Ignore them here; use the loop above instead.

## Reference files

- `references/schemas.md` — JSON structures for `evals.json` and friends (useful
  if you keep test prompts on disk; the grading half assumes the Claude Code harness).

---

Repeating the core loop one more time for emphasis:

- Figure out what the skill is about
- Draft or edit the skill
- Run a fresh agent on 2–3 test prompts, with and without the skill
- Read what each one actually did, and fix the skill accordingly
- Repeat until you and the user are satisfied
- Hand it over — and say plainly that the shared catalog needs the operator to
  publish it before any other agent can fetch it.

Good luck!
