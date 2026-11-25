#!/usr/bin/env python3
"""Published metadata and actual version-sync workflow tests; no GitHub calls."""

import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from sync_published_version import published_version, sync_project, version_key


def project(build=271, version="0.1.1"):
    return (f'CURRENT_PROJECT_VERSION = {build};\nMARKETING_VERSION = "{version}";\n' * 3) + 'OTHER_SETTING = keep;\n'


def appcast(build="273", version="0.1.1"):
    return f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>{version}</sparkle:shortVersionString></item></channel></rss>'


class PublishedVersionTests(unittest.TestCase):
    def test_exact_published_number_all_targets_and_idempotency(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pbx, feed = root / "project.pbxproj", root / "appcast.xml"
            pbx.write_text(project())
            feed.write_text(appcast())
            sync_project(pbx, feed, "0.1.1")
            self.assertEqual(pbx.read_text(), project(273))
            sync_project(pbx, feed, "0.1.1")
            self.assertEqual(pbx.read_text(), project(273))

    def test_does_not_downgrade_future_build_or_future_marketing_version(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pbx, feed = root / "project.pbxproj", root / "appcast.xml"
            feed.write_text(appcast())
            pbx.write_text(project(300, "0.2.0"))
            sync_project(pbx, feed, "0.1.1")
            self.assertEqual(pbx.read_text(), project(300, "0.2.0"))
            pbx.write_text(project(271, "0.2.0"))
            sync_project(pbx, feed, "0.1.1")
            self.assertEqual(pbx.read_text(), project(273, "0.2.0"))

    def test_rejects_wrong_or_ambiguous_release_and_invalid_build_without_writing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pbx, feed = root / "project.pbxproj", root / "appcast.xml"
            pbx.write_text(project())
            for content in (appcast(version="0.1.0"), appcast(build=""), appcast(build="0"), appcast(build="273.1"), appcast().replace('</channel>', '<item><sparkle:version>274</sparkle:version><sparkle:shortVersionString>0.1.1</sparkle:shortVersionString></item></channel>')):
                feed.write_text(content)
                with self.assertRaises(ValueError):
                    sync_project(pbx, feed, "0.1.1")
                self.assertEqual(pbx.read_text(), project())

    def test_nightly_reads_the_version_from_the_generated_appcast(self):
        with tempfile.TemporaryDirectory() as tmp:
            feed = Path(tmp) / 'appcast.xml'
            feed.write_text(appcast(version='0.1.2-rc.1'))
            self.assertEqual(published_version(feed), '0.1.2-rc.1')
            feed.write_text('<rss><channel /></rss>')
            with self.assertRaises(ValueError):
                published_version(feed)

    def test_nightly_sync_follows_publication_and_uses_the_live_project(self):
        workflow = (SCRIPTS.parents[1] / '.github/workflows/nightly.yml').read_text()
        self.assertLess(workflow.index('- name: Publish rolling nightly release'), workflow.index('python3 .github/scripts/sync_published_version.py'))
        self.assertIn('contents/${PBXPROJ_PATH}?ref=${CURRENT_HEAD}', workflow)
        self.assertIn('--rawfile project published-project.pbxproj', workflow)
        self.assertIn('content: $project', workflow)

    def test_semantic_version_ordering(self):
        versions = ["0.1.1-rc.2", "0.1.1-rc.10", "0.1.1", "0.1.2", "0.2.0"]
        self.assertEqual(sorted(versions, key=version_key), versions)
        self.assertEqual(version_key("0.1.1+metadata"), version_key("0.1.1"))

    def run_workflow_sync(self, beta=False, race=False):
        workflow = (SCRIPTS.parents[1] / '.github/workflows/release.yml').read_text()
        block = workflow.split('      - name: Sync actual published version without overwriting development work\n', 1)[1]
        block = textwrap.dedent(block.split('        run: |\n', 1)[1].split('\n  ending:', 1)[0])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            remote, seed, work, racer = [root / name for name in ('remote.git', 'seed', 'work', 'racer')]

            def git(*args, cwd=None):
                return subprocess.run(['git', *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()

            git('init', '--bare', str(remote))
            git('init', '-b', 'main', str(seed))
            git('config', 'user.name', 'Fixture', cwd=seed)
            git('config', 'user.email', 'fixture@example.invalid', cwd=seed)
            git('config', 'commit.gpgsign', 'false', cwd=seed)
            pbx = Path('powerNotch.xcodeproj/project.pbxproj')
            (seed / pbx).parent.mkdir()
            (seed / pbx).write_text(project())
            (seed / 'unrelated.txt').write_text('main content')
            git('add', '.', cwd=seed)
            git('commit', '-m', 'Initial', cwd=seed)
            git('remote', 'add', 'origin', str(remote), cwd=seed)
            git('push', 'origin', 'main', cwd=seed)
            git('checkout', '-b', 'dev', cwd=seed)
            (seed / 'unrelated.txt').write_text('development work')
            git('commit', '-am', 'Develop', cwd=seed)
            git('push', 'origin', 'dev', cwd=seed)
            git('clone', '-b', 'main', str(remote), str(work))
            git('config', 'commit.gpgsign', 'false', cwd=work)
            helpers = work / '.github/scripts'
            helpers.mkdir(parents=True)
            for name in ('stamp_version.py', 'sync_published_version.py'):
                shutil.copy2(SCRIPTS / name, helpers / name)
            runtime = root / 'runtime'
            (runtime / 'published-appcast').mkdir(parents=True)
            channel = 'beta' if beta else 'stable'
            (runtime / f'published-appcast/appcast-{channel}.xml').write_text(appcast())
            mock = ''
            if race:
                git('clone', '-b', 'main', str(remote), str(racer))
                git('config', 'user.name', 'Concurrent developer', cwd=racer)
                git('config', 'user.email', 'concurrent@example.invalid', cwd=racer)
                git('config', 'commit.gpgsign', 'false', cwd=racer)
                (racer / 'concurrent.txt').write_text('preserve this new commit')
                git('add', '.', cwd=racer)
                git('commit', '-m', 'Concurrent work', cwd=racer)
                (runtime / 'race').touch()
                mock = '''git() {
  if [[ "$*" == *" push "* && -f "$RUNNER_TEMP/race" ]]; then
    rm "$RUNNER_TEMP/race"
    command git -C "$RACER" push origin main
  fi
  command git "$@"
}
'''
            env = {**os.environ, 'RUNNER_TEMP': str(runtime), 'PROJECT_NAME': 'powerNotch', 'RELEASE_APP_TOKEN': 'fixture', 'VERSION': '0.1.1', 'IS_BETA': str(beta).lower(), 'RACER': str(racer)}
            for _ in range(2):
                # Copy the helpers back after the real branch checkout removes them.
                helpers.mkdir(parents=True, exist_ok=True)
                for name in ('stamp_version.py', 'sync_published_version.py'):
                    shutil.copy2(SCRIPTS / name, helpers / name)
                result = subprocess.run(['bash', '-c', mock + block], cwd=work, env=env, capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for branch in ('main', 'dev'):
                expected = project() if beta and branch == 'main' else project(273)
                self.assertEqual(git('--git-dir', str(remote), 'show', f'{branch}:{pbx}'), expected.strip())
            self.assertEqual(git('--git-dir', str(remote), 'show', 'dev:unrelated.txt'), 'development work')
            self.assertEqual(git('--git-dir', str(remote), 'show', 'main:unrelated.txt'), 'main content')
            if race:
                self.assertEqual(git('--git-dir', str(remote), 'show', 'main:concurrent.txt'), 'preserve this new commit')

    def test_stable_workflow_syncs_both_branches_without_merging_unrelated_work(self):
        self.run_workflow_sync()

    def test_beta_workflow_only_syncs_dev(self):
        self.run_workflow_sync(beta=True)

    def test_concurrent_push_is_retried_without_losing_the_new_commit(self):
        self.run_workflow_sync(race=True)

    def test_workflow_waits_for_publication_and_reports_sync_failures(self):
        workflow = (SCRIPTS.parents[1] / '.github/workflows/release.yml').read_text()
        job = workflow.split('  sync_published_version:\n', 1)[1].split('  ending:', 1)[0]
        self.assertIn("needs.upgrade-brew.result == 'success'", job)
        self.assertIn("needs.publish_stable.result == 'success'", job)
        self.assertNotIn('preparation.outputs.build_number', job)
        ending = workflow.split('  ending:', 1)[1]
        self.assertIn("needs.sync_published_version.result == 'success'", ending)


if __name__ == '__main__':
    unittest.main()
