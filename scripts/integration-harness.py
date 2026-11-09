#!/usr/bin/env python3
"""Reduced acceptance only. Loads a real isolated test launch agent; never run in unit tests."""
import argparse
from collections.abc import Callable
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import stat
import struct
import subprocess
import tempfile
import time
import uuid

from manifest import artifact_hash, verify_manifest


def run(args, timeout=30, check=True):
    result = subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            timeout=timeout, check=False)
    if check and result.returncode:
        raise RuntimeError('command failed: ' + Path(args[0]).name)
    return result.returncode


def wait(predicate, description, timeout=60):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            if predicate():
                return
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(0.1)
    raise RuntimeError('timeout: ' + description)


def load(path):
    return json.loads(path.read_text())


def locked(path):
    try:
        with path.open('r+') as handle:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                return False
            except BlockingIOError:
                return True
    except FileNotFoundError:
        return False


def saw_crash_presentation(runtime):
    def contains(value):
        if isinstance(value, dict):
            notice = value.get('noticePresented')
            if isinstance(notice, dict) and notice.get('_0') == 'previousCrash' and notice.get('success') is True:
                return True
            return any(contains(child) for child in value.values())
        if isinstance(value, list):
            return any(contains(child) for child in value)
        return False
    for name in ('trace-v2.jsonl.1', 'trace-v2.jsonl'):
        path = runtime / name
        if path.exists():
            for line in path.read_text().splitlines():
                try:
                    if contains(json.loads(line)):
                        return True
                except ValueError:
                    continue
    return False


def change_binary_identity(binary):
    # Change only LC_UUID in this disposable test binary; executable code is untouched.
    data = bytearray(binary.read_bytes())
    if data[:4] != b'\xcf\xfa\xed\xfe':
        raise RuntimeError('unsupported test binary architecture')
    cursor = 32
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        kind, size = struct.unpack_from('<II', data, cursor)
        if size < 8 or cursor + size > len(data):
            raise RuntimeError('invalid Mach-O')
        if kind == 0x1b and size == 24:
            data[cursor + 8] ^= 1
            temporary = binary.with_name(".harness-binary")
            temporary.write_bytes(data)
            temporary.chmod(binary.stat().st_mode & 0o777)
            os.replace(temporary, binary)
            return
        cursor += size
    raise RuntimeError('missing UUID command')


CLEANUP_GRACE_SECONDS = 5


