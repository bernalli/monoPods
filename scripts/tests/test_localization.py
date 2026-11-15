"""Localization tables: strict format, the same keys in every language, placeholders, coverage."""
import json
from pathlib import Path
import plistlib
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
LOCALIZATION = ROOT / 'Resources/Localization'
SOURCES = ROOT / 'Sources'
LANGUAGES = ('en', 'it', 'es', 'fr', 'de', 'pt-BR', 'ja', 'zh-Hans')
ENGLISH = 'en'
# Closed list of the tables in every language folder.
TABLES = ('Localizable', 'InfoPlist', 'AppleStyleUpdateDriver')
# Tables whose English values are their keys.
KEYED_BY_ENGLISH = ('Localizable', 'AppleStyleUpdateDriver')
# The update driver reads its own table, shared verbatim with another app.
DRIVER = SOURCES / 'MonoPods/AppleStyleUpdateDriver.swift'
DRIVER_TABLE = 'AppleStyleUpdateDriver'
BLUETOOTH_KEYS = ('NSBluetoothAlwaysUsageDescription', 'NSBluetoothPeripheralUsageDescription')
# Texts shared verbatim with another app, copied from its tables.
SHARED_FIXTURE = ROOT / 'scripts/tests/fixtures/shared-texts.json'
FIXTURE_TABLES = ('AppleStyleUpdateDriver', 'Localizable')
# Closed list of English values that differ from their key: (table, key) -> value.
ENGLISH_VALUES = {('Localizable', "Don't Check"): 'Don’t Check'}
# Closed list of the values that stay English in one language: (language, key), in every table
# that has the key.
SAME_AS_ENGLISH = {
    ('it', 'Mono'), ('es', 'Mono'), ('fr', 'Mono'), ('de', 'Mono'), ('pt-BR', 'Mono'),
    ('it', 'Stereo'), ('de', 'Stereo'),
    ('fr', 'Options'), ('de', 'Details'), ('de', 'Status: %@'),
    ('it', 'OK'), ('fr', 'OK'), ('de', 'OK'), ('pt-BR', 'OK'), ('ja', 'OK'),
}
# Visible texts that are also state: the code compares them and writes them to logs, so they
# stay English in the source and are translated only where they are shown.
STATE_TEXTS = {
    'Sources/MonoPodsRuntime/RuntimeHost.swift': (
        'Starting', 'Observing', 'Waiting for verified stream transport',
        'Automation blocked; recovery evidence needs review', 'Waiting for the command owner',
        'Configuration, manifest or runtime evidence is invalid. Automation is blocked.',
        'Diagnostic persistence failed',
        'Move MonoPods to Applications to launch at login.',
        'The login item could not be updated.',
        'Automatic restart is not active until the next login.',
        'No Bluetooth output',
    ),
    'Sources/MonoPodsRuntime/UpdatePolicy.swift': (
        'An update is being installed. MonoPods restarts when the new version is in place.',
    ),
    'Sources/MonoPodsRuntime/NoticePresenter.swift': (
        'MonoPods restarted after an error or an incomplete quit.',
        'Automatic Ear Detection is off. Turn it on in Bluetooth Settings to use MonoPods.',
        'If you stop using MonoPods, turn Automatic Ear Detection off in Bluetooth Settings.',
        'Runtime evidence could not be saved. Automation is blocked.',
        'Command order cannot be established. Automation and recovery are blocked.',
        'MonoPods did not confirm the return to Stereo. Mono may stay on. Reopen MonoPods to try '
        'again.',
        'An audio command failed repeatedly. Automatic attempts for this target are blocked. If '
        'switching does not resume, quit and reopen MonoPods.',
    ),
}
# The About window stays in English in every language: its texts are literals, never looked up.
ABOUT = SOURCES / 'MonoPodsRuntime/AboutWindow.swift'
ABOUT_TEXTS = {
    'windowTitle': 'About MonoPods', 'gitHubHelp': 'View MonoPods on GitHub',
    'sponsor': 'Buy Me a Coffee',
}
# Keys that only the About window used; the menu keeps `About %@`.
ABOUT_ONLY_KEYS = ('Buy Me a Coffee', 'View %@ on GitHub')
MENU_KEYS_SHARED_WITH_ABOUT = ('About %@',)
# The version lines never show the build number, so no table has a key for it.
BUILD_VERSION_KEYS = ('Version %@ (%@)', 'Version Unavailable (Build %@)')
# Details lines that join a label and a fixed value are whole-sentence keys, so the value agrees
# with the label's noun; the composed keys and the bare value they used are gone.
REMOVED_KEYS = (
    'Automatic Ear Detection: %@', 'None',
    # The menu shows one reason or remedy under the summary; the old warnings are gone.
    'Accessibility Mono Audio: %@',
    'AirPods Max have no ear detection, so MonoPods cannot switch.',
    'Needs Attention',
    'System Mono Audio is on; automatic switching is paused.',
    'The last audio change failed. See Details for the command result.',
    'Turn on Automatic Ear Detection in Bluetooth Settings to use MonoPods.',
    'Waiting for MonoPods…',
    'Waiting for a reliable ear detection connection.',
    # The menu has no version row, and no line under Launch at Login when it works.
    'Version %@', 'Version Unavailable', 'Applies from the next login.',
    # The update checks switch has the other app's name.
    'Automatic Updates',
    # Automation Blocked names the remedy.
    'Automatic switching is blocked; recovery evidence needs review.',
)
# Closed list of reviewed values: (language, table, key) -> value.
REVIEWED_VALUES = {
    ('it', 'Localizable', 'Automatic Ear Detection: On'): 'Rilevamento automatico dell’orecchio: Attivato',
    ('it', 'Localizable', 'Automatic Ear Detection: Off'):
        'Rilevamento automatico dell’orecchio: Disattivato',
    ('it', 'Localizable', 'Automatic Ear Detection: Unknown'):
        'Rilevamento automatico dell’orecchio: Sconosciuto',
    ('it', 'Localizable', 'Audio Output: None'): 'Uscita audio: Nessuna',
    ('it', 'Localizable', 'Model: None'): 'Modello: Nessuno',
    ('es', 'Localizable', 'Automatic Ear Detection: On'): 'Detección automática de oreja: Activada',
    ('es', 'Localizable', 'Automatic Ear Detection: Off'):
        'Detección automática de oreja: Desactivada',
    ('es', 'Localizable', 'Automatic Ear Detection: Unknown'):
        'Detección automática de oreja: Desconocida',
    ('es', 'Localizable', 'Audio Output: None'): 'Salida de audio: Ninguna',
    ('es', 'Localizable', 'Model: None'): 'Modelo: Ninguno',
    ('fr', 'Localizable', 'Automatic Ear Detection: On'):
        'Détection automatique des oreilles\u00a0: Activée',
    ('fr', 'Localizable', 'Automatic Ear Detection: Off'):
        'Détection automatique des oreilles\u00a0: Désactivée',
    ('fr', 'Localizable', 'Automatic Ear Detection: Unknown'):
        'Détection automatique des oreilles\u00a0: Inconnue',
    ('fr', 'Localizable', 'Audio Output: None'): 'Sortie audio\u00a0: Aucune',
    ('fr', 'Localizable', 'Model: None'): 'Modèle\u00a0: Aucun',
    ('de', 'Localizable', 'Automatic Ear Detection: On'): 'Automatische Ohrerkennung: Ein',
    ('de', 'Localizable', 'Automatic Ear Detection: Off'): 'Automatische Ohrerkennung: Aus',
    ('de', 'Localizable', 'Automatic Ear Detection: Unknown'): 'Automatische Ohrerkennung: Unbekannt',
    ('de', 'Localizable', 'Audio Output: None'): 'Audioausgabe: Keine',
    ('de', 'Localizable', 'Model: None'): 'Modell: Keines',
    ('pt-BR', 'Localizable', 'Automatic Ear Detection: On'): 'Detecção automática de ouvido: Ativada',
    ('pt-BR', 'Localizable', 'Automatic Ear Detection: Off'):
        'Detecção automática de ouvido: Desativada',
    ('pt-BR', 'Localizable', 'Automatic Ear Detection: Unknown'):
        'Detecção automática de ouvido: Desconhecida',
    ('pt-BR', 'Localizable', 'Audio Output: None'): 'Saída de áudio: Nenhuma',
    ('pt-BR', 'Localizable', 'Model: None'): 'Modelo: Nenhum',
    ('es', 'Localizable', 'Automatic Ear Detection Off'): 'Detección automática de oreja desactivada',
    ('es', 'Localizable',
     'Automatic Ear Detection is off. Turn it on in Bluetooth Settings to use MonoPods.'):
        'La detección automática de oreja está desactivada. Actívala en los ajustes de Bluetooth '
        'para usar MonoPods.',
    ('es', 'Localizable',
     'If you stop using MonoPods, turn Automatic Ear Detection off in Bluetooth Settings.'):
        'Si dejas de usar MonoPods, desactiva la detección automática de oreja en los ajustes de '
        'Bluetooth.',
    ('fr', 'Localizable', 'Automatic Ear Detection Off'):
        'Détection automatique des oreilles désactivée',
    ('fr', 'Localizable',
     'Automatic Ear Detection is off. Turn it on in Bluetooth Settings to use MonoPods.'):
        'La détection automatique des oreilles est désactivée. Activez-la dans les réglages '
        'Bluetooth pour utiliser MonoPods.',
    ('fr', 'Localizable',
     'If you stop using MonoPods, turn Automatic Ear Detection off in Bluetooth Settings.'):
        'Si vous n’utilisez plus MonoPods, désactivez la détection automatique des oreilles dans '
        'les réglages Bluetooth.',
    ('fr', 'Localizable', 'Launch at Login'): 'Ouvrir avec la session',
    ('ja', 'Localizable', 'Launch at Login'): 'ログイン時に開く',
    ('zh-Hans', 'Localizable', 'Launch at Login'): '登录时打开',
    ('zh-Hans', 'Localizable', 'Resume Without Updating?'): '是否不更新并继续？',
    # The exit status of the last command is named in full.
    ('it', 'Localizable', '%@ (Exit %@)'): '%@ (codice di uscita %@)',
    ('es', 'Localizable', '%@ (Exit %@)'): '%@ (código de salida %@)',
    ('fr', 'Localizable', '%@ (Exit %@)'): '%@ (code de sortie %@)',
    ('pt-BR', 'Localizable', '%@ (Exit %@)'): '%@ (código de saída %@)',
}
# es and fr name ear detection as Apple does: «de oreja», «des oreilles».
EAR_DETECTION_TERMS = {'es': ('de oído', 'de oreja'), 'fr': ('de l’oreille', 'des oreilles')}

