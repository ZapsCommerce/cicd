# ZapsCommerce/cicd — working notes for Claude

Shared CI/CD used by many repositories (README.md); a mistake here breaks every project's deploy.

- Public repository: no secrets, account ids, role ARNs, domains or project names in it.
- Keep inputs backward-compatible within a major version. Removing or renaming an input, or
  changing what an existing input does, needs a new major version (`v2`).
- Change branches from `main` (`feat/`, `fix/`), PR into `main`, merge commit, only after the owner
  says "merge". Versions are tagged by the **Tag version** workflow, never by hand.
- Before pushing: `pytest -q`, `bash -n release/*.sh smoke/*.sh`; extend the tests for any change to
  `release/release-after-deploy.sh`.
- Keep `docs/CICD_PLAYBOOK.md` and its PDF in step with behaviour changes.
