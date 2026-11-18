#!/usr/bin/env python3
"""Build, notarize, package and publish Orbit from the canonical repository.

Private signing keys stay in the macOS Keychain. No passwords are command args.
Test packages require --allow-unnotarized and cannot be published by this tool.
"""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
REPO = 'strongestweapon/Orbit'
TEAM = 'M38GX6QKSQ'
IDENTITY = 'Developer ID Application: SUPERLESS Inc. (M38GX6QKSQ)'
ACCOUNT = 'studio.superless.Orbit'
SPARKLE_VERSION = '2.10.1'
FEED = f'https://raw.githubusercontent.com/{REPO}/main/updates/appcast.xml'
NOTARY_PROFILE = 'OrbitNotary'


def run(*args, capture=False):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE if capture else None, check=True)
    return result.stdout.strip() if capture else None


def logged(name, *args):
    log = ROOT / '.build' / (name + '.log')
    log.parent.mkdir(exist_ok=True)
    print(name, flush=True)
    with log.open('w') as stream:
        result = subprocess.run([str(a) for a in args], cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'{name} failed. See {log}')


def app_info(app):
    return plistlib.loads((app / 'Contents/Info.plist').read_bytes())


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def tools(path):
    if path:
        folder = path.resolve()
    else:
        folder = ROOT / '.build' / f'Sparkle-{SPARKLE_VERSION}'
        if not (folder / 'bin/generate_appcast').exists():
            folder.mkdir(parents=True, exist_ok=True)
            archive = folder / f'Sparkle-{SPARKLE_VERSION}.tar.xz'
            if not archive.exists():
                run('gh', 'release', 'download', SPARKLE_VERSION, '--repo', 'sparkle-project/Sparkle',
                    '--pattern', archive.name, '--dir', folder)
            run('tar', '-xf', archive, '-C', folder)
        folder /= 'bin'
    if not (folder / 'generate_appcast').is_file():
        raise RuntimeError('Provide Sparkle bin directory with --sparkle-tools')
    return folder


def build(args):
    version = re.search(r'MARKETING_VERSION:\s*"([0-9.]+)"', (ROOT / 'OrbitApp/project.yml').read_text()).group(1)
    work = ROOT / '.build' / f'release-{version}'
    work.mkdir(parents=True, exist_ok=True)
    archive = work / 'Orbit.xcarchive'
    run('xcodegen', 'generate', '--spec', 'OrbitApp/project.yml')
    logged('release-archive', 'xcodebuild', '-project', 'OrbitApp/Orbit.xcodeproj', '-scheme', 'Orbit',
           '-configuration', 'Release', '-destination', 'generic/platform=macOS',
           '-derivedDataPath', ROOT / '.build/updater', '-archivePath', archive,
           'CODE_SIGN_IDENTITY=' + IDENTITY, 'DEVELOPMENT_TEAM=' + TEAM,
           'ENABLE_HARDENED_RUNTIME=YES', 'OTHER_CODE_SIGN_FLAGS=--timestamp', 'archive')
    for destination in ['export', 'upload']:
        (work / (destination + '.plist')).write_bytes(plistlib.dumps({
            'method': 'developer-id', 'destination': destination, 'signingStyle': 'manual',
            'signingCertificate': IDENTITY, 'teamID': TEAM}))
    logged('release-export', 'xcodebuild', '-exportArchive', '-archivePath', archive,
           '-exportPath', work / 'export', '-exportOptionsPlist', work / 'export.plist')
    print('Signed app:', work / 'export/Orbit.app')
    print('Archive for notarization:', archive)


def notarize(args):
    archive = args.archive.resolve()
    work = archive.parent
    options = work / 'upload.plist'
    options.write_bytes(plistlib.dumps({'method': 'developer-id', 'destination': 'upload',
                                       'signingStyle': 'manual', 'signingCertificate': IDENTITY, 'teamID': TEAM}))
    logged('release-notarization-upload', 'xcodebuild', '-exportArchive', '-archivePath', archive,
           '-exportPath', work / 'upload', '-exportOptionsPlist', options, '-allowProvisioningUpdates')
    # The archive records its submission. Retry export while Apple processes it.
    for attempt in range(40):
        try:
            logged('release-notarized-export', 'xcodebuild', '-exportNotarizedApp',
                   '-archivePath', archive, '-exportPath', work / 'notarized')
            run('xcrun', 'stapler', 'validate', work / 'notarized/Orbit.app')
            print('Notarized app:', work / 'notarized/Orbit.app')
            return
        except RuntimeError:
            if attempt == 39:
                raise
            print('Waiting for Apple notarization…', flush=True)
            time.sleep(30)


