# Compounding agent value: what exists, what was added, who owns what

Written 2026-11-23 for the brief "Build compounding agent value across
321 and 123.do". The principle: a model contributes to a job; the agent
keeps useful skills and experience, and the organisation keeps its
project knowledge and evidence, so a later job benefits even on another
model or harness. 321 is the durable layer where that compounds.

## Who owns what

| Party | Owns | Never |
|---|---|---|
| 123.do (api.123.do, d1on) | Tracks, Steps, Entries, the person's verdict on a result, which actor gets a Step | runs code, marks a Step done on a receipt alone |
| 321 runtime (cli.321.do) | running an agent from a sealed package, enforcing grants, receipts, cost with its basis, local lessons, outcomes, evidence, value | grants anything from a lesson, rewrites a receipt |
| Registry (agents.321.do) | agent identity, skills with versions, organisation contexts and their lessons, outcome reports | decides keep or revert for a person |
| The project's repository | project lessons (`.321/lessons/`), shared on purpose and merged by people | |
| IZ4 | promises and checks | is changed by learning |

## What already existed (verified in code)

- Receipts with cost basis, attempts, tokens, plan (model, harness, effort, reasons), signatures: `schemas/run-receipt.v1.json`, `lib/Do321/Run.rakumod`.
- Lessons with scope (agent, context, skill, harness, project) and states trial/kept/reverted; outcomes beside receipts; with/without comparison; value report with honest savings (baseline required, three accepted runs minimum): `lib/Do321/Learn.rakumod`, `321 lessons`, `321 outcome`, `321 value`.
- Curation of model size and effort from comparable judged runs, with reasons on the receipt: `lib/Do321/Curate.rakumod`.
- Registry lessons per organisation context, pulled by 321 and by api.123.do (cached in `registry_lesson_cache`, served into 123.do packages as `context.lines`, ids kept as `actions.context.lessonsGiven`).
- Opt-in outcome reports to the registry (`321 record share`).

## What was missing

1. Nothing turned an outcome into a lesson: every lesson was typed by hand.
2. Nothing acted on evidence: keep and revert were only a person's acts, so a lesson nobody looked at stayed on trial for ever, helping or not.
3. 123.do verdicts (approve or decline of a packaged result) never reached the 321 that ran the work, so 321's outcomes, evidence and value had no data from 123.do work.
4. A correction a person made in 123.do never became a lesson anywhere, so the next package for that agent in that Track carried nothing learnt.

## The slices

| # | Slice | Where | Status |
|---|---|---|---|
| 1 | A correction with words becomes one lesson on trial for that agent on any harness; judged runs keep or revert lessons no person decided | cli.321.do | built, tested (`t/44-compounding.rakutest`) |
| 2 | 123.do serves an agent the verdicts on its runs (`GET /me/get-run-outcomes`); the 123 worker says each new one to its 321 as `321 outcome RUN WORD [WORDS]` under `DO_321_OUTCOME_BY` | api.123.do (`Engine::RunOutcomes`), tui.123.do (`say-outcomes`, `launcher-outcome`) | built, tested (`t/integration/179`, `t/52-outcomes.rakutest`) |
| 3 | A person's decline with words in a configured Track is taught to the registry as a trial lesson for that agent and context, key-shaped strings redacted, so the next package there carries it | api.123.do (`Engine::Lessons::report_to_registry`, migration 99) | built, tested against a stubbed registry (`t/integration/180`) |
| 5 | Each steer a person had to give a run while it went on becomes one lesson on trial for that agent (on any verdict; the same words again are the same lesson), and each outcome records steers and answered questions, so `321 value` says how often a person stepped in | cli.321.do (`propose-from-steers`, `driven-of`, `321 outcome --steer --answered`); api.123.do serves `steers`/`answered` on run outcomes; tui.123.do passes them | built, tested (`t/44-compounding.rakutest`, api `t/integration/179` D, tui `t/52-outcomes.rakutest`) |
| 6 | Kept lessons become a skill (`321 skills make`, a standard SKILL.md) a person can give any run with `--skill` and publish to the registry, private to their account until they make it public there | cli.321.do (`Do321::Promote`); agents.321.do `POST /api/skills` | built, tested (`t/46-skills-from-lessons.rakutest`, registry `t/18-skill-publish.t`) |
| 4 | Each judged run's lesson ids and outcome go to the registry (`lesson-uses.v1`, opaque runKey; runs told nothing are the comparison) and each registry lesson shows its evidence | api.123.do sends; agents.321.do receives (another session) | sender built and tested against a stub; the receiving end is built in agents.321.do and not yet deployed |

## How a correction travels

1. A person declines b1ll's result on a Step in 123.do and says why.
2. On the person's computer, the 123 worker reads the verdict and runs `321 outcome <run> rejected <their words>`; 321 records the outcome and proposes a lesson on trial for b1ll, on any harness or model.
3. In a Track whose context is configured, api.123.do teaches the same words to the registry for that context and reports the run's lesson uses.
4. The next b1ll package from that Track carries the lesson as advice (`context.lines`, grants nothing); the next 321-built run anywhere carries the local one.
5. A person who had to steer the run while it went on ("check the printer path first") is driving the harness by hand; each such steer reaches 321 with the verdict and becomes a lesson on trial, so the next run is told it and the person need not say it again. How often a person stepped in is counted per run where 123.do reported it, and unknown elsewhere.
6. Judged runs with and without a lesson are compared: 321 keeps or reverts what no person decided; at the registry the evidence is shown and a person decides.

What is deliberately not built: a model call to distil lessons, a new service or daemon, automatic keep or revert at the registry (a person decides there, `lessons_decided_by_a_person`), promotion of a lesson into a skill, organisation-wide value.