# Keys whose values are shared verbatim with another app; their style is decided there.
SHARED_KEYS = (
    '%@ can check for new versions once a day. You can change this at any time in Options.',
    'About %@', 'Check Automatically', 'Check for Updates Automatically',
    'Check for Updates Automatically?', 'Check for Updates…', "Don't Check",
    'Hide Menu Bar Icon', 'Launch at Login', 'Open %@ again to bring it back.', 'Options',
    'Quit %@', 'Report an Issue…',
)
# French puts a no-break space before these marks.
FRENCH_HIGH_MARKS = ':;?!'
# Closed list of texts that name a menu item: the text contains the item's title, identical.
MENU_REFERENCES = {
    'See Details for the command result.': 'Details',
    'Quit and reopen MonoPods. If it stays blocked, choose Report an Issue…': 'Report an Issue…',
}
# The label of the Details line and the reason of Switching Paused name the same setting.
MONO_AUDIO_LINE = 'Mono Audio: %@'
MONO_AUDIO_REASON = 'Mono Audio is on in Accessibility settings.'
LABEL_END = ' \u00a0\u202f:：'

# The only files that may pass a value, not a literal, to Localized.
NON_LITERAL_FILES = ('MenuPresentation.swift', 'MenuLayout.swift', 'NoticePresenter.swift')