def notarize_file(path, profile):
    print('Submitting distribution file for notarization:', path.name, flush=True)
    result = json.loads(run('xcrun', 'notarytool', 'submit', path,
                            '--keychain-profile', profile, '--wait', '--timeout', '20m',
                            '--output-format', 'json', capture=True))
    if result.get('status') != 'Accepted':
        raise RuntimeError(f"Apple rejected the distribution: {result.get('status')} (submission {result.get('id')})")
    run('xcrun', 'stapler', 'staple', path)
    return result['id']


def verify_dmg(path):
    run('codesign', '--verify', '--strict', path)
    run('xcrun', 'stapler', 'validate', path)
    run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', path)


def package(args):
    source = args.app.resolve()
    info = app_info(source)
    if info['CFBundleIdentifier'] != ACCOUNT or info['SUFeedURL'] != FEED:
        raise RuntimeError('This is not a production Orbit update configuration')
    run('codesign', '--verify', '--deep', '--strict', '--all-architectures', source)
    signature = subprocess.run(['codesign', '-dv', '--verbose=2', str(source)], capture_output=True, text=True, check=True).stderr
    if f'TeamIdentifier={TEAM}' not in signature or 'runtime' not in signature:
        raise RuntimeError('Developer ID signing and Hardened Runtime are required')
    notarized = subprocess.run(['xcrun', 'stapler', 'validate', str(source)], capture_output=True).returncode == 0
    if not notarized and not args.allow_unnotarized:
        raise RuntimeError('Notarize and staple the app first, or explicitly create a local TEST package')
    version = info['CFBundleShortVersionString']
    suffix = '' if notarized else '-TEST'
    output = ROOT / 'Releases' / (version + suffix)
    if output.exists():
        raise RuntimeError(f'Refusing to overwrite existing release: {output}')
    sparkle = tools(args.sparkle_tools)
    public_key = run(sparkle / 'generate_keys', '--account', ACCOUNT, '-p', capture=True)
    if public_key != info['SUPublicEDKey']:
        raise RuntimeError('Keychain update signing key does not match the app')
    notes = ROOT / 'updates' / (version + '.txt')
    if not notes.is_file():
        raise RuntimeError(f'Add release notes: {notes}')
    # A local staging folder avoids cloud/Finder metadata contaminating signatures.
    with tempfile.TemporaryDirectory(prefix='orbit-release-') as temporary:
        stage = Path(temporary)
        dmg_contents = stage / 'disk'
        dmg_contents.mkdir()
        app = dmg_contents / 'Orbit.app'
        run('ditto', '--norsrc', '--noextattr', source, app)
        (dmg_contents / 'Applications').symlink_to('/Applications', target_is_directory=True)
        instructions = 'Orbit.app을 Applications 폴더로 끌어다 놓은 뒤 실행하세요.\n'
        if not notarized:
            instructions += '\nTEST: Developer ID 서명 완료, Apple 공증 전 테스트용입니다. 정식 자동 업데이트로 배포하지 않습니다.\n'
        (dmg_contents / 'READ-ME-KO.txt').write_text(instructions)
        artifacts = stage / 'artifacts'
        artifacts.mkdir()
        base = f'Orbit-{version}-macOS-universal{suffix}'
        zip_path = artifacts / (base + '.zip')
        run('ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent', app, zip_path)
        dmg_path = artifacts / (base + '.dmg')
        run('hdiutil', 'create', '-volname', f'Orbit {version}{suffix}', '-srcfolder', dmg_contents,
            '-fs', 'HFS+', '-format', 'UDZO', '-nospotlight', dmg_path)
        run('codesign', '--sign', IDENTITY, '--timestamp', dmg_path)
        run('hdiutil', 'verify', dmg_path)
        dmg_submission = None
        if notarized:
            # App notarization does not notarize its enclosing disk image.
            dmg_submission = notarize_file(dmg_path, args.notary_profile)
            verify_dmg(dmg_path)
        feed_work = stage / 'feed'
        feed_work.mkdir()
        shutil.copyfile(zip_path, feed_work / zip_path.name)
        shutil.copyfile(ROOT / 'updates/appcast.xml', feed_work / 'appcast.xml')
        shutil.copyfile(notes, feed_work / (zip_path.stem + '.txt'))
        run(sparkle / 'generate_appcast', '--account', ACCOUNT, '--maximum-deltas', '0',
            '--download-url-prefix', f'https://github.com/{REPO}/releases/download/v{version}/',
            '--embed-release-notes', feed_work)
        run(sparkle / 'sign_update', '--account', ACCOUNT, '--verify', feed_work / 'appcast.xml')
        shutil.copyfile(feed_work / 'appcast.xml', artifacts / 'appcast.xml')
        shutil.copyfile(notes, artifacts / 'ReleaseNotes.txt')
        metadata = {'version': version, 'build': info['CFBundleVersion'], 'notarized': notarized,
                    'app_notarized': notarized, 'dmg_notarized': dmg_submission is not None,
                    'dmg_submission': dmg_submission,
                    'source_commit': run('git', 'rev-parse', 'HEAD', capture=True),
                    'files': {p.name: digest(p) for p in artifacts.iterdir()}}
        (artifacts / 'release.json').write_text(json.dumps(metadata, indent=2) + '\n')
        (artifacts / 'SHA256SUMS.txt').write_text(''.join(
            f'{digest(p)}  {p.name}\n' for p in sorted(artifacts.iterdir()) if p.is_file()))
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(artifacts, output)
    print('READY:', output)
    if not notarized:
        print('TEST ONLY. Not eligible for publishing or the production update feed.')


