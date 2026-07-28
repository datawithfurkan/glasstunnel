# Dependency compatibility patches

`brace-expansion` 5.0.8 fixes the memory-exhaustion advisory that affects every
earlier major line. `minimatch` 3 and 5 load that package as a CommonJS function,
while version 5 exports a named `expand` function. The two patches preserve the
old consumer API while keeping the secure dependency release.

Remove a patch only after the corresponding `minimatch` consumer no longer
requires it and `pnpm audit`, lint, tests, and builds all remain green.
