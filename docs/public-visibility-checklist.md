# Public visibility checklist

Do not change repository visibility until every required item below is complete.

## Source and history

- [x] Full-history secret scan reports no unresolved credential.
- [x] Tracked-file privacy audit reports no personal email, machine path, account ID,
      raw screenshot, transcript, or oversized evidence artifact.
- [x] The pre-rewrite Git bundle is verified and stored outside the repository.
- [x] Public history uses a GitHub no-reply identity and contains only the sanitized tree.
- [x] No extra branch or tag exposes the private history.

## Legal and community

- [x] Apache-2.0 license is present.
- [x] README, CONTRIBUTING, SECURITY, CODE_OF_CONDUCT, and CHANGELOG are present.
- [x] Issue templates warn contributors not to upload private content.
- [x] Support tiers and known limitations are explicit.

## Contributor setup

- [x] A fresh clone installs with the documented Node/pnpm baseline.
- [x] `pnpm lab:doctor` gives actionable output on a clean checkout.
- [x] Protocol, web, Worker, Go, and Swift builds pass from the sanitized history.
- [x] The disposable account-first lab journey passes without production credentials.

## Release and operations

- [x] `pnpm release:readiness` passes on the committed release candidate and its rebuilt local artifact.
- [x] CI is bounded to the sanitized push; the immutable GitHub check on that commit is the result of record.
- [x] Production deployment is manual-only and is not triggered by the source push.
- [x] Repository description, homepage, and topics are set.
- [x] Repository security settings were reviewed without enabling automatic update PR churn.
- [x] npm dependency audit reports zero advisories and `govulncheck` reports zero reachable vulnerabilities.

GitHub vulnerability alerts, secret scanning, and push protection are enabled.
Automatic security-fix and dependency-update PRs remain disabled to avoid unbounded CI
usage. `main` requires all five CI jobs, linear history, resolved conversations, and
one approving review for contributor pull requests; force pushes and deletion are disabled.

## Visibility decision

- [x] Maintainer explicitly approved the visibility change; the repository is public.
- [x] The public-source announcement contract does not claim that a downloadable binary or Preview
      integration is Supported unless its separate release gate is complete.