STRING_BODY = r'((?:[^"\\]|\\["\\n])*)'
LINE = re.compile(rf'"{STRING_BODY}" = "{STRING_BODY}";')
STRINGS_ESCAPE = re.compile(r'\\(["\\n])')
POSITIONAL = re.compile(r'%([1-9][0-9]*)\$@')
UNICODE_ESCAPE = re.compile(r'\{([0-9A-Fa-f]{1,8})\}')
CALL = re.compile(r'\bLocalized\.(?:text|format)\(')
DRIVER_CALL = re.compile(r'(?<!func )\blocalized\(')
SWIFT_ESCAPES = {'"': '"', '\\': '\\', 'n': '\n'}


class StringsError(ValueError):
    """A table or an entry outside the strict format."""


def unescape_strings(text: str) -> str:
    """Decode the three escapes a table may use."""
    return STRINGS_ESCAPE.sub(lambda match: '\n' if match[1] == 'n' else match[1], text)


def parse_strings(data: bytes) -> list[tuple[str, str]]:
    """Parse a strict `.strings` table: UTF-8 without BOM, one sorted `"k" = "v";` per line."""
    if data.startswith(b'\xef\xbb\xbf'):
        raise StringsError('byte order mark')
    if not data or not data.endswith(b'\n') or b'\r' in data:
        raise StringsError('line endings')
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError as error:
        raise StringsError('not UTF-8') from error
    if '\x00' in text:
        raise StringsError('not UTF-8 text')
    entries: list[tuple[str, str]] = []
    for line in text[:-1].split('\n'):
        match = LINE.fullmatch(line)
        if match is None:
            raise StringsError(f'malformed line: {line!r}')
        entries.append((unescape_strings(match[1]), unescape_strings(match[2])))
    keys = [key for key, _ in entries]
    if len(set(keys)) != len(keys):
        raise StringsError('duplicate key')
    if keys != sorted(keys, key=lambda key: key.encode('utf-8')):
        raise StringsError('keys out of order')
    return entries


def placeholders(text: str) -> tuple[bool, list[int]]:
    """Return (positional, indices) of the `%@` and `%n$@` placeholders; `%%` is a literal."""
    simple = 0
    positional: list[int] = []
    index = 0
    while index < len(text):
        if text[index] != '%':
            index += 1
            continue
        if text.startswith('%%', index):
            index += 2
        elif text.startswith('%@', index):
            simple += 1
            index += 2
        elif (match := POSITIONAL.match(text, index)) is not None:
            positional.append(int(match[1]))
            index = match.end()
        else:
            raise StringsError(f'placeholder not allowed: {text!r}')
    if simple and positional:
        raise StringsError(f'simple and positional placeholders mixed: {text!r}')
    if positional:
        if sorted(positional) != list(range(1, len(positional) + 1)):
            raise StringsError(f'positional indices are not 1...n once each: {text!r}')
        return True, positional
    return False, list(range(1, simple + 1))


