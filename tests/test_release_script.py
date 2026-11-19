"""scripts/release-after-deploy.sh against a throwaway git remote: pre-v/v tags, the `release`
branch, versions, which work branches are deleted, and the move from release/ branches to tags."""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "release" / "release-after-deploy.sh"
GIT_ENV = {
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull,
}

pytestmark = pytest.mark.skipif(shutil.which("git") is None, reason="needs git")


class Repo:
    """A bare 'origin' plus a working clone, like the workflow's checkout."""

    def __init__(self, root: Path):
        self.origin = root / "origin.git"
        self.work = root / "work"
        self.git("init", "-q", "--bare", "-b", "prod", str(self.origin), cwd=root)
        self.git("clone", "-q", str(self.origin), str(self.work), cwd=root)
        self.git("checkout", "-q", "-b", "prod")
        self.commit("initial")
        self.git("push", "-q", "origin", "prod")

    def git(self, *args, cwd=None) -> str:
        out = subprocess.run(["git", *args], cwd=cwd or self.work, env={**os.environ, **GIT_ENV},
                             check=True, capture_output=True, text=True)
        return out.stdout.strip()

    def commit(self, msg: str) -> str:
        self.git("commit", "-q", "--allow-empty", "-m", msg)
        return self.git("rev-parse", "HEAD")

    def branch_from_prod(self, name: str) -> None:
        """A work branch from prod with one commit, pushed."""
        self.git("checkout", "-q", "-b", name, "prod")
        self.commit(f"work on {name}")
        self.git("push", "-q", "origin", name)
        self.git("checkout", "-q", "prod")

    def release_merge(self, *branches: str) -> tuple[str, str]:
        """merge/prod-x from prod with the branches merged in, then merged into prod (like the
        PR). Returns (before, after) prod commits."""
        before = self.git("rev-parse", "prod")
        self.git("checkout", "-q", "-b", "merge/prod-x", "prod")
        for b in branches:
            self.git("merge", "-q", "--no-ff", "--no-edit", b)
        self.git("checkout", "-q", "prod")
        self.git("merge", "-q", "--no-ff", "-m", "Merge pull request #1 from org/merge/prod-x", "merge/prod-x")
        self.git("branch", "-q", "-D", "merge/prod-x")
        self.git("push", "-q", "origin", "prod")
        return before, self.git("rev-parse", "prod")

    def run(self, *args: str) -> subprocess.CompletedProcess:
        self.git("fetch", "-q", "--prune", "--tags", "origin", "+refs/heads/*:refs/remotes/origin/*")
        return subprocess.run(["bash", str(SCRIPT), *args], cwd=self.work,
                              env={**os.environ, **GIT_ENV, "GITHUB_STEP_SUMMARY": os.devnull},
                              capture_output=True, text=True)

    def remote_branches(self) -> set[str]:
        out = self.git("ls-remote", "--heads", "origin")
        return {line.split("refs/heads/", 1)[1] for line in out.splitlines() if line}

    def remote_sha(self, branch: str) -> str:
        return self.git("ls-remote", "origin", f"refs/heads/{branch}").split()[0]

    def tag_sha(self, tag: str) -> str:
        """The commit a remote tag points at (annotated tags peeled)."""
        out = self.git("ls-remote", "origin", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}")
        lines = out.splitlines()
        assert lines, f"no tag {tag}"
        return lines[-1].split()[0]

    def remote_tags(self) -> set[str]:
        out = self.git("ls-remote", "--tags", "origin")
        return {l.split("refs/tags/", 1)[1] for l in out.splitlines() if l and not l.endswith("^{}")}


@pytest.fixture
def repo(tmp_path):
    return Repo(tmp_path)


def test_first_release_is_v1_and_records_the_rollback_point(repo):
    repo.branch_from_prod("feat/a")
    before, after = repo.release_merge("feat/a")
    assert repo.run("--pre", after, before).returncode == 0
    assert repo.tag_sha("pre-v1.0.0") == before
    assert repo.run(after).returncode == 0
    assert repo.tag_sha("v1.0.0") == after
    # One `release` branch, always at what is live; no release/ branches.
    assert repo.remote_sha("release") == after
    assert not any(b.startswith("release/") for b in repo.remote_branches())