def find_processes(executable: Path,
                   command: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> list[int]:
    """List exact executable spellings; reject incomplete or malformed listings."""
    import re
    target = str(executable.resolve())
    paths = {target, str(executable)}
    if target.startswith(('/private/var/', '/private/tmp/')):
        paths.add(target[len('/private'):])
    pattern = '^(' + '|'.join(re.escape(path) for path in sorted(paths)) + ')( |$)'
    result = command(['/usr/bin/pgrep', '-l', '-f', pattern], stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, text=True, timeout=30, check=False)
    if type(result.returncode) is not int or not isinstance(result.stdout, str):
        raise RuntimeError('unexpected pgrep result')
    if result.returncode == 1 and not result.stdout:
        return []
    if result.returncode != 0:
        raise RuntimeError('command failed: pgrep')
    if not result.stdout or not result.stdout.endswith('\n'):
        raise RuntimeError('incomplete pgrep output')
    pids = set()
    for line in result.stdout[:-1].split('\n'):
        match = re.fullmatch(r'([1-9][0-9]*) (.+)', line)
        if match is None or len(match[1]) > 10:
            raise RuntimeError('unexpected pgrep output')
        pid = int(match[1])
        arguments = match[2]
        if not 1 < pid < 2**31 or pid in pids:
            raise RuntimeError('invalid or duplicate pgrep PID')
        if not any(arguments == path or arguments.startswith(path + ' ') for path in paths):
            raise RuntimeError('unexpected pgrep command line')
        pids.add(pid)
    return sorted(pids)


def stop_processes(executable: Path,
                   command: Callable[..., subprocess.CompletedProcess] = subprocess.run,
                   send: Callable[[int, int], None] = os.kill,
                   sleep: Callable[[float], None] = time.sleep,
                   clock: Callable[[], float] = time.monotonic) -> None:
    """Stop every process of this executable by PID: SIGTERM, then SIGKILL after a grace period."""
    remaining = find_processes(executable, command)
    for number in (signal.SIGTERM, signal.SIGKILL):
        if not remaining:
            return
        for pid in remaining:
            try:
                send(pid, number)
            except ProcessLookupError:
                pass
        end = clock() + CLEANUP_GRACE_SECONDS
        remaining = find_processes(executable, command)
        while remaining and clock() < end:
            sleep(0.1)
            remaining = find_processes(executable, command)
    if remaining:
        raise RuntimeError('test processes survived SIGKILL')


def remove_bundle(bundle: Path, executable: Path,
                  command: Callable[..., subprocess.CompletedProcess] = subprocess.run,
                  send: Callable[[int, int], None] = os.kill,
                  sleep: Callable[[float], None] = time.sleep,
                  clock: Callable[[], float] = time.monotonic) -> None:
    """Remove the test bundle only after no process runs its executable."""
    stop_processes(executable, command=command, send=send, sleep=sleep, clock=clock)
    shutil.rmtree(bundle)


AGENT_KEYS = ['Label', 'ProgramArguments', 'RunAtLoad', 'KeepAlive', 'ThrottleInterval',
              'LimitLoadToSessionType', 'ProcessType', 'AssociatedBundleIdentifiers']


def parse_agent_document(data, label, executable, identifier):
    class UniqueKeys(dict):
        def __setitem__(self, key, value):
            if key in self:
                raise ValueError('duplicate plist key')
            super().__setitem__(key, value)

    document = plistlib.loads(data, dict_type=UniqueKeys)
    arguments = document.get('ProgramArguments') if isinstance(document, dict) else None
    if (not isinstance(document, dict) or list(document) != AGENT_KEYS
            or document['Label'] != label
            or not isinstance(arguments, list) or len(arguments) != 1
            or not isinstance(arguments[0], str) or not Path(arguments[0]).is_absolute()
            or Path(arguments[0]).resolve() != executable.resolve()
            or document['RunAtLoad'] is not True
            or document['KeepAlive'] != {'SuccessfulExit': False}
            or type(document['KeepAlive']['SuccessfulExit']) is not bool
            or type(document['ThrottleInterval']) is not int
            or document['ThrottleInterval'] != 10
            or document['LimitLoadToSessionType'] != 'Aqua'
            or document['ProcessType'] != 'Interactive'
            or document['AssociatedBundleIdentifiers'] != [identifier]):
        raise RuntimeError('launch agent differs from the contract')
    # A plain dict: callers edit the document, and duplicate detection only matters while parsing.
    return dict(document)


def parse_job_pid(result):
    if type(result.returncode) is not int or not isinstance(result.stdout, str):
        raise RuntimeError('malformed launchctl result')
    if result.returncode == 113:
        return None
    if result.returncode != 0:
        raise RuntimeError('launchctl print failed')
    if result.stdout and not result.stdout.endswith('\n'):
        raise RuntimeError('incomplete launchctl output')
    matches = re.findall(r'^\s*pid = ([^\n]*)$', result.stdout, re.MULTILINE)
    if not matches:
        return None
    if len(matches) != 1 or re.fullmatch(r'[1-9][0-9]{0,9}', matches[0]) is None:
        raise RuntimeError('malformed launchctl PID')
    pid = int(matches[0])
    if not 1 < pid < 2**31:
        raise RuntimeError('invalid launchctl PID')
    return pid


def owns_lock(result, pid):
    return (type(pid) is int and 1 < pid < 2**31
            and type(result.returncode) is int and result.returncode == 0
            and result.stdout == f'{pid}\n')


ISOLATED_RUNTIME_FILE = 'IsolatedRuntime.json'


def isolated_config(runtime: Path, agents: Path) -> bytes:
    """The test copy's runtime file: its own runtime and launch agents directories."""
    return json.dumps({'v': 1, 'runtimeDirectory': str(runtime),
                       'launchAgentsDirectory': str(agents)}, separators=(',', ':')).encode()


def runtime_created(runtime: Path) -> bool:
    """The app made the runtime directory: a real directory with mode 0700."""
    try:
        info = runtime.lstat()
    except FileNotFoundError:
        return False
    return stat.S_ISDIR(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o700


def distribution_source(source, root):
    source = source.absolute()
    expected = root / 'dist/MonoPods.app'
    if source.is_symlink() or source != expected or source.resolve() != expected:
        raise RuntimeError('only the local distribution artifact is accepted')
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execute', action='store_true', required=True)
    parser.add_argument('bundle', type=Path)
    options = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    source = distribution_source(options.bundle, root)
    run(['/usr/bin/codesign', '--verify', '--strict', str(source)])
    source_commit = verify_manifest(source)['sourceCommit']
    work = Path(tempfile.mkdtemp(prefix='monopods-launchagent-')).resolve()
    bundle = work / 'MonoPods-test.app'
    # The app creates the runtime directory itself, as on a first launch.
    runtime = work / 'runtime'
    agents = work / 'LaunchAgents'
    identifier = 'io.github.bernalli.monopods.test.' + uuid.uuid4().hex
    label = identifier + '.agent'
    domain = f'gui/{os.getuid()}/{label}'
    executable = bundle / 'Contents/MacOS/MonoPods'
    plist = agents / (label + '.plist')
    receipt_fd, receipt_path = tempfile.mkstemp(prefix='monopods-launchagent-receipt-', suffix='.json')
    os.close(receipt_fd)
    receipt = Path(receipt_path)
    phases = []
    clean = False
    failure = None

    def record(name):
        phases.append({'phase': name, 'observed': True})

    def control(command):
        run([str(executable), '--harness-control', command])

    def launch_direct():
        # An instance not started by its job hands over to launchd and exits 0.
        return run([str(executable)], timeout=75, check=False)

    def journal():
        return load(runtime / 'restore.json')

    def new_owner(previous=None):
        return (locked(runtime / 'owner.lock') and not journal()['lifecycle']['closedCleanly']
                and (previous is None or journal()['lifecycle']['run'] != previous))

    def job_pid():
        result = subprocess.run(['/bin/launchctl', 'print', domain], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True, timeout=30, check=False)
        return parse_job_pid(result)

    def supervised():
        # The process holding owner.lock is the job's process, so launchd started it.
        pid = job_pid()
        result = subprocess.run(['/usr/sbin/lsof', '-t', '--', str(runtime / 'owner.lock')],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                                timeout=30, check=False)
        return owns_lock(result, pid)

    def agent_document():
        if plist.is_symlink() or not plist.is_file() or plist.stat().st_mode & 0o7777 != 0o644:
            raise RuntimeError('launch agent is not a regular 0644 file')
        return parse_agent_document(plist.read_bytes(), label, executable, identifier)

    def seal():
        run(['/usr/bin/codesign', '--force', '--sign', '-', str(bundle)])
        run(['/usr/bin/env', 'python3', str(root / 'scripts/manifest.py'), 'write',
             str(bundle), source_commit])
        run(['/usr/bin/codesign', '--force', '--sign', '-', str(bundle)])
        run(['/usr/bin/codesign', '--verify', '--strict', str(bundle)])
        run(['/usr/bin/env', 'python3', str(root / 'scripts/manifest.py'), 'verify', str(bundle)])

    try:
        # H0 isolated copy.
        shutil.copytree(source, bundle, symlinks=True)
        info_path = bundle / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        info['CFBundleIdentifier'] = identifier
        info_path.write_bytes(plistlib.dumps(info))
        (bundle / 'Contents/Resources' / ISOLATED_RUNTIME_FILE).write_bytes(
            isolated_config(runtime, agents))
        seal()
        record('isolated-copy')
        # H1 first launch and login.
        if launch_direct() != 0:
            raise RuntimeError('first instance did not hand over with exit 0')
        wait(lambda: new_owner() and supervised(), 'owner started by launchd')
        if not runtime_created(runtime):
            raise RuntimeError('runtime not created with mode 0700')
        record('runtime-created')
        agent_document()
        first_bytes = plist.read_bytes()
        owner_run = journal()['lifecycle']['run']
        run(['/usr/bin/open', '-W', '-na', str(bundle)], timeout=75)
        assert journal()['lifecycle']['run'] == owner_run and supervised(), 'a second open started a second owner'
        record('first-launch-login')
        # H2 crash.
        control('crash')
        wait(lambda: new_owner(owner_run) and supervised(), 'restart after crash')
        wait(lambda: saw_crash_presentation(runtime), 'crash notice presented')
        wait(lambda: not journal()['lifecycle']['noticePending'], 'durable crash notice acknowledgement')
        record('crash-restart')
        # H3 Quit.
        control('quit')
        wait(lambda: journal()['lifecycle']['closedCleanly'] and not locked(runtime / 'owner.lock'), 'clean Quit')
        before = journal()['lifecycle']['run']
        time.sleep(11)
        assert journal()['lifecycle']['run'] == before and not locked(runtime / 'owner.lock'), 'clean Quit restarted'
        record('quit-no-restart')
        # H4 update: new executable identity and a changed plist, then an ordinary opening.
        change_binary_identity(executable)
        altered = agent_document()
        altered['ThrottleInterval'] = 11
        plist.write_bytes(plistlib.dumps(altered))
        seal()
        if launch_direct() != 0:
            raise RuntimeError('updated instance did not hand over with exit 0')
        expected_build = artifact_hash(executable)
        wait(lambda: new_owner(before) and supervised()
             and journal()['lifecycle']['build'] == expected_build, 'updated owner started by launchd')
        assert plist.read_bytes() == first_bytes, 'launch agent not restored after the update'
        record('update')
        # H5 OFF.
        owner_run = journal()['lifecycle']['run']
        control('off')
        wait(lambda: not plist.exists() and not plist.is_symlink(), 'launch agent removed')
        assert new_owner() and journal()['lifecycle']['run'] == owner_run, 'OFF ended the owner'
        record('off')
        clean = True
    except (RuntimeError, OSError, ValueError, KeyError, AssertionError,
            subprocess.TimeoutExpired) as error:
        failure = str(error)
    finally:
        if executable.exists():
            cleanup_failed = False
            failed_steps = []

            def attempt_cleanup(name, action):
                nonlocal cleanup_failed
                try:
                    result = action()
                    if isinstance(result, int) and result != 0:
                        cleanup_failed = True
                        failed_steps.append(name)
                except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
                    cleanup_failed = True
                    failed_steps.append(f'{name}: {error}')

            try:
                control('quit')
            except (RuntimeError, OSError, subprocess.TimeoutExpired):
                pass  # No owner may be left to answer; bootout and process checks decide.

            def bootout_absent():
                run(['/bin/launchctl', 'bootout', domain], check=False)
                # bootout fails when the job is not loaded; launchd may finish the removal
                # after bootout returns, so success = print reports the job absent in time.
                wait(lambda: run(['/bin/launchctl', 'print', domain], check=False) == 113,
                     'job unloaded', timeout=10)

            attempt_cleanup('bootout', bootout_absent)
            attempt_cleanup('processes', lambda: stop_processes(executable))
            if not cleanup_failed:
                attempt_cleanup('owner lock', lambda: wait(
                    lambda: not locked(runtime / 'owner.lock'), 'test owner cleanup'))
            if not cleanup_failed and (plist.exists() or plist.is_symlink()):
                attempt_cleanup('plist', plist.unlink)
            if not cleanup_failed:
                attempt_cleanup('bundle', lambda: remove_bundle(bundle, executable))
            if cleanup_failed:
                clean = False
                failure = ((failure or '') + '; cleanup incomplete ('
                           + '; '.join(failed_steps) + '); isolated artifacts retained')
        receipt.write_text(json.dumps({'v': 1, 'phases': phases, 'complete': clean,
            'failure': failure, 'isolatedRoot': str(work)}, indent=2) + '\n')
        print(str(receipt))
    if not clean:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
