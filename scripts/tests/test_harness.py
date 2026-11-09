"""Cleanup of the isolated test app, exercised only against fake process tables."""
import importlib.util
import json
import plistlib
from xml.parsers.expat import ExpatError
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location('integration_harness', SCRIPTS / 'integration-harness.py')
harness = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(harness)


class FakeSystem:
    """Process table, pgrep, kill and clock; no real process is listed or signalled."""

    def __init__(self, processes, ignored=None, listing_code=None):
        self.processes = dict(processes)
        self.ignored = ignored or {}
        self.listing_code = listing_code
        self.commands = []
        self.signals = []
        self.now = 0.0

    def run(self, args, **_):
        self.commands.append(list(args))
        if self.listing_code is not None:
            return subprocess.CompletedProcess(args, self.listing_code, stdout='')
        lines = [f'{pid} {command}' for pid, command in self.processes.items()
                 if re.search(args[-1], command)]
        return subprocess.CompletedProcess(args, 0 if lines else 1,
                                           stdout=''.join(line + '\n' for line in lines))

    def send(self, pid, number):
        self.signals.append((pid, number, self.now))
        if pid not in self.processes:
            raise ProcessLookupError(pid)
        if number not in self.ignored.get(pid, ()):
            del self.processes[pid]

    def sleep(self, seconds):
        self.now += seconds

    def clock(self):
        return self.now


class HarnessCleanupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.bundle = Path(self.temporary.name).resolve() / 'MonoPods-test.app'
        self.executable = self.bundle / 'Contents/MacOS/MonoPods'
        self.executable.parent.mkdir(parents=True)
        self.executable.write_bytes(b'test binary\n')

    def remove(self, system):
        harness.remove_bundle(self.bundle, self.executable, command=system.run, send=system.send,
                              sleep=system.sleep, clock=system.clock)

    def test_distribution_path_is_case_sensitive_and_rejects_links(self):
        root = Path(self.temporary.name).resolve()
        source = root / 'dist/MonoPods.app'
        source.mkdir(parents=True)
        self.assertEqual(harness.distribution_source(source, root), source)
        for path in (root / 'dist/monoPods.app', root / 'MonoPods.app'):
            with self.subTest(path=path), self.assertRaises(RuntimeError):
                harness.distribution_source(path, root)
        real = root / 'real.app'
        source.rename(real)
        source.symlink_to(real)
        with self.assertRaises(RuntimeError):
            harness.distribution_source(source, root)
        source.unlink()
        (root / 'dist').rmdir()
        outside = root / 'outside'
        (outside / 'MonoPods.app').mkdir(parents=True)
        (root / 'dist').symlink_to(outside)
        with self.assertRaises(RuntimeError):
            harness.distribution_source(source, root)

    def test_matching_processes_are_terminated_with_sigterm_before_removal(self):
        system = FakeSystem({41: str(self.executable),
                             42: str(self.executable) + ' --harness-control quit'})
        self.remove(system)
        self.assertEqual([(pid, number) for pid, number, _ in system.signals],
                         [(41, signal.SIGTERM), (42, signal.SIGTERM)])
        self.assertFalse(self.bundle.exists())

    def test_listing_handles_path_aliases_arguments_and_hostile_ordering(self):
        target = Path('/private/var/folders/review/MonoPods-test.app/Contents/MacOS/MonoPods')
        for path in (str(target), str(target)[len('/private'):]):
            for order in ((41, 42), (42, 41)):
                system = FakeSystem({pid: path + ' --agent' for pid in order})
                harness.stop_processes(target, command=system.run, send=system.send,
                                       sleep=system.sleep, clock=system.clock)
                self.assertFalse(system.processes)
                self.assertEqual({pid for pid, _, _ in system.signals}, {41, 42})

    def test_malformed_listings_retain_bundle_without_signalling(self):
        valid = '123 ' + str(self.executable) + '\n'
        cases = [(0, valid[:end]) for end in range(len(valid))]
        cases += [(0, valid * 2), (0, '0 ' + str(self.executable) + '\n'),
                  (0, '-1 ' + str(self.executable) + '\n'),
                  (0, '2147483648 ' + str(self.executable) + '\n'),
                  (0, '² ' + str(self.executable) + '\n'), (0, '123\n'),
                  (0, '123 extra ' + str(self.executable) + '\n'),
                  (0, None), (False, ''), (1, valid), (2, '')]
        for code, output in cases:
            with self.subTest(code=code, output=output):
                system = FakeSystem({})
                system.run = lambda *args, **kwargs: subprocess.CompletedProcess(
                    args, code, stdout=output)
                with self.assertRaises(RuntimeError):
                    self.remove(system)
                self.assertEqual(system.signals, [])
                self.assertTrue(self.executable.exists())

    def test_processes_that_only_resemble_the_executable_are_never_signalled(self):
        path = str(self.executable)
        system = FakeSystem({
            51: '/usr/bin/tail -f ' + path,
            52: path + '-helper',
            53: path.replace('MonoPods-test.app', 'MonoPods-testXapp'),
            54: path.replace('/MonoPods', '/MonoPodsHelper'),
        })
        self.remove(system)
        self.assertEqual(system.signals, [])
        self.assertFalse(self.bundle.exists())

    def test_sigterm_survivor_receives_sigkill_after_the_grace_period(self):
        system = FakeSystem({61: str(self.executable)}, ignored={61: {signal.SIGTERM}})
        self.remove(system)
        self.assertEqual([(pid, number) for pid, number, _ in system.signals],
                         [(61, signal.SIGTERM), (61, signal.SIGKILL)])
        self.assertGreaterEqual(system.signals[1][2], harness.CLEANUP_GRACE_SECONDS)
        self.assertFalse(self.bundle.exists())

    def test_sigkill_survivor_is_an_error_and_the_bundle_is_retained(self):
        system = FakeSystem({71: str(self.executable)},
                            ignored={71: {signal.SIGTERM, signal.SIGKILL}})
        with self.assertRaises(RuntimeError):
            self.remove(system)
        self.assertEqual([(pid, number) for pid, number, _ in system.signals],
                         [(71, signal.SIGTERM), (71, signal.SIGKILL)])
        self.assertTrue(self.executable.exists())

    def test_no_matching_process_sends_no_signal(self):
        system = FakeSystem({81: '/usr/bin/unrelated'})
        self.remove(system)
        self.assertEqual(system.signals, [])
        self.assertFalse(self.bundle.exists())

    def test_process_that_exits_before_its_signal_is_not_an_error(self):
        system = FakeSystem({91: str(self.executable)})
        original = system.send

        def exits_first(pid, number):
            system.processes.pop(pid, None)
            original(pid, number)

        system.send = exits_first
        self.remove(system)
        self.assertFalse(self.bundle.exists())

    def test_listing_failure_is_an_error_and_the_bundle_is_retained(self):
        system = FakeSystem({}, listing_code=2)
        with self.assertRaises(RuntimeError):
            self.remove(system)
        self.assertEqual(system.signals, [])
        self.assertTrue(self.executable.exists())


class HarnessAgentDocumentTests(unittest.TestCase):
    def test_closed_agent_contract_rejects_malformed_families(self):
        label, identifier = 'test.agent', 'test'
        executable = Path('/isolated/MonoPods')
        valid = dict(zip(harness.AGENT_KEYS, [
            label, [str(executable)], True, {'SuccessfulExit': False}, 10,
            'Aqua', 'Interactive', [identifier]]))

        def parse(data):
            return harness.parse_agent_document(data, label, executable, identifier)

        def encode(value):
            return plistlib.dumps(value, sort_keys=False)

        raw = encode(valid).rstrip()
        self.assertEqual(parse(raw), valid)
        # The update phase edits the parsed document before writing it back.
        edited = parse(raw)
        edited['ThrottleInterval'] = 11
        self.assertIs(type(edited), dict)
        documents = [[], dict(valid, extra=True), dict(reversed(list(valid.items())))]
        for key in valid:
            documents.append({k: v for k, v in valid.items() if k != key})
            for value in (False, 1, '', [], {}):
                if type(value) is not type(valid[key]) or value != valid[key]:
                    documents.append(dict(valid, **{key: value}))
        for value in (-1, 0, 11):
            documents.append(dict(valid, ThrottleInterval=value))
        documents.extend([
            dict(valid, ProgramArguments=[str(executable), str(executable)]),
            dict(valid, ProgramArguments=['isolated/MonoPods']),
            dict(valid, KeepAlive={'SuccessfulExit': 0}),
            dict(valid, KeepAlive={'SuccessfulExit': False, 'extra': True})])
        malformed = [encode(value) for value in documents]
        malformed += [raw[:end] for end in range(len(raw))]
        for key, value in [('Label', '<string>wrong</string>'),
                           ('SuccessfulExit', '<true/>')]:
            marker = ('<key>' + key + '</key>').encode()
            malformed.append(raw.replace(marker, marker + value.encode() + marker, 1))
        for data in malformed:
            with self.subTest(data=data[:80]):
                with self.assertRaises((RuntimeError, ValueError, ExpatError)):
                    parse(data)


