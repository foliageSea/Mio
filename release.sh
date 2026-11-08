#!/bin/zsh
# 更新应用版本并发布 GitHub Release；--dry-run 仅预演。
set -euo pipefail
MIO_RELEASE_DIR="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null || { print -u2 "未找到 python3。"; exit 1; }
exec python3 - "$MIO_RELEASE_DIR" "$@" <<'PY'
import argparse
import json
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(sys.argv.pop(1)).resolve()
PROJECT = Path("Mio.xcodeproj/project.pbxproj")


class ReleaseError(Exception):
    pass


def run(*args, check=True):
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True, timeout=120)
    if check and result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise ReleaseError(f"{args[0]} {args[1]} 失败：{detail}")
    return result


def git(*args):
    return run("git", *args).stdout.strip()


def setting(text, key):
    pattern = re.compile(r"^([ \t]*" + key + r"[ \t]*=[ \t]*)([^;\n]+)(;[ \t]*)$", re.M)
    values = [match.group(2).strip().strip('"') for match in pattern.finditer(text)]
    if len(values) < 2 or len(set(values)) != 1:
        raise ReleaseError(f"Debug / Release 的 {key} 缺失或不一致。")
    return pattern, values[0]


def main():
    parser = argparse.ArgumentParser(prog="./release.sh", description="同步应用版本、提交并推送版本标签，然后发布 GitHub Release。")
    parser.add_argument("version", help="例如 0.2.0、v0.2.0 或 0.2.0-beta.1")
    parser.add_argument("--dry-run", action="store_true", help="只显示计划，不修改文件、提交、推送或访问 GitHub")
    args = parser.parse_args()
    pattern = r"v?((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))(?:-(?P<pre>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    match = re.fullmatch(pattern, args.version)
    if not match:
        raise ReleaseError("版本号无效，请使用 0.2.0、v0.2.0 或 0.2.0-beta.1 等格式。")
    if match.group("pre") and any(part.isdigit() and len(part) > 1 and part.startswith("0") for part in match.group("pre").split(".")):
        raise ReleaseError("版本号无效：数字预发布标识不能包含前导零。")
    version = args.version[1:] if args.version.startswith("v") else args.version
    core = match.group(1)
    tag = "v" + version
    prerelease = match.group("pre") is not None
    message = "chore: release " + tag
    if shutil.which("git") is None:
        raise ReleaseError("未找到 git。")
    if Path(git("rev-parse", "--show-toplevel")).resolve() != ROOT:
        raise ReleaseError("请将发版脚本放在 Mio 仓库根目录。")
    branch_result = run("git", "symbolic-ref", "--quiet", "--short", "HEAD", check=False)
    if branch_result.returncode:
        raise ReleaseError("当前是 detached HEAD，请先切换到发版分支。")
    branch = branch_result.stdout.strip()
    source = (ROOT / PROJECT).read_text(encoding="utf-8")
    marketing_pattern, old_version = setting(source, "MARKETING_VERSION")
    build_pattern, old_build = setting(source, "CURRENT_PROJECT_VERSION")
    if not re.fullmatch(r"[0-9]+", old_build):
        raise ReleaseError("CURRENT_PROJECT_VERSION 必须是整数构建号。")
    head = git("rev-parse", "HEAD")
    has_tag = run("git", "show-ref", "--verify", "--quiet", "refs/tags/" + tag, check=False).returncode == 0
    if has_tag:
        tagged = run("git", "rev-parse", "--verify", "refs/tags/" + tag + "^{commit}", check=False)
        if tagged.returncode or tagged.stdout.strip() != head or old_version != core:
            raise ReleaseError(f"本地标签 {tag} 已存在，且不对应当前提交和应用版本；不会覆盖标签。")
    prepared = has_tag or (git("log", "-1", "--format=%s") == message and old_version == core)
    new_build = old_build if prepared else str(int(old_build) + 1)
    dirty = bool(git("status", "--porcelain", "--untracked-files=normal"))
    # Give gh the configured GitHub URL, not a local transport URL rewritten by Git.
    remote = git("config", "--get", "remote.origin.url")
    github_origin = r"(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/?"
    if not re.fullmatch(github_origin, remote):
        raise ReleaseError("origin 必须指向 GitHub 仓库（HTTPS 或 SSH 地址）。")
    create_args = ["gh", "release", "create", tag, "--verify-tag", "--generate-notes", "--title", "Mio " + version]
    if prerelease:
        create_args.append("--prerelease")
    print(f"发布版本：{tag}（{'预发布' if prerelease else '正式版'}）", flush=True)
    print(f"应用版本：{old_version} → {core}；本地构建号：{old_build} → {new_build}", flush=True)
    print(f"分支：{branch}；远端：origin", flush=True)
    if args.dry_run:
        if not prepared:
            print(f"更新 {PROJECT} 的 Debug / Release 版本，然后创建提交：{message}")
        print(("复用" if has_tag else "创建") + f"标签：{tag}")
        print(shlex.join(["git", "push", "--atomic", "origin", "HEAD:refs/heads/" + branch, "refs/tags/" + tag]))
        print(shlex.join(create_args))
        if dirty:
            print("当前工作区有未提交改动；正式发版前请先提交。")
        print("预演完成，未修改文件或执行远端操作。")
        return
    if dirty:
        raise ReleaseError("工作区有未提交改动，请先提交或暂存到 stash 后再发版。")
    if run("git", "cat-file", "-e", "HEAD:.github/workflows/release.yml", check=False).returncode:
        raise ReleaseError("当前提交不包含 Release 构建工作流，请先提交工作流。")
    if shutil.which("gh") is None:
        raise ReleaseError("未找到 GitHub CLI，请先安装 gh 并运行 gh auth login。")
    run("gh", "auth", "status")
    repo = run("gh", "repo", "view", remote, "--json", "nameWithOwner", "--jq", ".nameWithOwner").stdout.strip()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ReleaseError("无法识别 origin 对应的 GitHub 仓库。")
    refs = {}
    for line in git("ls-remote", "origin", "refs/heads/" + branch, "refs/tags/" + tag, "refs/tags/" + tag + "^{}").splitlines():
        oid, name = line.split(None, 1)
        refs[name] = oid
    remote_tag = refs.get("refs/tags/" + tag)
    if remote_tag and (not has_tag or remote_tag != git("rev-parse", "refs/tags/" + tag)):
        raise ReleaseError(f"远端标签 {tag} 已存在且与本地不一致；不会覆盖标签。")
    remote_branch = refs.get("refs/heads/" + branch)
    if remote_branch and run("git", "merge-base", "--is-ancestor", remote_branch, "HEAD", check=False).returncode:
        raise ReleaseError("远端分支包含本地没有的提交，请先 git pull --ff-only 后重试。")
    if git("status", "--porcelain", "--untracked-files=normal"):
        raise ReleaseError("检查期间工作区发生了变化，请先提交改动后重试。")
    if not prepared:
        updated = marketing_pattern.sub(lambda item: item.group(1) + core + item.group(3), source)
        updated = build_pattern.sub(lambda item: item.group(1) + new_build + item.group(3), updated)
        if (ROOT / PROJECT).read_text(encoding="utf-8") != source:
            raise ReleaseError("检查期间项目版本发生了变化，请重试。")
        (ROOT / PROJECT).write_text(updated, encoding="utf-8")
        try:
            print(run("git", "commit", "--only", "-m", message, "--", str(PROJECT)).stdout.strip(), flush=True)
        except ReleaseError:
            # Only undo this script's untouched version edit; preserve hook/user edits.
            if git("rev-parse", "HEAD") == head and (ROOT / PROJECT).read_text(encoding="utf-8") == updated:
                run("git", "restore", "--staged", "--", str(PROJECT), check=False)
                (ROOT / PROJECT).write_text(source, encoding="utf-8")
            raise
    committed_source = (ROOT / PROJECT).read_text(encoding="utf-8")
    if setting(committed_source, "MARKETING_VERSION")[1] != core or setting(committed_source, "CURRENT_PROJECT_VERSION")[1] != new_build:
        raise ReleaseError("版本提交后的项目版本不符合预期，请检查 Git hooks 或项目配置。")
    if git("status", "--porcelain", "--untracked-files=normal"):
        raise ReleaseError("版本提交后工作区发生了变化，请检查 Git hooks 或其他改动后重试。")
    if not has_tag:
        run("git", "tag", "-a", tag, "-m", "Mio " + version)
    print("推送版本提交和标签…", flush=True)
    run("git", "push", "--atomic", "origin", "HEAD:refs/heads/" + branch, "refs/tags/" + tag)
    existing = run("gh", "release", "view", tag, "--repo", repo, "--json", "isDraft,url", check=False)
    if existing.returncode == 0:
        release = json.loads(existing.stdout)
        if release.get("isDraft"):
            run("gh", "release", "edit", tag, "--repo", repo, "--draft=false", "--prerelease=" + str(prerelease).lower())
        print("Release：" + release["url"])
        if not release.get("isDraft"):
            print("Release 已存在；可在 GitHub Actions 查看或重新运行构建。")
            return
    else:
        print(run(*create_args, "--repo", repo).stdout.strip())
    print("发版完成，GitHub Actions 将自动构建并上传带版本号的安装包。")


try:
    main()
except (ReleaseError, OSError, subprocess.TimeoutExpired, ValueError) as error:
    print(f"发版失败：{error}", file=sys.stderr)
    print("修复问题后可使用相同版本重试；已创建的版本提交和标签会被复用。", file=sys.stderr)
    sys.exit(1)
except KeyboardInterrupt:
    sys.exit(130)
PY