def publish_assets(folder, tag, commit):
    releases = json.loads(run('gh', 'release', 'list', '--repo', REPO, '--limit', '100',
                             '--json', 'tagName,isDraft', capture=True))
    existing = next((release for release in releases if release['tagName'] == tag), None)
    if existing and not existing['isDraft']:
        raise RuntimeError(f'Refusing to replace published release: {tag}')
    if existing is None:
        run('gh', 'release', 'create', tag, '--repo', REPO, '--target', commit, '--draft')
    # Keep the release private until every verified artifact has uploaded.
    run('gh', 'release', 'upload', tag, *sorted(folder.iterdir()), '--repo', REPO, '--clobber')
    run('gh', 'release', 'edit', tag, '--repo', REPO, '--target', commit,
        '--title', 'Orbit ' + tag.removeprefix('v'), '--notes-file', folder / 'ReleaseNotes.txt',
        '--draft=false', '--latest')


def publish(args):
    folder = args.directory.resolve()
    data = json.loads((folder / 'release.json').read_text())
    if not data['notarized']:
        raise RuntimeError('Refusing to publish an unnotarized TEST package')
    for name, expected in data['files'].items():
        if digest(folder / name) != expected:
            raise RuntimeError(f'Release file changed: {name}')
    disk_images = list(folder.glob('*.dmg'))
    if len(disk_images) != 1:
        raise RuntimeError('The release must contain exactly one signed and notarized DMG')
    verify_dmg(disk_images[0])
    sparkle = tools(args.sparkle_tools)
    run(sparkle / 'sign_update', '--account', ACCOUNT, '--verify', folder / 'appcast.xml')
    run('git', 'diff', '--exit-code')
    run('git', 'diff', '--cached', '--exit-code')
    commit = run('git', 'rev-parse', 'HEAD', capture=True)
    if data['source_commit'] != commit:
        raise RuntimeError('Package the committed release source before publishing')
    if not run('git', 'ls-remote', 'origin', 'refs/heads/main', capture=True).startswith(commit):
        raise RuntimeError('Push the release commit to main before publishing')
    tag = 'v' + data['version']
    publish_assets(folder, tag, commit)
    # Publish the feed only after every release asset is available.
    shutil.copyfile(folder / 'appcast.xml', ROOT / 'updates/appcast.xml')
    run('git', 'add', 'updates/appcast.xml')
    run('git', 'commit', '-m', 'Publish Orbit ' + data['version'] + ' update feed')
    run('git', 'push', 'origin', 'main')
    print('Published:', f'https://github.com/{REPO}/releases/tag/{tag}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('build')
    notarize_parser = sub.add_parser('notarize')
    notarize_parser.add_argument('--archive', type=Path, required=True)
    package_parser = sub.add_parser('package')
    package_parser.add_argument('--app', type=Path, required=True)
    package_parser.add_argument('--sparkle-tools', type=Path)
    package_parser.add_argument('--notary-profile', default=NOTARY_PROFILE,
                                help='Saved notarytool Keychain profile (default: OrbitNotary)')
    package_parser.add_argument('--allow-unnotarized', action='store_true')
    publish_parser = sub.add_parser('publish')
    publish_parser.add_argument('directory', type=Path)
    publish_parser.add_argument('--sparkle-tools', type=Path)
    args = parser.parse_args()
    {'build': build, 'notarize': notarize, 'package': package, 'publish': publish}[args.command](args)


if __name__ == '__main__':
    main()