def test_released_work_branches_are_deleted_and_unreleased_kept(repo):
    repo.branch_from_prod("feat/a")
    repo.branch_from_prod("fix/b")
    repo.branch_from_prod("hotfix/c")
    repo.branch_from_prod("feat/not-yet")
    _, after = repo.release_merge("feat/a", "fix/b", "hotfix/c")
    assert repo.run(after).returncode == 0
    branches = repo.remote_branches()
    assert {"feat/a", "fix/b", "hotfix/c"}.isdisjoint(branches)
    assert "feat/not-yet" in branches


def test_fix_only_release_bumps_patch_and_feat_bumps_minor(repo):
    repo.branch_from_prod("feat/a")
    _, v1 = repo.release_merge("feat/a")
    repo.run(v1)
    repo.branch_from_prod("fix/b")
    before, v2 = repo.release_merge("fix/b")
    repo.run("--pre", v2, before)
    repo.run(v2)
    assert repo.tag_sha("pre-v1.0.1") == before
    assert repo.tag_sha("v1.0.1") == v2
    repo.branch_from_prod("feat/c")
    _, v3 = repo.release_merge("feat/c")
    repo.run(v3)
    assert repo.tag_sha("v1.1.0") == v3
    assert repo.remote_sha("release") == v3


def test_rerun_on_a_released_commit_changes_nothing(repo):
    repo.branch_from_prod("fix/a")
    before, after = repo.release_merge("fix/a")
    repo.run(after)
    branches, tags = repo.remote_branches(), repo.remote_tags()
    again = repo.run(after)
    assert again.returncode == 0 and "already exists" in again.stdout
    assert repo.run("--pre", after, before).returncode == 0
    assert repo.remote_branches() == branches and repo.remote_tags() == tags


def test_dry_run_changes_nothing(repo):
    repo.branch_from_prod("feat/a")
    _, after = repo.release_merge("feat/a")
    branches = repo.remote_branches()
    out = subprocess.run(["bash", str(SCRIPT), after], cwd=repo.work,
                         env={**os.environ, **GIT_ENV, "DRY_RUN": "1", "GITHUB_STEP_SUMMARY": os.devnull},
                         capture_output=True, text=True)
    assert out.returncode == 0 and "[dry-run]" in out.stdout
    assert repo.remote_branches() == branches


def test_refuses_a_prod_that_diverged_from_the_last_release(repo):
    repo.branch_from_prod("fix/a")
    _, v1 = repo.release_merge("fix/a")
    repo.run(v1)
    # A prod history that does not contain release/v1.0.0.
    repo.git("checkout", "-q", "--orphan", "other")
    other = repo.commit("unrelated")
    repo.git("push", "-q", "origin", "other")
    out = repo.run(other)
    assert out.returncode != 0 and "not an ancestor" in out.stderr


def test_tags_are_lightweight(repo):
    """GitHub rejects new annotated tag objects from the workflow token when the tagged commit's
    workflow files differ from the default branch's; lightweight tags are just refs."""
    repo.branch_from_prod("fix/a")
    before, after = repo.release_merge("fix/a")
    repo.run("--pre", after, before)
    repo.run(after)
    for tag in ("pre-v1.0.0", "v1.0.0"):
        assert repo.git("cat-file", "-t", f"refs/tags/{tag}", cwd=repo.origin) == "commit", tag


def test_legacy_release_branches_become_tags(repo):
    """Releases made before the switch were release/ branches: they become tags, the branches go."""
    repo.branch_from_prod("fix/a")
    before, v1 = repo.release_merge("fix/a")
    repo.git("push", "-q", "origin", f"{before}:refs/heads/release/pre-v1.0.0", f"{v1}:refs/heads/release/v1.0.0")
    repo.branch_from_prod("fix/b")
    _, v2 = repo.release_merge("fix/b")
    assert repo.run(v2).returncode == 0
    assert repo.tag_sha("pre-v1.0.0") == before and repo.tag_sha("v1.0.0") == v1
    assert repo.tag_sha("v1.0.1") == v2 and repo.remote_sha("release") == v2
    assert not any(b.startswith("release/") for b in repo.remote_branches())


def test_release_lists_the_merged_branches_and_prod_pr(repo):
    repo.branch_from_prod("feat/a")
    repo.branch_from_prod("fix/b")
    _, v1 = repo.release_merge("feat/a", "fix/b")
    out = repo.run(v1)
    assert out.returncode == 0
    assert "Merged branches: feat/a fix/b" in out.stdout
    assert "Prod PRs: #1 (merge/prod-x)" in out.stdout
    repo.branch_from_prod("fix/c")
    _, v2 = repo.release_merge("fix/c")
    out = repo.run(v2)
    assert "Merged branches: fix/c" in out.stdout  # only what is new since v1.0.0
