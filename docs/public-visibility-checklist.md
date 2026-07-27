# Public visibility checklist

Do not change repository visibility until every required item below is complete.

## Source and history

- [ ] Full-history secret scan reports no unresolved credential.
- [ ] Tracked-file privacy audit reports no personal email, machine path, account ID,
      raw screenshot, transcript, or oversized evidence artifact.
- [ ] The pre-rewrite Git bundle is verified and stored outside the repository.
- [ ] Public history uses a GitHub no-reply identity and contains only the sanitized tree.
- [ ] No extra branch or tag exposes the private history.

## Legal and community

- [x] Apache-2.0 license is present.
- [x] README, CONTRIBUTING, SECURITY, CODE_OF_CONDUCT, and CHANGELOG are present.
- [x] Issue templates warn contributors not to upload private content.
- [x] Support tiers and known limitations are explicit.

## Contributor setup

- [ ] A fresh clone installs with the documented Node/pnpm baseline.
- [ ] `pnpm lab:doctor` gives actionable output on a clean checkout.
- [ ] Protocol, web, Worker, Go, and Swift builds pass from the sanitized history.
- [ ] The disposable account-first lab journey passes without production credentials.

## Release and operations

- [ ] `pnpm release:readiness` passes.
- [ ] One bounded GitHub CI run passes after the sanitized push.
- [ ] Production deployment remains manual and protected.
- [ ] Repository description and homepage are set.
- [ ] Branch protection, vulnerability reporting, and dependency updates are reviewed.

## Visibility decision

- [ ] Maintainer explicitly approves changing the repository from private to public.
- [ ] Public source announcement does not claim that a downloadable binary or Preview
      integration is Supported unless its separate release gate is complete.