def check_entry(key: str, value: str) -> None:
    """Value rules of one entry: not empty, no outer spaces, the placeholders of its key."""
    if not value or value != value.strip():
        raise StringsError(f'empty value or outer spaces: {key!r}')
    key_positional, key_indices = placeholders(key)
    value_positional, value_indices = placeholders(value)
    if key_positional and not value_positional:
        raise StringsError(f'positional key with simple value: {key!r}')
    if sorted(value_indices) != sorted(key_indices):
        raise StringsError(f'placeholders differ from the key: {key!r}')


def validate(data: bytes) -> list[tuple[str, str]]:
    """The whole check of a table: the format, then every entry."""
    entries = parse_strings(data)
    for key, value in entries:
        check_entry(key, value)
    return entries


def _refuse_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
    keys = [key for key, _ in pairs]
    if len(set(keys)) != len(keys):
        raise StringsError('duplicate key in the shared fixture')
    return dict(pairs)


def load_shared_fixture(data: bytes) -> dict[str, dict[str, dict[str, str]]]:
    """The shared texts: exactly the tables and languages, one key set per table, text values."""
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError as error:
        raise StringsError('shared fixture is not UTF-8') from error
    try:
        document = json.loads(text, object_pairs_hook=_refuse_duplicates)
    except json.JSONDecodeError as error:
        raise StringsError(f'shared fixture is not one JSON document: {error}') from error
    if not isinstance(document, dict) or sorted(document) != sorted(FIXTURE_TABLES):
        raise StringsError('shared fixture tables')
    for name in FIXTURE_TABLES:
        languages = document[name]
        if not isinstance(languages, dict) or sorted(languages) != sorted(LANGUAGES):
            raise StringsError(f'shared fixture languages of {name}')
        keys = None
        for language in LANGUAGES:
            entries = languages[language]
            if not isinstance(entries, dict) or not entries:
                raise StringsError(f'shared fixture entries of {name} {language}')
            for value in entries.values():
                if not isinstance(value, str) or not value:
                    raise StringsError(f'shared fixture value in {name} {language}')
            if keys is None:
                keys = sorted(entries)
            elif sorted(entries) != keys:
                raise StringsError(f'shared fixture keys of {name} {language}')
        for key, value in languages[ENGLISH].items():
            if value != ENGLISH_VALUES.get((name, key), key):
                raise StringsError(f'shared fixture English value of {key!r}')
    return document


def table_path(language: str, name: str) -> Path:
    return LOCALIZATION / f'{language}.lproj' / f'{name}.strings'


def table(language: str, name: str) -> dict[str, str]:
    return dict(parse_strings(table_path(language, name).read_bytes()))


def swift_sources() -> list[Path]:
    return sorted(SOURCES.rglob('*.swift'))


def swift_literal(source: str, start: int) -> tuple[str, int]:
    """Decode the Swift string literal at `start`; refuse interpolation and other escapes."""
    if source.startswith('"""', start):
        raise StringsError('multi-line literal')
    if source[start] != '"':
        raise StringsError('not a literal')
    result: list[str] = []
    index = start + 1
    while index < len(source):
        character = source[index]
        if character == '"':
            return ''.join(result), index + 1
        if character == '\n':
            raise StringsError('unterminated literal')
        if character != '\\':
            result.append(character)
            index += 1
            continue
        escape = source[index + 1] if index + 1 < len(source) else ''
        if escape in SWIFT_ESCAPES:
            result.append(SWIFT_ESCAPES[escape])
            index += 2
        elif escape == 'u' and (match := UNICODE_ESCAPE.match(source, index + 2)) is not None:
            result.append(chr(int(match[1], 16)))
            index = match.end()
        else:
            raise StringsError(f'escape not allowed: \\{escape}')
    raise StringsError('unterminated literal')


def localized_calls() -> tuple[set[str], list[Path]]:
    """Literal keys passed to `Localized.text(` and `Localized.format(`, and files with others."""
    keys: set[str] = set()
    non_literal: list[Path] = []
    for path in swift_sources():
        source = path.read_text()
        for match in CALL.finditer(source):
            start = match.end()
            while source[start] in ' \n':
                start += 1
            if source[start] == '"':
                keys.add(swift_literal(source, start)[0])
            else:
                non_literal.append(path)
    return keys, non_literal


