# Domain Docs

This is a single-context repository.

## Before exploring

Read root `GLOSSARY.md`, if present, for the project's domain vocabulary.
Read relevant architectural decision records under `docs/adr/` before changing the area they cover.

If these files or directories do not exist, proceed silently. Do not suggest creating them upfront.
The domain-modeling workflow creates them lazily when terms or decisions are resolved.

## Use the glossary's vocabulary

Use the glossary's exact terms in issue titles, implementation discussions, tests, and documentation.
Avoid synonyms the glossary explicitly rejects.
If a needed concept is missing, reconsider whether it is an invented term or note the real gap for domain modeling.

## Respect decisions

Surface a conflict with an existing ADR explicitly rather than silently overriding it.
Explain which decision conflicts and why reopening it may be appropriate.

Edit this document if the repository's domain-documentation layout changes.
