# Prompt Package

Experts have no repository access, no tools, and no memory of earlier rounds. Everything they
know comes from the file passed as `--prompt-file`. Every fan-out (`clarify`, `architecture`,
`ad-hoc`, `review`) sends a package with **all nine sections, in this order, with these exact
headings**. A section with nothing to say states that explicitly (`None.`); never drop a heading.

## Template

```markdown
# MoE Prompt Package

## 1. Product and goal
**Goal:** one or two sentences — the outcome the user wants, in their terms.

**Product (up to 150 words):** what this product is and who uses it; the one or two things it
exists to get right; the domain rules and invariants any design must respect (units, ownership,
money, safety, compliance); its scale and stage (side project or production, users, data size);
and one or two sentences on how this request fits into it. Write it from `CLAUDE.md`,
`AGENTS.md`, `README.md` and the code — not from guesses. Keep it under 150 words: experts
read it every round, and padding crowds out the specifics in sections 5 and 6.

Example: *"CardVault is a private ledger for one collector's Pokémon cards: photograph a card,
a vision model reads it, it is matched to the exact PriceCharting product and priced, with a
20% import markup. Getting the exact print right is the whole product — Base Set vs Base Set 2
or Holo vs Reverse Holo differ 3x in price — so matching rules and their regression tests are
the crown jewels. Money is integer cents end to end; markup is applied in exactly one place.
Multi-user and invite-only: every data-layer call takes an owner, so a missing owner filter
leaks another collector's collection. Small scale (~2k cards), one maintainer, deployed on
Vercel with Postgres on Neon. This request adds tests for the API routes that enforce that
ownership."*

## 2. Problem / feature
What is broken or missing today, who hits it, and what "working" looks like.

## 3. Constraints and non-goals
Hard constraints (stack, compatibility, budgets, deadlines, policies) and what is explicitly
out of scope, so experts don't design for it.

## 4. Expert Q&A (director answers)
See "Section 4 by round" below.

## 5. Codebase context
Only what the experts need to reason: relevant file paths with a one-line role each, key types
and signatures, short excerpts of the code that will change, existing conventions to follow.
Summarize large files; never paste secrets, keys, or `.env` contents.

## 6. Current state
What exists now, what has already been tried, and any decisions already made (and why).

## 7. Success criteria
Observable, checkable conditions: tests that must pass, behaviours, performance numbers.

## 8. Explicit ask
The single question the experts must answer, e.g. "Propose an architecture for X within the
constraints above." Written in the clarify round and then left **unchanged** for architecture.

## 9. Assumptions
What the lead is assuming but has not verified. Experts may challenge these.
```

## Section 4 by round

| Round | Section 4 content |
|---|---|
| `clarify` | Exactly: `Pending — clarify round in progress.` |
| `architecture` | Attributed Q&A and context log from the clarify round (format below), or exactly `No clarifying questions or context requests from any expert.` when every expert wrote `None` for both |
| `challenge` | Keep the architecture round's Q&A; add the chosen design itself to section 6 and point section 8 at it (below) |
| `ad-hoc` / `review` | Any relevant Q&A, or `None.` |

Attributed Q&A format:

```markdown
**Q (grok-4.6-expert):** Does the importer need to resume after a crash, or can it restart?
**A (director):** Must resume. Jobs run up to 20 minutes and the host restarts nightly.

**Q (gpt-5.6-sol, DeepSeek-V4-Pro-expert):** Is Postgres available, or only SQLite?
**A (director, confirmed by user):** Postgres (Neon). SQLite is being retired.
```

**Context added:**
- `jobs` table schema (requested by DeepSeek-V4-Pro-expert, gpt-5.6-sol) → section 5
- p95 import duration for the last 30 days (requested by grok-4.6-expert) → section 6
- Load-test results (requested by gpt-5.6-sol) → unavailable: never run

Merge duplicate questions and requests, and list every expert who asked. Keep each answer to
10 lines or fewer. Mark answers that came from the human as `confirmed by user`. The context
log points at where the evidence landed; the evidence itself goes in sections 5–6.

## The challenge round

Run after an approach is chosen and before it is built. Reuse the architecture package with two
edits:

- **Section 6** gains the chosen design, in enough detail to attack: the approach, the main
  components, and why it was picked over the alternatives.
- **Section 8** becomes: `Argue against the design in section 6. Assume it is the wrong choice.`

Section 1 (product), 2, 3, 5, 7 and 9 stay as they were: the opponent needs the same facts and
the same constraints, or it will object to things that were never on the table. Send it to a
model that did **not** author the chosen design, so it is not defending its own proposal.

## Rules

- **Section 8 is the contract.** Write it before the clarify round and do not reword it for
  the architecture round. If the ask genuinely changes, start a new clarify round.
- **Same package, additive edits.** The architecture package is the clarify package with
  section 4 filled in and requested evidence appended to sections 5–6. Nothing else is
  reworded, so the rounds stay comparable.
- **No secrets.** Packages are written to disk (`~/.cache/moe-plugin/runs/`) and sent to
  third-party providers.
- **Size.** Aim for under ~30k characters. Cut section 5 before cutting anything else; keep the
  product paragraph, it is what stops an expert proposing something the product cannot accept.
- **Same product paragraph every round.** Write it once per feature and reuse it verbatim for
  clarify, architecture and review, so answers stay comparable.