def driver_calls() -> tuple[set[str], int]:
    """Literal keys passed to `localized(` in the driver file, and the count of other calls."""
    keys: set[str] = set()
    non_literal = 0
    source = DRIVER.read_text()
    for match in DRIVER_CALL.finditer(source):
        start = match.end()
        while source[start] in ' \n':
            start += 1
        if source[start] == '"':
            keys.add(swift_literal(source, start)[0])
        else:
            non_literal += 1
    return keys, non_literal


def state_texts() -> set[str]:
    return {text for texts in STATE_TEXTS.values() for text in texts}


class ParserTests(unittest.TestCase):
    """L0: the strict parser and the source extractor refuse every malformed input."""

    VALID = '"About %@" = "Informazioni su %@";\n"Options" = "Opzioni";\n'

    def test_a_valid_table_parses(self):
        self.assertEqual(validate(self.VALID.encode()),
                         [('About %@', 'Informazioni su %@'), ('Options', 'Opzioni')])

    def test_the_three_escapes_decode(self):
        self.assertEqual(validate(b'"a\\"b\\\\c\\nd" = "x\\"y\\\\z\\nw";\n'),
                         [('a"b\\c\nd', 'x"y\\z\nw')])

    def test_reordered_positional_value_and_literal_percent_pass(self):
        self.assertEqual(validate(b'"%@ of %@" = "%2$@ di %1$@ al 100%%";\n'),
                         [('%@ of %@', '%2$@ di %1$@ al 100%%')])

    def test_malformed_inputs_are_rejected(self):
        cases = {
            'duplicate key': b'"Options" = "Opzioni";\n"Options" = "Opzioni";\n',
            'missing semicolon': b'"Options" = "Opzioni"\n',
            'unescaped quote': b'"Options" = "Op"zioni";\n',
            'byte order mark': b'\xef\xbb\xbf"Options" = "Opzioni";\n',
            'UTF-16': '"Options" = "Opzioni";\n'.encode('utf-16'),
            'UTF-16 without BOM': '"Options" = "Opzioni";\n'.encode('utf-16-le'),
            'CRLF': b'"Options" = "Opzioni";\r\n',
            'block comment line': b'/* note */\n"Options" = "Opzioni";\n',
            'line comment': b'// note\n"Options" = "Opzioni";\n',
            'empty line': b'"Options" = "Opzioni";\n\n',
            'trailing space': b'"Options" = "Opzioni"; \n',
            'leading space': b' "Options" = "Opzioni";\n',
            'value with an outer space': b'"Options" = "Opzioni ";\n',
            'empty value': b'"Options" = "";\n',
            'missing final newline': b'"Options" = "Opzioni";',
            'empty file': b'',
            'unsorted keys': b'"Options" = "Opzioni";\n"About %@" = "Informazioni su %@";\n',
            'other escape': b'"Options" = "Op\\tzioni";\n',
            'one placeholder too many': b'"Options" = "Opzioni %@";\n',
            'one placeholder too few': b'"About %@" = "Informazioni";\n',
            'repeated positional': b'"%@ and %@" = "%1$@ e %1$@";\n',
            'positional gap': b'"%@ and %@" = "%1$@ e %3$@";\n',
            'simple and positional mixed': b'"%@ and %@" = "%@ e %2$@";\n',
            'positional key, simple value': b'"%1$@ and %2$@" = "%@ e %@";\n',
            'integer placeholder': b'"Count %@" = "Conteggio %d";\n',
            'lone percent': b'"Rate" = "Tasso %";\n',
        }
        for name, data in cases.items():
            with self.subTest(case=name):
                with self.assertRaises(StringsError):
                    validate(data)

    def test_swift_extractor_decodes_the_allowed_escapes(self):
        source = '"Check\\u{2026} \\"a\\" \\\\ \\n"'
        self.assertEqual(swift_literal(source, 0), ('Check… "a" \\ \n', len(source)))

    def test_swift_extractor_refuses_interpolation_other_escapes_and_multiline(self):
        for source in ('"a\\(b)"', '"a\\tb"', '"""\na\n"""', '"a\nb"', '"a'):
            with self.subTest(source=source):
                with self.assertRaises(StringsError):
                    swift_literal(source, 0)

    def test_generated_tables_reject_structural_and_placeholder_mutations(self):
        for count in range(1, 33):
            key = f'K{count:02} è ' + ' '.join(['%@'] * count)
            value = 'V ' + ' '.join(
                f'%{i}$@' for i in range(count, 0, -1))
            row = f'"{key}" = "{value}";\n'.encode()
            other = b'"Z" = "z";\n'
            self.assertEqual(validate(row), [(key, value)])
            self.assertEqual(len(validate(row + other)), 2)

            malformed = [
                row + row,
                other + row,
                row + b'extra\n',
                row.replace(b' = ', b' ', 1),
                row.replace(b' = ', b' = 0 ', 1),
            ]
            malformed += [row[:end] for end in range(len(row))]
            malformed += [
                row[:end] + b'\n' for end in range(len(row) - 1)
            ]
            for data in malformed:
                with self.subTest(count=count, data=data):
                    with self.assertRaises(StringsError):
                        validate(data)

            replacements = [
                '', '%d', '%',
                ' '.join(['%@'] * (count + 1)),
                ' '.join(f'%{i}$@' for i in range(2, count + 2)),
            ]
            for replacement in replacements:
                data = f'"{key}" = "{replacement}";\n'.encode()
                with self.subTest(count=count, value=replacement):
                    with self.assertRaises(StringsError):
                        validate(data)


