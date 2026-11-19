#!/usr/bin/env python3
"""Serve signed, isolated old/new app fixtures for a real Sparkle update test.

Only modifies .build/update-e2e, never the installed Orbit app or its preferences.
Start with the tampered feed, launch installed/Orbit.app and verify rejection.
Set mode.txt to 'valid', relaunch the fixture, choose Later and verify it stays
on build 14. Check again, explicitly install/relaunch, and verify build 15.
"""
import argparse
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / '.build/update-e2e'


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def main():
    global WORK
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--sparkle-tools', type=Path, required=True)
    parser.add_argument('--identity', required=True)
    parser.add_argument('--work', type=Path, default=WORK)
    parser.add_argument('--initial-mode', choices=['valid','tampered','offline'], default='tampered')
    args = parser.parse_args()
    WORK = args.work.resolve()
    if WORK.exists():
        raise SystemExit('Test folder already exists; preserve or move the previous test before rerunning.')
    public = WORK / 'public'
    public.mkdir(parents=True)
    mode = WORK / 'mode.txt'
    mode.write_text(args.initial_mode)

    class Handler(SimpleHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/appcast.xml':
                state = mode.read_text().strip()
                if state == 'offline':
                    self.send_error(503)
                    return
                name = 'appcast.xml' if state == 'valid' else 'tampered.xml'
                body = (public / name).read_bytes()
                self.send_response(200)
                self.send_header('Content-Type', 'application/rss+xml')
                self.send_header('Cache-Control', 'no-store')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                super().do_GET()

    server = ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(public)))
    url = f'http://127.0.0.1:{server.server_port}/'
    for folder, version, build in [('installed', '0.7.0', '14'), ('candidate', '0.7.1', '15')]:
        app = WORK / folder / 'Orbit.app'
        run('ditto', '--norsrc', '--noextattr', args.app.resolve(), app)
        info = app / 'Contents/Info.plist'
        values = plistlib.loads(info.read_bytes())
        values.update(CFBundleIdentifier='studio.superless.Orbit.UpdateTest',
                      CFBundleDisplayName='Orbit Update Test',
                      CFBundleVersion=build, CFBundleShortVersionString=version,
                      SUFeedURL=url + 'appcast.xml',
                      NSAppTransportSecurity={'NSAllowsLocalNetworking': True,
                                              'NSAllowsArbitraryLoads': True})
        info.write_bytes(plistlib.dumps(values))
        run('codesign', '--force', '--sign', args.identity, '--options', 'runtime', '--timestamp', app)
        run('codesign', '--verify', '--deep', '--strict', app)
    archive = public / 'Orbit-test-update.zip'
    run('ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent', WORK / 'candidate/Orbit.app', archive)
    run(args.sparkle_tools / 'generate_appcast', '--account', 'studio.superless.Orbit',
        '--download-url-prefix', url, '--maximum-deltas', '0', '--major-version', '15', public)
    run(args.sparkle_tools / 'sign_update', '--account', 'studio.superless.Orbit', '--verify', public / 'appcast.xml')
    original = (public / 'appcast.xml').read_bytes()
    # A valid XML document with a now-invalid feed signature.
    (public / 'tampered.xml').write_bytes(original.replace(b'</title>', b' tampered</title>', 1))
    (WORK / 'server-url.txt').write_text(url)
    print('READY:', WORK / 'installed/Orbit.app', flush=True)
    print('FEED:', url, 'MODE:', mode.read_text(), flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
