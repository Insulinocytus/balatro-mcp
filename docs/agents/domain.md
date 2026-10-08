# Domain Docs

## Layout

Single-context repository: root-level `GLOSSARY.md` and `docs/adr/`.

## Before exploring

- Read `GLOSSARY.md`.
- Read ADRs in `docs/adr/` that concern the area being explored.

If these files do not exist, proceed silently.
Do not suggest creating them merely because they are absent.
Domain modeling creates documentation when terms or decisions are resolved.

## Use the domain vocabulary

Use the defined terms in issue titles, proposals, hypotheses, and test names.
Respect the synonyms explicitly marked as terms to avoid.

If a required concept is undefined, reconsider whether it belongs to this
domain. If it does, note the gap for domain modeling.

## Flag ADR conflicts

If a proposal contradicts an ADR, identify the ADR and explain why the
decision should be reopened rather than silently overriding it.