class LocalizationTableTests(unittest.TestCase):
    def test_l1_exactly_the_languages_and_tables_as_regular_files(self):
        self.assertTrue(LOCALIZATION.is_dir() and not LOCALIZATION.is_symlink())
        folders = sorted(path.name for path in LOCALIZATION.iterdir())
        self.assertEqual(folders, sorted(f'{language}.lproj' for language in LANGUAGES))
        for language in LANGUAGES:
            folder = LOCALIZATION / f'{language}.lproj'
            with self.subTest(language=language):
                self.assertTrue(folder.is_dir() and not folder.is_symlink())
                self.assertEqual(sorted(path.name for path in folder.iterdir()),
                                 sorted(f'{name}.strings' for name in TABLES))
                for name in TABLES:
                    path = table_path(language, name)
                    self.assertTrue(path.is_file() and not path.is_symlink(), path)

    def test_l2_every_table_has_the_strict_format_and_passes_plutil(self):
        for language in LANGUAGES:
            for name in TABLES:
                path = table_path(language, name)
                with self.subTest(path=path.relative_to(ROOT)):
                    parse_strings(path.read_bytes())
                    result = subprocess.run(['plutil', '-lint', str(path)],
                                            capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_l3_same_keys_everywhere_and_english_values(self):
        info = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
        for name in TABLES:
            english = table(ENGLISH, name)
            for language in LANGUAGES:
                with self.subTest(table=name, language=language):
                    self.assertEqual(sorted(table(language, name)), sorted(english))
            if name in KEYED_BY_ENGLISH:
                for key, value in english.items():
                    with self.subTest(table=name, key=key):
                        self.assertEqual(value, ENGLISH_VALUES.get((name, key), key))
        plist = table(ENGLISH, 'InfoPlist')
        self.assertEqual(sorted(plist), sorted(BLUETOOTH_KEYS))
        for key in BLUETOOTH_KEYS:
            with self.subTest(key=key):
                self.assertEqual(plist[key], info[key])

    def test_l4_placeholders_match_the_key(self):
        for language in LANGUAGES:
            for name in TABLES:
                for key, value in table(language, name).items():
                    with self.subTest(language=language, table=name, key=key):
                        check_entry(key, value)

    def test_l5_values_are_translated_unless_listed(self):
        for name in TABLES:
            english = table(ENGLISH, name)
            for language in LANGUAGES:
                for key, value in table(language, name).items():
                    with self.subTest(language=language, table=name, key=key):
                        self.assertTrue(value and value == value.strip())
                        if language != ENGLISH and (language, key) not in SAME_AS_ENGLISH:
                            self.assertNotEqual(value, english[key])
        for language, key in sorted(SAME_AS_ENGLISH):
            with self.subTest(language=language, key=key):
                self.assertIn(language, LANGUAGES)
                self.assertNotEqual(language, ENGLISH)
                names = [name for name in TABLES if key in table(ENGLISH, name)]
                self.assertTrue(names)
                for name in names:
                    self.assertEqual(table(language, name)[key], table(ENGLISH, name)[key])


class LocalizationSourceTests(unittest.TestCase):
    def test_l6_every_literal_key_is_in_the_table(self):
        keys, _ = localized_calls()
        self.assertTrue(keys)
        localizable = table(ENGLISH, 'Localizable')
        for key in sorted(keys):
            with self.subTest(key=key):
                self.assertIn(key, localizable)

    def test_l6_the_driver_keys_are_exactly_its_table(self):
        keys, non_literal = driver_calls()
        self.assertEqual(non_literal, 0)
        self.assertEqual(sorted(keys), sorted(table(ENGLISH, DRIVER_TABLE)))

    def test_l7_non_literal_calls_only_in_the_listed_files(self):
        _, non_literal = localized_calls()
        for path in non_literal:
            with self.subTest(path=path.relative_to(ROOT)):
                self.assertIn(path.name, NON_LITERAL_FILES)

    def test_l8_state_texts_are_literals_in_their_files_and_keys(self):
        localizable = table(ENGLISH, 'Localizable')
        for relative, texts in STATE_TEXTS.items():
            source = (ROOT / relative).read_text()
            for text in texts:
                with self.subTest(text=text):
                    self.assertIn(f'"{text}"', source)
                    self.assertIn(text, localizable)

    def test_l9_no_orphan_keys(self):
        keys, _ = localized_calls()
        allowed = keys | state_texts()
        for key in sorted(table(ENGLISH, 'Localizable')):
            with self.subTest(key=key):
                self.assertIn(key, allowed)

    def test_l11_the_about_window_stays_english(self):
        source = ABOUT.read_text()
        self.assertNotIn('Localized.', source)
        for name, text in ABOUT_TEXTS.items():
            with self.subTest(name=name):
                self.assertIn(f'public static let {name} = "{text}"', source)
        self.assertIn('Text(information.englishVersionLabel)', source)
        self.assertNotIn('information.versionLabel', source)
        for language in LANGUAGES:
            localizable = table(language, 'Localizable')
            for key in ABOUT_ONLY_KEYS:
                with self.subTest(language=language, key=key):
                    self.assertNotIn(key, localizable)
            for key in MENU_KEYS_SHARED_WITH_ABOUT:
                with self.subTest(language=language, key=key):
                    self.assertIn(key, localizable)
            for key in BUILD_VERSION_KEYS:
                with self.subTest(language=language, key=key):
                    self.assertNotIn(key, localizable)

    def test_l12_reviewed_values_and_removed_keys(self):
        for (language, name, key), value in sorted(REVIEWED_VALUES.items()):
            with self.subTest(language=language, key=key):
                self.assertEqual(table(language, name).get(key), value)
        for language in LANGUAGES:
            for name in TABLES:
                for key in REMOVED_KEYS:
                    with self.subTest(language=language, table=name, key=key):
                        self.assertNotIn(key, table(language, name))

    def test_l13_ear_detection_has_one_name_in_spanish_and_french(self):
        for language, (old, new) in EAR_DETECTION_TERMS.items():
            for name in TABLES:
                for key, value in table(language, name).items():
                    if 'detection' not in key.lower() and 'Usage' not in key:
                        continue
                    with self.subTest(language=language, key=key):
                        self.assertNotIn(old, value)
                        if 'detection' in key.lower():
                            self.assertIn(new, value)

    def test_l14_shared_fixture_loader_rejects_malformed_input(self):
        def document(**changes: object) -> dict:
            base = {
                name: {language: {'K': 'K' if language == ENGLISH else f'K {language}'}
                       for language in LANGUAGES}
                for name in FIXTURE_TABLES
            }
            base.update(changes)
            return base

        def encode(value: object) -> bytes:
            return json.dumps(value, ensure_ascii=False).encode('utf-8')

        self.assertEqual(load_shared_fixture(encode(document())), document())
        missing_language = document()
        del missing_language['Localizable']['ja']
        extra_language = document()
        extra_language['Localizable']['ko'] = {'K': 'K ko'}
        extra_table = document(InfoPlist={language: {'K': 'K'} for language in LANGUAGES})
        missing_table = document()
        del missing_table['AppleStyleUpdateDriver']
        different_keys = document()
        different_keys['Localizable']['it'] = {'L': 'L it'}
        english_differs = document()
        english_differs['Localizable'][ENGLISH] = {'K': 'Other'}
        empty_language = document()
        empty_language['Localizable']['fr'] = {}
        cases = {
            'missing language': encode(missing_language),
            'extra language': encode(extra_language),
            'extra table': encode(extra_table),
            'missing table': encode(missing_table),
            'different keys': encode(different_keys),
            'English value differs': encode(english_differs),
            'empty language': encode(empty_language),
            'not UTF-8': encode(document()).replace(b'K it', b'K \xff'),
            'two documents': encode(document()) + encode(document()),
            'top level list': encode([document()]),
            'top level string': encode('Localizable'),
            'duplicate table': b'{"Localizable": {}, "Localizable": {}}',
        }
        doubled = encode(document())
        cases['duplicate language'] = doubled.replace(
            b'"Localizable": {"en": {"K": "K"},',
            b'"Localizable": {"en": {"K": "K"}, "en": {"K": "K"},', 1)
        cases['duplicate key'] = doubled.replace(
            b'"Localizable": {"en": {"K": "K"}',
            b'"Localizable": {"en": {"K": "K", "K": "K"}', 1)
        for bad in (None, 1, [], {}, ''):
            value = document()
            value['Localizable']['it'] = {'K': bad}
            cases[f'value {bad!r}'] = encode(value)
        for name, data in cases.items():
            with self.subTest(case=name):
                with self.assertRaises(StringsError):
                    load_shared_fixture(data)
        self.assertNotEqual(cases['duplicate language'], doubled)
        self.assertNotEqual(cases['duplicate key'], doubled)

    def test_l14_shared_fixture_rejects_generated_mutations(self):
        def encode(value):
            return json.dumps(value, ensure_ascii=False).encode('utf-8')

        def at(value, path):
            for key in path:
                value = value[key]
            return value

        def objects(value, path=()):
            yield path
            for key, child in value.items():
                if isinstance(child, dict):
                    yield from objects(child, path + (key,))

        def render(value, duplicate=None, path=()):
            if not isinstance(value, dict):
                return json.dumps(value, ensure_ascii=False)
            pairs = list(value.items())
            if path == duplicate:
                pairs.append(pairs[0])
            return '{' + ','.join(
                json.dumps(key) + ':' + render(child, duplicate, path + (key,))
                for key, child in pairs) + '}'

        def reversed_objects(value):
            if not isinstance(value, dict):
                return value
            return {key: reversed_objects(child)
                    for key, child in reversed(list(value.items()))}

        for count in (1, 3):
            document = {
                name: {
                    language: {
                        f'K{i}é': f'K{i}é' if language == ENGLISH else f'V{i} {language}'
                        for i in range(count)}
                    for language in LANGUAGES}
                for name in FIXTURE_TABLES}
            data = render(document).encode('utf-8')
            self.assertEqual(load_shared_fixture(data), document)
            self.assertEqual(load_shared_fixture(encode(reversed_objects(document))), document)
            for end in range(len(data)):
                with self.subTest(count=count, truncation=end):
                    with self.assertRaises(StringsError):
                        load_shared_fixture(data[:end])
            for path in objects(document):
                with self.subTest(count=count, duplicate=path):
                    with self.assertRaises(StringsError):
                        load_shared_fixture(render(document, path).encode('utf-8'))
                changed = json.loads(data)
                at(changed, path)['unexpected'] = 'extra'
                with self.subTest(count=count, extra=path):
                    with self.assertRaises(StringsError):
                        load_shared_fixture(encode(changed))
                for key in at(document, path):
                    changed = json.loads(data)
                    del at(changed, path)[key]
                    with self.subTest(count=count, missing=path + (key,)):
                        with self.assertRaises(StringsError):
                            load_shared_fixture(encode(changed))
                    for bad in (None, False, 0, 1.5, [], {}, ''):
                        changed = json.loads(data)
                        at(changed, path)[key] = bad
                        with self.subTest(count=count, field=path + (key,), value=bad):
                            with self.assertRaises(StringsError):
                                load_shared_fixture(encode(changed))

    def test_l14_shared_texts_match_the_other_app(self):
        fixture = load_shared_fixture(SHARED_FIXTURE.read_bytes())
        for name, languages in fixture.items():
            for language, entries in languages.items():
                mine = table(language, name)
                if name == DRIVER_TABLE:
                    with self.subTest(table=name, language=language):
                        self.assertEqual(mine, entries)
                for key, value in entries.items():
                    with self.subTest(table=name, language=language, key=key):
                        self.assertEqual(mine.get(key, '').encode('utf-8'), value.encode('utf-8'))

    def test_l14_shared_keys_are_the_closed_list(self):
        fixture = load_shared_fixture(SHARED_FIXTURE.read_bytes())
        english = table(ENGLISH, 'Localizable')
        self.assertEqual(sorted(SHARED_KEYS), sorted(fixture['Localizable'][ENGLISH]))
        for key in SHARED_KEYS:
            with self.subTest(key=key):
                self.assertIn(key, english)

    def test_l15_installing_update_is_the_same_in_the_menu_and_the_update_window(self):
        for language in LANGUAGES:
            with self.subTest(language=language):
                self.assertEqual(table(language, 'Localizable')['Installing Update…'],
                                 table(language, DRIVER_TABLE)['Installing Update…'])

    def test_l17_mono_audio_has_one_name(self):
        for language in LANGUAGES:
            localizable = table(language, 'Localizable')
            with self.subTest(language=language):
                label = localizable[MONO_AUDIO_LINE].split('%@')[0].rstrip(LABEL_END)
                self.assertTrue(label)
                self.assertIn(label.casefold(), localizable[MONO_AUDIO_REASON].casefold())

    def test_l19_a_text_that_names_a_menu_item_uses_its_title(self):
        for language in LANGUAGES:
            localizable = table(language, 'Localizable')
            for text, item in MENU_REFERENCES.items():
                with self.subTest(language=language, text=text):
                    self.assertIn(localizable[item], localizable[text])

    def test_l18_french_uses_no_break_spaces(self):
        for name in ('Localizable', 'InfoPlist'):
            for key, value in table('fr', name).items():
                if name == 'Localizable' and key in SHARED_KEYS:
                    continue
                with self.subTest(table=name, key=key):
                    for index, character in enumerate(value):
                        if character in FRENCH_HIGH_MARKS and index > 0:
                            self.assertNotEqual(value[index - 1], ' ')
                            if value[index - 1].isspace():
                                self.assertEqual(value[index - 1], '\u00a0')

    def test_l10_info_plist_declares_the_languages(self):
        info = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
        self.assertEqual(info.get('CFBundleDevelopmentRegion'), 'en')
        self.assertEqual(info.get('CFBundleLocalizations'), list(LANGUAGES))


if __name__ == '__main__':
    unittest.main()
