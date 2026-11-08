"""Offline release.sh contract checks using real disposable Git repositories."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PROJECT = 'Mio.xcodeproj/project.pbxproj'
ORIGIN = 'https://github.com/example/mio-release-checks.git'
REPOSITORY = 'example/mio-release-checks'

MOCK = r'''import json, os, sys
from pathlib import Path
root = Path(os.environ['RELEASE_CHECK_ROOT'])
args = sys.argv[1:]
tool = Path(sys.argv[0]).name
with (root / 'events.jsonl').open('a') as out:
    out.write(json.dumps({'tool': tool, 'args': args}) + '\n')
if tool == 'git':
    if args[:1] == ['push'] and (root / 'fail-push').exists():
        print('simulated push failure', file=sys.stderr)
        raise SystemExit(1)
    os.execv(os.environ['RELEASE_CHECK_GIT'], [os.environ['RELEASE_CHECK_GIT']] + args)
if args[:2] == ['auth', 'status']:
    raise SystemExit(1 if (root / 'fail-auth').exists() else 0)
if args[:2] == ['repo', 'view']:
    if (root / 'fail-repo').exists(): raise SystemExit(1)
    print('example/mio-release-checks')
    raise SystemExit(0)
state_file = root / 'release.json'
if args[:2] == ['release', 'view']:
    if not state_file.exists():
        print('release not found', file=sys.stderr)
        raise SystemExit(1)
    print(state_file.read_text())
    raise SystemExit(0)
if args[:2] == ['release', 'create']:
    if (root / 'fail-create').exists():
        print('simulated gh create failure', file=sys.stderr)
        raise SystemExit(1)
    if state_file.exists():
        print('release already exists', file=sys.stderr)
        raise SystemExit(1)
    state_file.write_text(json.dumps({'isDraft': False, 'url': 'https://github.com/example/mio-release-checks/releases/tag/' + args[2]}))
    print(json.loads(state_file.read_text())['url'])
    raise SystemExit(0)
if args[:2] == ['release', 'edit']:
    state = json.loads(state_file.read_text())
    state['isDraft'] = False
    state_file.write_text(json.dumps(state))
    raise SystemExit(0)
print('unexpected mocked gh arguments: ' + repr(args), file=sys.stderr)
raise SystemExit(99)
'''


class ReleaseScriptChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = ROOT / 'release.sh'
        if not cls.script.is_file():
            raise RuntimeError('release.sh must exist before running these checks')
        cls.real_git = shutil.which('git')
        cls.zsh = shutil.which('zsh')
        if not cls.real_git or not cls.zsh:
            raise unittest.SkipTest('Git and zsh are required')
        cls.project_source = (ROOT / PROJECT).read_text()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mio-release-checks-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / 'work'
        self.remote = self.root / 'origin.git'
        self.repo.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.home = self.root / 'home'
        self.home.mkdir()
        # No inherited credentials, Git configuration, hooks, or real gh executable.
        self.env = {
            'PATH': str(self.bin), 'HOME': str(self.home), 'LC_ALL': 'C',
            'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': str(self.root / 'gitconfig'),
            'GIT_TERMINAL_PROMPT': '0', 'GIT_AUTHOR_NAME': 'Release Checks',
            'GIT_AUTHOR_EMAIL': 'release-checks@example.invalid',
            'GIT_COMMITTER_NAME': 'Release Checks',
            'GIT_COMMITTER_EMAIL': 'release-checks@example.invalid',
            'RELEASE_CHECK_ROOT': str(self.root), 'RELEASE_CHECK_GIT': self.real_git,
        }
        for name, executable in [('python3', sys.executable), ('zsh', self.zsh),
                                 ('dirname', shutil.which('dirname')),
                                 ('git-receive-pack', shutil.which('git-receive-pack')),
                                 ('git-upload-pack', shutil.which('git-upload-pack'))]:
            if executable:
                (self.bin / name).symlink_to(executable)
        for name in ['gh', 'git']:
            path = self.bin / name
            path.write_text('#!' + sys.executable + '\n' + MOCK)
            path.chmod(0o755)
        # Global rewrite also intercepts direct-URL ls-remote calls.
        self.git('config', '--global', 'url.' + str(self.remote) + '.insteadOf', ORIGIN)
        self.git('init', '--bare', str(self.remote), cwd=self.root)
        self.git('init', '-b', 'release-check', str(self.repo), cwd=self.root)
        self.git('config', 'commit.gpgsign', 'false')
        self.git('config', 'tag.gpgsign', 'false')
        self.git('config', 'core.hooksPath', str(self.root / 'no-hooks'))
        self.project = self.repo / PROJECT
        self.project.parent.mkdir()
        text = re.sub(r'(MARKETING_VERSION\s*=\s*)[^;]+', r'\g<1>1.0.0', self.project_source)
        text = re.sub(r'(CURRENT_PROJECT_VERSION\s*=\s*)[^;]+', r'\g<1>40', text)
        self.project.write_text(text)
        workflow = self.repo / '.github/workflows/release.yml'
        workflow.parent.mkdir(parents=True)
        workflow.write_text('name: Release\non: push\n')
        shutil.copy2(self.script, self.repo / 'release.sh')
        (self.repo / 'release.sh').chmod(0o755)
        (self.repo / 'unrelated.txt').write_text('preserve me\n')
        self.git('add', '.')
        self.git('commit', '-m', 'Initial fixture')
        self.git('remote', 'add', 'origin', ORIGIN)
        self.git('push', '-u', 'origin', 'HEAD:refs/heads/release-check')
        self.initial_head = self.git('rev-parse', 'HEAD').stdout.strip()
        self.clear_events()

    def git(self, *args, cwd=None, check=True):
        result = subprocess.run([self.real_git, *args], cwd=cwd or self.repo,
                                env=self.env, capture_output=True, text=True, timeout=20)
        if check and result.returncode:
            self.fail(f'git {args!r}: {result.stdout}\n{result.stderr}')
        return result

    def release(self, *args, success=True):
        result = subprocess.run([str(self.repo / 'release.sh'), *args], cwd=self.repo,
                                env=self.env, capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        if success:
            self.assertEqual(result.returncode, 0, output)
        else:
            self.assertNotEqual(result.returncode, 0, output)
        return result

    def clear_events(self):
        (self.root / 'events.jsonl').write_text('')

    def events(self, tool):
        events = [json.loads(line) for line in (self.root / 'events.jsonl').read_text().splitlines()]
        return [event['args'] for event in events if event['tool'] == tool]

    def snapshot(self):
        # Include index, refs, objects, FETCH_HEAD and config, not just worktree.
        return {str(path.relative_to(self.root)): path.read_bytes()
                for directory in (self.repo, self.remote)
                for path in directory.rglob('*') if path.is_file()}

    def versions(self):
        text = self.project.read_text()
        return (re.findall(r'MARKETING_VERSION\s*=\s*([^;]+);', text),
                re.findall(r'CURRENT_PROJECT_VERSION\s*=\s*([^;]+);', text))

    def assert_release_commit(self, version):
        core = version.split('-')[0].split('+')[0]
        self.assertEqual(self.versions(), ([core, core], ['41', '41']))
        self.assertEqual(self.git('log', '-1', '--format=%s').stdout.strip(), 'chore: release v' + version)
        self.assertEqual(self.git('diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD').stdout.splitlines(), [PROJECT])
        self.assertEqual(self.git('rev-list', '--count', self.initial_head + '..HEAD').stdout.strip(), '1')
        self.assertEqual(self.git('status', '--porcelain').stdout, '')
        tag = 'v' + version
        self.assertEqual(self.git('cat-file', '-t', 'refs/tags/' + tag).stdout.strip(), 'tag')
        head = self.git('rev-parse', 'HEAD').stdout.strip()
        self.assertEqual(self.git('rev-parse', tag + '^{}').stdout.strip(), head)
        return head

    def assert_pushed(self, version, head):
        self.assertEqual(self.git('--git-dir=' + str(self.remote), 'rev-parse', 'refs/heads/release-check').stdout.strip(), head)
        self.assertEqual(self.git('--git-dir=' + str(self.remote), 'rev-parse', 'refs/tags/v' + version + '^{}').stdout.strip(), head)
        pushes = [args for args in self.events('git') if args[:1] == ['push']]
        self.assertIn(['push', '--atomic', 'origin', 'HEAD:refs/heads/release-check', 'refs/tags/v' + version], pushes)

    def assert_gh_create(self, version, prerelease=False):
        calls = self.events('gh')
        self.assertIn(['auth', 'status'], calls)
        self.assertIn(['repo', 'view', ORIGIN, '--json', 'nameWithOwner', '--jq', '.nameWithOwner'], calls)
        creates = [args for args in calls if args[:2] == ['release', 'create']]
        self.assertEqual(len(creates), 1)
        args = creates[0]
        self.assertEqual(args[2], 'v' + version)
        for flag, value in [('--repo', REPOSITORY), ('--title', 'Mio ' + version)]:
            self.assertIn(flag, args)
            self.assertEqual(args[args.index(flag) + 1], value)
        self.assertIn('--verify-tag', args)
        self.assertIn('--generate-notes', args)
        self.assertEqual('--prerelease' in args, prerelease)
        probes = [args for args in self.events('git') if 'ls-remote' in args]
        self.assertTrue(any(any('tags' in arg for arg in args) for args in probes))
        self.assertTrue(any(any('heads' in arg for arg in args) for args in probes))
        events = [json.loads(line) for line in (self.root / 'events.jsonl').read_text().splitlines()]
        mutations = [index for index, event in enumerate(events)
                     if event['tool'] == 'git' and event['args'][:1] in (['commit'], ['tag'], ['push'])]
        if mutations:
            first_mutation = min(mutations)
            for command in [['auth', 'status'], ['repo', 'view', ORIGIN, '--json', 'nameWithOwner', '--jq', '.nameWithOwner']]:
                self.assertTrue(any(index < first_mutation and event['tool'] == 'gh' and event['args'] == command
                                    for index, event in enumerate(events)), 'GitHub preflight must precede mutations')
            self.assertTrue(any(index < first_mutation and event['tool'] == 'git' and 'ls-remote' in event['args']
                                for index, event in enumerate(events)), 'Remote checks must precede mutations')

    def test_commit_failure_restores_version_edit(self):
        hooks = self.root / 'hooks'
        hooks.mkdir()
        hook = hooks / 'pre-commit'
        hook.write_text('#!/bin/sh\nexit 1\n')
        hook.chmod(0o755)
        self.git('config', 'core.hooksPath', str(hooks))
        original = self.project.read_text()
        self.release('2.3.4', success=False)
        self.assertEqual(self.project.read_text(), original)
        self.assertEqual(self.git('rev-parse', 'HEAD').stdout.strip(), self.initial_head)
        self.assertEqual(self.git('status', '--porcelain').stdout, '')
        self.assertFalse(any(args[:1] in (['tag'], ['push']) for args in self.events('git')))

    def test_post_commit_changes_stop_before_tag_and_allow_retry(self):
        hooks = self.root / 'hooks'
        hooks.mkdir()
        hook = hooks / 'post-commit'
        hook.write_text('#!/bin/sh\nprintf hook > hook-output.txt\n')
        hook.chmod(0o755)
        self.git('config', 'core.hooksPath', str(hooks))
        self.release('2.3.4', success=False)
        self.assertEqual(self.git('log', '-1', '--format=%s').stdout.strip(), 'chore: release v2.3.4')
        self.assertFalse(any(args[:1] in (['tag'], ['push']) for args in self.events('git')))
        (self.repo / 'hook-output.txt').unlink()
        self.git('config', 'core.hooksPath', str(self.root / 'no-hooks'))
        self.clear_events()
        self.release('2.3.4')
        self.assert_pushed('2.3.4', self.assert_release_commit('2.3.4'))

    def test_stable_full_flow(self):
        self.release('v2.3.4')
        self.assert_pushed('2.3.4', self.assert_release_commit('2.3.4'))
        self.assert_gh_create('2.3.4')

    def test_prerelease_and_metadata_full_flow(self):
        version = '2.3.4-rc.1+build.7'
        self.release(version)
        self.assert_pushed(version, self.assert_release_commit(version))
        self.assert_gh_create(version, prerelease=True)

    def test_metadata_alone_is_stable(self):
        version = '2.3.4+build.7'
        self.release(version)
        self.assert_release_commit(version)
        self.assert_gh_create(version)

    def test_dry_run_offline_dirty_and_without_gh(self):
        (self.bin / 'gh').unlink()
        self.project.write_text(self.project.read_text() + '\n// dirty\n')
        (self.repo / 'untracked.txt').write_text('local content')
        self.git('add', PROJECT)
        before = self.snapshot()
        result = self.release('2.3.4-rc.1', '--dry-run')
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.events('gh'))
        self.assertFalse(any(args[:1] in (['push'], ['fetch'], ['ls-remote']) for args in self.events('git')))
        self.assertIn('2.3.4-rc.1', result.stdout)
        self.assertIn('41', result.stdout)

    def test_dirty_default_rejected_without_mutation(self):
        self.project.write_text(self.project.read_text() + '\n// dirty\n')
        before = self.snapshot()
        self.release('2.3.4', success=False)
        self.assertEqual(self.snapshot(), before)

    def test_untracked_default_rejected(self):
        (self.repo / 'untracked.txt').write_text('local content')
        before = self.snapshot()
        self.release('2.3.4', success=False)
        self.assertEqual(self.snapshot(), before)

    def test_invalid_versions_rejected_before_mutation(self):
        for version in ['', '1', '1.2', '1.2.3.4', 'vv1.2.3', '1.2.3-', '1.2.3+',
                        '1.2.3-rc..1', '1.2.3+build..7', '1.2.3/evil', '1.2.3;touch nope',
                        '01.2.3', '1.2.3-01']:
            with self.subTest(version=version):
                before = self.snapshot()
                self.clear_events()
                self.release(version, success=False)
                self.assertEqual(self.snapshot(), before)
                self.assertFalse(self.events('gh'))

    def test_conflicting_local_tag_rejected_before_mutation(self):
        self.git('tag', '-a', 'v2.3.4', '-m', 'Existing unrelated tag')
        before = self.snapshot()
        self.release('2.3.4', success=False)
        self.assertEqual(self.snapshot(), before)

    def test_conflicting_remote_tag_rejected_before_mutation(self):
        self.git('tag', '-a', 'v2.3.4', '-m', 'Existing remote tag')
        self.git('push', 'origin', 'refs/tags/v2.3.4')
        self.git('tag', '-d', 'v2.3.4')
        before = self.snapshot()
        self.release('2.3.4', success=False)
        self.assertEqual(self.snapshot(), before)

    def test_gh_create_failure_retry_reuses_commit_build_and_tag(self):
        failure = self.root / 'fail-create'
        failure.touch()
        self.release('2.3.4', success=False)
        head = self.assert_release_commit('2.3.4')
        tag = self.git('rev-parse', 'v2.3.4').stdout
        self.assert_pushed('2.3.4', head)
        failure.unlink()
        self.clear_events()
        self.release('2.3.4')
        self.assertEqual(self.assert_release_commit('2.3.4'), head)
        self.assertEqual(self.git('rev-parse', 'v2.3.4').stdout, tag)
        self.assert_gh_create('2.3.4')

    def test_push_failure_retry_reuses_commit_build_and_tag(self):
        failure = self.root / 'fail-push'
        failure.touch()
        self.release('2.3.4', success=False)
        head = self.assert_release_commit('2.3.4')
        tag = self.git('rev-parse', 'v2.3.4').stdout
        self.assertFalse(any(args[:2] == ['release', 'create'] for args in self.events('gh')))
        failure.unlink()
        self.clear_events()
        self.release('2.3.4')
        self.assertEqual(self.assert_release_commit('2.3.4'), head)
        self.assertEqual(self.git('rev-parse', 'v2.3.4').stdout, tag)
        self.assert_pushed('2.3.4', head)

    def test_matching_release_commit_without_tag_is_reused(self):
        text = self.project.read_text().replace('MARKETING_VERSION = 1.0.0;', 'MARKETING_VERSION = 2.3.4;').replace('CURRENT_PROJECT_VERSION = 40;', 'CURRENT_PROJECT_VERSION = 41;')
        self.project.write_text(text)
        self.git('add', PROJECT)
        self.git('commit', '-m', 'chore: release v2.3.4')
        head = self.git('rev-parse', 'HEAD').stdout.strip()
        self.release('2.3.4')
        self.assertEqual(self.assert_release_commit('2.3.4'), head)
        self.assert_pushed('2.3.4', head)

    def test_published_release_retry_skips_duplicate_creation(self):
        self.release('2.3.4')
        head = self.assert_release_commit('2.3.4')
        tag = self.git('rev-parse', 'v2.3.4').stdout
        self.clear_events()
        self.release('2.3.4')
        self.assertEqual(self.assert_release_commit('2.3.4'), head)
        self.assertEqual(self.git('rev-parse', 'v2.3.4').stdout, tag)
        self.assertFalse(any(args[:2] == ['release', 'create'] for args in self.events('gh')))
        views = [args for args in self.events('gh') if args[:2] == ['release', 'view']]
        self.assertTrue(views)
        self.assertIn('--json', views[0])
        self.assertEqual(set(views[0][views[0].index('--json') + 1].split(',')), {'isDraft', 'url'})

    def test_existing_draft_is_published_without_duplicate_create(self):
        (self.root / 'release.json').write_text(json.dumps({'isDraft': True, 'url': 'https://github.com/example/mio-release-checks/releases/tag/v2.3.4'}))
        self.release('2.3.4')
        self.assert_release_commit('2.3.4')
        calls = self.events('gh')
        self.assertFalse(any(args[:2] == ['release', 'create'] for args in calls))
        edits = [args for args in calls if args[:2] == ['release', 'edit']]
        self.assertEqual(len(edits), 1)
        self.assertTrue('--draft=false' in edits[0] or ('--draft' in edits[0] and edits[0][edits[0].index('--draft') + 1] == 'false'))
        self.assertFalse(json.loads((self.root / 'release.json').read_text())['isDraft'])

    def test_remote_ahead_refused_before_mutation(self):
        peer = self.root / 'peer'
        self.git('clone', '-b', 'release-check', str(self.remote), str(peer), cwd=self.root)
        (peer / 'remote.txt').write_text('remote change\n')
        self.git('add', 'remote.txt', cwd=peer)
        self.git('-c', 'commit.gpgsign=false', 'commit', '-m', 'Remote advances', cwd=peer)
        self.git('push', 'origin', 'HEAD:refs/heads/release-check', cwd=peer)
        before = self.snapshot()
        self.release('2.3.4', success=False)
        self.assertEqual(self.snapshot(), before)

    def test_gh_preflight_failure_does_not_mutate(self):
        for marker in ['fail-auth', 'fail-repo']:
            with self.subTest(marker=marker):
                failure = self.root / marker
                failure.touch()
                before = self.snapshot()
                self.release('2.3.4', success=False)
                self.assertEqual(self.snapshot(), before)
                failure.unlink()

    def test_missing_tracked_workflow_is_rejected(self):
        self.git('rm', '.github/workflows/release.yml')
        self.git('commit', '-m', 'Remove workflow')
        before = self.snapshot()
        self.release('2.3.4', success=False)
        self.assertEqual(self.snapshot(), before)

    def test_detached_head_is_rejected(self):
        self.git('checkout', '--detach')
        before = self.snapshot()
        self.release('2.3.4', success=False)
        self.assertEqual(self.snapshot(), before)

    def test_non_github_origin_is_rejected(self):
        self.git('remote', 'set-url', 'origin', str(self.remote))
        before = self.snapshot()
        self.release('2.3.4', success=False)
        self.assertEqual(self.snapshot(), before)


if __name__ == '__main__':
    unittest.main(verbosity=2)