class HarnessProcessEvidenceTests(unittest.TestCase):
    def test_job_pid_rejects_malformed_results(self):
        def result(code, output):
            return subprocess.CompletedProcess([], code, stdout=output)
        self.assertEqual(harness.parse_job_pid(result(0, 'state = running\n pid = 42\n')), 42)
        self.assertIsNone(harness.parse_job_pid(result(0, 'state = waiting\n')))
        self.assertIsNone(harness.parse_job_pid(result(113, '')))
        for code, output in [(False, ''), (5, ''), (0, None),
                             (0, ' pid = 42\n pid = 43\n'), (0, ' pid = 42'),
                             *[(0, ' pid = ' + value + '\n')
                               for value in ('0', '1', '-2', '2147483648', '²', '42 extra')]]:
            with self.subTest(code=code, output=output):
                with self.assertRaises(RuntimeError):
                    harness.parse_job_pid(result(code, output))

    def test_lock_evidence_requires_success_and_one_complete_pid(self):
        def result(code, output):
            return subprocess.CompletedProcess([], code, stdout=output)
        self.assertTrue(harness.owns_lock(result(0, '42\n'), 42))
        for code, output in [(1, '42\n'), (False, '42\n'), (0, None),
                             (0, ''), (0, '42'), (0, '43\n'), (0, '42\n42\n')]:
            self.assertFalse(harness.owns_lock(result(code, output), 42))



class HarnessIsolatedRuntimeTests(unittest.TestCase):
    def test_isolated_config_names_only_the_two_directories(self):
        runtime = Path('/private/tmp/monopods-x/runtime')
        agents = Path('/private/tmp/monopods-x/LaunchAgents')
        data = harness.isolated_config(runtime, agents)
        self.assertIsInstance(data, bytes)
        document = json.loads(data)
        self.assertEqual(set(document), {'v', 'runtimeDirectory', 'launchAgentsDirectory'})
        self.assertIs(type(document['v']), int)
        self.assertEqual(document['v'], 1)
        self.assertEqual(document['runtimeDirectory'], str(runtime))
        self.assertEqual(document['launchAgentsDirectory'], str(agents))
        self.assertEqual(harness.ISOLATED_RUNTIME_FILE, 'IsolatedRuntime.json')

    def test_the_app_creates_the_runtime_directory(self):
        source = (SCRIPTS / 'integration-harness.py').read_text()
        self.assertNotIn('runtime.mkdir', source)
        # Split so that a repository search for the retired file name finds nothing.
        self.assertNotIn('Runtime' 'Config', source)
        with tempfile.TemporaryDirectory() as temporary:
            runtime = Path(temporary) / 'runtime'
            self.assertFalse(harness.runtime_created(runtime))
            runtime.mkdir(mode=0o755)
            runtime.chmod(0o755)
            self.assertFalse(harness.runtime_created(runtime))
            runtime.chmod(0o700)
            self.assertTrue(harness.runtime_created(runtime))
            link = Path(temporary) / 'link'
            link.symlink_to(runtime)
            self.assertFalse(harness.runtime_created(link))

    def test_the_isolated_copy_preserves_framework_links(self):
        source = (SCRIPTS / 'integration-harness.py').read_text()
        self.assertEqual(source.count('shutil.copytree('), 1)
        self.assertIn('shutil.copytree(source, bundle, symlinks=True)', source)


if __name__ == '__main__':
    unittest.main()
