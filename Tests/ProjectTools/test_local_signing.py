"""Isolated signing-policy checks; never touch a real keychain or create keys."""

from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "local-signing.py"
REAL_SUBPROCESS_RUN = subprocess.run
SPEC = importlib.util.spec_from_file_location("typingrt_local_signing_tests", SCRIPT)
signing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signing)
RUN_COMMAND = signing.run

# Synthetic public fingerprints, not certificates, keys, or credentials.
PIN = "A1" * 20
OTHER = "B2" * 20
BOUND = f'identifier "dev.typingrt.mac.signing-probe" and certificate leaf = H"{PIN}"'


class LocalSigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="typingrt-signing-unit-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.config = self.directory / "config" / "signing.json"
        self.data = {"identity_sha1": PIN, "keychain_path": str(self.directory / "fake.keychain-db")}
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(signing, "CONFIG", self.config).start()
        # Defense in depth: an incomplete fake must never execute an OS command.
        mock.patch.object(signing.subprocess, "run", side_effect=AssertionError("External subprocess prohibited in signing tests")).start()
        self.commands = mock.patch.object(signing, "run", side_effect=AssertionError("Unconfigured signing command")).start()
        original_umask = os.umask(0o077)
        os.umask(original_umask)
        self.addCleanup(os.umask, original_umask)

    def write_config(self, data=None):
        self.config.parent.mkdir()
        self.config.write_text(json.dumps(self.data if data is None else data))

    def cli(self, *arguments):
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, "argv", [str(SCRIPT), *arguments]), redirect_stdout(stdout), redirect_stderr(stderr):
            status = signing.main()
        return status, stdout.getvalue(), stderr.getvalue()

    def result(self, stdout="", stderr="", status=0):
        return subprocess.CompletedProcess([], status, stdout=stdout, stderr=stderr)

    def valid_identities(self):
        return self.result(f'  1) {PIN} "typingRT Local Development"\n     1 valid identities found\n')

    def test_command_failure_identifies_step_and_safe_os_error_without_arguments(self):
        response = self.result(stdout="DO-NOT-PRINT-STDOUT", stderr="security: SecKeychainItemImport: Unknown format in import.\n", status=1)
        with mock.patch.object(signing.subprocess, "run", return_value=response), self.assertRaises(signing.SigningError) as error:
            RUN_COMMAND([signing.SECURITY, "import", "/private/not-for-output.pem"], step="Privaten Signaturschlüssel importieren")
        self.assertIn("Privaten Signaturschlüssel importieren", str(error.exception))
        self.assertIn("Exit 1", str(error.exception))
        self.assertIn("SecKeychainItemImport: Unknown format", str(error.exception))
        self.assertNotIn("not-for-output", str(error.exception))
        self.assertNotIn("DO-NOT-PRINT", str(error.exception))

    def test_command_failure_never_prints_pem_material_or_openssl_stderr(self):
        for executable, diagnostic in [(signing.SECURITY, "security: failure\n-----BEGIN PRIVATE KEY-----\nSYNTHETIC-DO-NOT-PRINT\n-----END PRIVATE KEY-----"),
                                       (signing.OPENSSL, "SYNTHETIC-DO-NOT-PRINT")]:
            with self.subTest(executable=executable):
                response = self.result(stderr=diagnostic, status=1)
                with mock.patch.object(signing.subprocess, "run", return_value=response), self.assertRaises(signing.SigningError) as error:
                    RUN_COMMAND([executable, "import"])
                self.assertNotIn("SYNTHETIC-DO-NOT-PRINT", str(error.exception))
                self.assertNotIn("BEGIN PRIVATE", str(error.exception))

    def test_allowed_failure_retains_exit_code_for_read_only_discovery(self):
        response = self.result(stderr="security: not found", status=44)
        with mock.patch.object(signing.subprocess, "run", return_value=response):
            self.assertIs(RUN_COMMAND([signing.SECURITY, "find-certificate"], allow_failure=True), response)

    def native_setup_fake(self, state="valid", *, subject=None, certificate=True):
        self.data["keychain_path"] = str(Path.home() / "Library/Keychains/login.keychain-db")
        trusted = False
        def execute(args, **_):
            nonlocal trusted
            if args[0] == signing.SECURITY:
                self.assertIn(args[1], ["default-keychain", "find-certificate", "find-identity", "add-trusted-cert"])
                if args[1] == "default-keychain":
                    return self.result(json.dumps(self.data["keychain_path"]))
                if args[1] == "find-certificate":
                    return self.result("-----BEGIN CERTIFICATE-----\nSYNTHETIC PUBLIC CERT\n-----END CERTIFICATE-----\n" if certificate else "")
                if args[1] == "find-identity":
                    if state == "missing" or ("-v" in args and state != "valid" and not trusted):
                        return self.result("0 identities found")
                    error = "" if state == "valid" or trusted else f" ({state})"
                    return self.result(f'1) {PIN} "{signing.NAME}"{error}\n')
                self.assertEqual(state, "CSSMERR_TP_NOT_TRUSTED")
                self.assertEqual(args[args.index("-p") + 1], "codeSign")
                self.assertNotIn("-d", args)
                trusted = True
                return self.result()
            self.assertEqual(args[0], signing.OPENSSL)
            self.assertEqual(args[1], "x509")
            self.assertNotIn("-out", args)
            return self.result(f"subject={subject or 'CN=' + signing.NAME}\nsha1 Fingerprint={PIN}\n")
        return execute

    def test_native_setup_adopts_pair_and_only_saves_public_pin(self):
        self.commands.side_effect = self.native_setup_fake()
        with mock.patch.object(signing, "probe_identity") as probe, redirect_stdout(io.StringIO()):
            signing.setup()
        self.assertEqual(signing.read_config(), self.data)
        self.assertFalse(any(call.args[0][1] == "add-trusted-cert" for call in self.commands.call_args_list))
        probe.assert_called_once()

    def test_certificate_only_cannot_modify_trust_or_save_configuration_on_repeated_setup(self):
        self.commands.side_effect = self.native_setup_fake("missing")
        for _ in range(2):
            with self.assertRaises(signing.SigningError) as error:
                signing.setup()
            self.assertIn("privaten Schlüssel", str(error.exception))
            self.assertFalse(self.config.exists())
        self.assertTrue(all(call.args[0][1] in ["default-keychain", "find-certificate", "x509", "find-identity"]
                            for call in self.commands.call_args_list))
        self.assertFalse(any("-v" in call.args[0] for call in self.commands.call_args_list))

    def test_missing_native_identity_shows_certificate_assistant_without_generating_keys(self):
        self.commands.side_effect = self.native_setup_fake(certificate=False)
        with self.assertRaises(signing.SigningError) as error:
            signing.setup()
        self.assertIn("Zertifikatsassistent", str(error.exception))
        self.assertIn(signing.NAME, str(error.exception))
        self.assertEqual(len(self.commands.call_args_list), 2)
        self.assertFalse(self.config.exists())

    def test_only_untrusted_pair_gets_scoped_trust_then_is_rechecked_and_pinned(self):
        self.commands.side_effect = self.native_setup_fake("CSSMERR_TP_NOT_TRUSTED")
        with mock.patch.object(signing, "probe_identity") as probe, redirect_stdout(io.StringIO()):
            signing.setup()
        commands = [call.args[0] for call in self.commands.call_args_list]
        trust = next(i for i, command in enumerate(commands) if command[1] == "add-trusted-cert")
        self.assertEqual(commands[trust - 2][1:3], ["find-identity", "-p"])
        self.assertEqual(commands[trust - 1][1:3], ["find-identity", "-v"])
        self.assertEqual(commands[trust + 1][1:3], ["find-identity", "-v"])
        self.assertEqual(signing.read_config(), self.data)
        probe.assert_called_once()

    def test_expired_or_unknown_invalid_pair_cannot_change_trust(self):
        for state in ["CSSMERR_TP_CERT_EXPIRED", "", "CSSMERR_TP_INVALID_CERTIFICATE"]:
            with self.subTest(state=state):
                self.commands.reset_mock()
                self.commands.side_effect = self.native_setup_fake(state)
                with self.assertRaises(signing.SigningError):
                    signing.setup()
                self.assertFalse(any(call.args[0][1] == "add-trusted-cert" for call in self.commands.call_args_list))
                self.assertFalse(self.config.exists())

    def test_certificate_substring_and_duplicate_common_names_are_not_adopted(self):
        for subject in ["CN=" + signing.NAME + " Backup", "CN=" + signing.NAME + ",CN=" + signing.NAME,
                        "O=Example\\,CN=" + signing.NAME]:
            with self.subTest(subject=subject):
                self.commands.reset_mock()
                self.commands.side_effect = self.native_setup_fake(subject=subject)
                with self.assertRaises(signing.SigningError):
                    signing.setup()
                self.assertFalse(any(call.args[0][1] in ["find-identity", "add-trusted-cert"] for call in self.commands.call_args_list))

    def test_wrong_default_keychain_is_not_silently_selected(self):
        self.commands.side_effect = None
        self.commands.return_value = self.result(json.dumps(str(self.directory / "other.keychain-db")))
        with self.assertRaises(signing.SigningError) as error:
            signing.setup()
        self.assertIn("Anmeldung/login", str(error.exception))
        self.assertEqual(len(self.commands.call_args_list), 1)

    def test_missing_configuration_fails_closed_without_keychain_access(self):
        status, output, error = self.cli("settings")
        self.assertEqual(status, 1)
        self.assertEqual(output, "")
        self.assertIn("Signatur", error)
        self.assertFalse(self.config.exists())
        self.commands.assert_not_called()

    def test_invalid_configuration_is_not_replaced_or_used(self):
        invalid = [None, [], {}, {**self.data, "identity_sha1": "-"},
                   {**self.data, "identity_sha1": PIN + "00"},
                   {**self.data, "keychain_path": "relative.keychain"},
                   {**self.data, "keychain_path": "/tmp/fake\nextra"},
                   {**self.data, "keychain_path": "/tmp/fake\0extra"}]
        self.config.parent.mkdir()
        for value in invalid:
            with self.subTest(value=value):
                contents = json.dumps(value)
                self.config.write_text(contents)
                with self.assertRaises(signing.SigningError):
                    signing.setup()
                self.assertEqual(self.config.read_text(), contents)
                self.commands.assert_not_called()
        self.config.write_text("invalid json")
        with self.assertRaises(signing.SigningError):
            signing.setup()
        self.assertEqual(self.config.read_text(), "invalid json")

    def test_public_fingerprint_is_normalized_and_unknown_fields_are_not_loaded(self):
        self.write_config({**self.data, "identity_sha1": PIN.lower(), "unexpected_private_field": "do-not-return"})
        self.assertEqual(signing.read_config(), self.data)
        self.commands.assert_not_called()

    def test_identity_must_match_exact_fingerprint_not_name_or_substring(self):
        self.commands.side_effect = None
        wrong = [f'  1) {OTHER} "typingRT Local Development"\n',
                 f'  1) {OTHER} "typingRT {PIN} Local Development"\n',
                 f'  1) {PIN[:-1]} "typingRT Local Development"\n',
                 "     0 valid identities found\n"]
        for output in wrong:
            with self.subTest(output=output):
                self.commands.return_value = self.result(output)
                with self.assertRaises(signing.SigningError):
                    signing.require_identity(self.data)
        self.commands.return_value = self.result(f'  1) {PIN.lower()} "Unrelated Display Name"\n')
        signing.require_identity(self.data)
        self.assertEqual(self.commands.call_args.args[0], [signing.SECURITY, "find-identity", "-v", "-p", "codesigning", self.data["keychain_path"]])

    def test_existing_setup_reuses_identity_and_probes_without_new_keys_or_trust(self):
        self.write_config()
        original = self.config.read_bytes()
        self.commands.side_effect = None
        self.commands.return_value = self.valid_identities()
        with mock.patch.object(signing, "probe_identity") as probe, redirect_stdout(io.StringIO()):
            signing.setup()
        self.assertEqual(self.config.read_bytes(), original)
        probe.assert_called_once()
        self.assertEqual(probe.call_args.args[0], self.data)
        self.assertEqual(len(self.commands.call_args_list), 1)
        self.assertEqual(self.commands.call_args.args[0][1], "find-identity")

    def test_missing_pinned_identity_does_not_generate_a_replacement(self):
        self.write_config()
        original = self.config.read_bytes()
        self.commands.side_effect = None
        self.commands.return_value = self.result("0 valid identities found")
        with mock.patch.object(signing, "probe_identity") as probe, self.assertRaises(signing.SigningError):
            signing.setup()
        self.assertEqual(self.config.read_bytes(), original)
        self.assertEqual([call.args[0][1] for call in self.commands.call_args_list], ["find-identity", "find-identity"])
        probe.assert_not_called()

    def test_identity_parser_accepts_stderr_and_does_not_depend_on_name_quotes(self):
        self.commands.side_effect = None
        self.commands.return_value = self.result(stderr=f'  1) {PIN} typingRT Local Development\n')
        signing.require_identity(self.data)

    def test_invalid_identity_reports_actual_policy_error_without_replacement(self):
        self.commands.side_effect = [self.result("0 valid identities found"),
            self.result(f'1) {PIN} "typingRT Local Development" (CSSMERR_TP_NOT_TRUSTED)\n')]
        with self.assertRaises(signing.SigningError) as error:
            signing.require_identity(self.data)
        self.assertIn("CSSMERR_TP_NOT_TRUSTED", str(error.exception))
        self.assertIn("als Identität gefunden", str(error.exception))
        self.assertNotIn("kein zugängliches", str(error.exception))

    def test_diagnose_distinguishes_certificate_without_accessible_identity_read_only(self):
        certificate = "-----BEGIN CERTIFICATE-----\nSYNTHETIC-PUBLIC-CERTIFICATE\n-----END CERTIFICATE-----\n"
        def execute(args, **_):
            if args[0] == signing.SECURITY:
                self.assertIn(args[1], ["default-keychain", "find-certificate", "find-identity"])
                if args[1] == "default-keychain":
                    return self.result(json.dumps(str(Path.home() / "Library/Keychains/login.keychain-db")))
                if args[1] == "find-certificate":
                    return self.result(certificate if signing.NAME in args else "")
                return self.result("0 identities found")
            self.assertEqual(args[0], signing.OPENSSL)
            self.assertEqual(args[1], "x509")
            self.assertNotIn("-out", args)
            return self.result("subject=CN=" + signing.NAME + "\nsha1 Fingerprint=" + PIN)
        self.commands.side_effect = execute
        status, output, error = self.cli("diagnose")
        self.assertEqual(status, 0)
        self.assertEqual(error, "")
        self.assertIn("typingRT-Zertifikate: 1", output)
        self.assertIn("nicht als zugängliche Identität gefunden", output)
        self.assertNotIn("BEGIN CERTIFICATE", output)
        self.assertFalse(self.config.exists())

    def test_failed_reuse_probe_preserves_pinned_configuration(self):
        self.write_config()
        original = self.config.read_bytes()
        self.commands.side_effect = None
        self.commands.return_value = self.valid_identities()
        with mock.patch.object(signing, "probe_identity", side_effect=signing.SigningError("probe failed")), self.assertRaises(signing.SigningError):
            signing.setup()
        self.assertEqual(self.config.read_bytes(), original)
        self.assertEqual(len(self.commands.call_args_list), 1)

    def test_requirements_reject_adhoc_and_identifier_only_identity(self):
        bad = [f'cdhash H"{PIN}"', 'identifier "dev.typingrt.mac"',
               'identifier "dev.typingrt.certificate"', 'identifier "dev.anchor.typingrt"',
               f'identifier "dev.typingrt.mac" and cdhash H"{PIN}" and certificate leaf = H"{PIN}"']
        self.commands.side_effect = None
        for requirement in bad:
            with self.subTest(requirement=requirement):
                self.commands.return_value = self.result(stderr=f"designated => {requirement}\n")
                with self.assertRaises(signing.SigningError):
                    signing.requirement(self.directory / "fake.app")
        self.commands.return_value = self.result(stderr="no designated requirement available")
        with self.assertRaises(signing.SigningError):
            signing.requirement(self.directory / "fake.app")

    def test_requirement_accepts_certificate_binding_on_either_output_stream(self):
        self.commands.side_effect = None
        for stdout, stderr in [(f"designated => {BOUND}\n", ""), ("", f"# designated => {BOUND}\n")]:
            with self.subTest(stdout=stdout):
                self.commands.return_value = self.result(stdout, stderr)
                self.assertEqual(signing.requirement(self.directory / "fake.app"), BOUND)

    def probe_fake(self, *, identical_bytes=False, different_requirements=False):
        def execute(arguments, *, input=None, **_):
            if arguments[0] == "/usr/bin/clang":
                output = Path(arguments[arguments.index("-o") + 1])
                output.write_bytes(b"same synthetic binary" if identical_bytes else input.encode())
                return self.result()
            if arguments[0] == signing.CODESIGN:
                if "--display" in arguments:
                    requirement = BOUND
                    if different_requirements and Path(arguments[-1]).name == "probe-b":
                        requirement = BOUND.replace(PIN, OTHER)
                    return self.result(stderr=f"designated => {requirement}\n")
                return self.result()
            raise AssertionError(f"Unexpected fake operation: {arguments[0]}")
        return execute

    def test_probe_signs_two_different_binaries_and_verifies_cross_version_identity(self):
        self.commands.side_effect = self.probe_fake()
        signing.probe_identity(self.data, self.directory)
        paths = [self.directory / "probe-a", self.directory / "probe-b"]
        self.assertNotEqual(paths[0].read_bytes(), paths[1].read_bytes())
        signs = [call.args[0] for call in self.commands.call_args_list if "--sign" in call.args[0]]
        checks = [call.args[0] for call in self.commands.call_args_list if "--verify" in call.args[0]]
        self.assertEqual(len(signs), 2)
        self.assertEqual(len(checks), 2)
        for command in signs:
            self.assertEqual(command[command.index("--sign") + 1], PIN)
            self.assertEqual(command[command.index("--keychain") + 1], self.data["keychain_path"])
            self.assertIn("--timestamp=none", command)
        self.assertEqual({command[-1] for command in checks}, {str(path) for path in paths})
        for command in checks:
            self.assertEqual(command[command.index("-R") + 1], "=" + BOUND)

    def test_probe_cannot_claim_success_for_identical_binary_fixtures(self):
        self.commands.side_effect = self.probe_fake(identical_bytes=True)
        with self.assertRaises(signing.SigningError):
            signing.probe_identity(self.data, self.directory)

    def test_probe_checks_each_other_requirement_then_rejects_identity_drift(self):
        self.commands.side_effect = self.probe_fake(different_requirements=True)
        with self.assertRaises(signing.SigningError):
            signing.probe_identity(self.data, self.directory)
        checks = [call.args[0] for call in self.commands.call_args_list if "--verify" in call.args[0]]
        self.assertEqual(checks[0][checks[0].index("-R") + 1], "=" + BOUND.replace(PIN, OTHER))
        self.assertEqual(checks[1][checks[1].index("-R") + 1], "=" + BOUND)

    def test_cli_settings_prints_only_public_fingerprint_and_keychain_path(self):
        self.write_config({**self.data, "unexpected_private_field": "do-not-print"})
        self.commands.side_effect = None
        self.commands.return_value = self.valid_identities()
        status, output, error = self.cli("settings")
        self.assertEqual(status, 0)
        self.assertEqual(output, f'{PIN}\n{self.data["keychain_path"]}\n')
        self.assertEqual(error, "")

    def test_cli_verify_requires_the_pinned_certificate(self):
        self.write_config()
        self.commands.side_effect = [self.valid_identities(), self.result(), self.result(stderr=f"designated => {BOUND}\n")]
        status, output, error = self.cli("verify", str(self.directory / "fake.app"))
        self.assertEqual((status, output, error), (0, "", ""))
        check = self.commands.call_args_list[1].args[0]
        self.assertIn(f'=certificate leaf = H"{PIN}"', check)

    def isolated_build_project(self):
        project = self.directory / "isolated-project"
        scripts = project / "scripts"
        scripts.mkdir(parents=True)
        for name in ["build-app.sh", "local-signing.py"]:
            shutil.copyfile(SCRIPT.parent / name, scripts / name)
        app = project / "dist" / "typingRT.app"
        app.mkdir(parents=True)
        (app / "sentinel").write_bytes(b"previous valid installation")
        environment = os.environ.copy()
        environment["TYPINGRT_SIGNING_CONFIG"] = str(self.config)
        environment["TYPINGRT_ADHOC_PREVIEW"] = "0"
        environment["TYPINGRT_SIGNING_MODE"] = "certificate"
        return project, app, environment

    def test_development_build_refuses_the_daily_output_before_compilation(self):
        project, app, environment = self.isolated_build_project()
        environment["TYPINGRT_SIGNING_MODE"] = "adhoc"
        result = REAL_SUBPROCESS_RUN(["/bin/bash", str(project / "scripts/build-app.sh"),
                                     "debug", "typingRT", "development"],
                                    env=environment, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Alltagspfad bleibt geschützt", result.stderr)
        self.assertEqual((app / "sentinel").read_bytes(), b"previous valid installation")
        self.assertFalse((project / ".build").exists())

    def test_development_output_refuses_an_incompatible_identity(self):
        project, app, environment = self.isolated_build_project()
        environment["TYPINGRT_SIGNING_MODE"] = "adhoc"
        result = REAL_SUBPROCESS_RUN(["/bin/bash", str(project / "scripts/build-app.sh"),
                                     "debug", "typingRT-development", "required"],
                                    env=environment, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("isolierten Entwicklungsbuild", result.stderr)
        self.assertEqual((app / "sentinel").read_bytes(), b"previous valid installation")

    def test_development_build_reaches_compilation_without_signing_configuration(self):
        project, app, environment = self.isolated_build_project()
        environment.pop("TYPINGRT_SIGNING_MODE")
        result = REAL_SUBPROCESS_RUN(["/bin/bash", str(project / "scripts/build-app.sh"),
                                     "debug", "typingRT-development", "development"],
                                    env=environment, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Ad-hoc-Build", result.stdout)
        self.assertIn("swift-tool.sh", result.stderr)
        self.assertEqual((app / "sentinel").read_bytes(), b"previous valid installation")
        self.assertFalse((project / "dist/typingRT-development.app").exists())

    def test_default_adhoc_build_reaches_compilation_without_signing_configuration(self):
        project, app, environment = self.isolated_build_project()
        environment.pop("TYPINGRT_SIGNING_MODE")
        # Deliberately no compiler wrapper in this isolated fixture: reaching it
        # proves no certificate/keychain gate ran first, without building an app.
        result = REAL_SUBPROCESS_RUN(["/bin/bash", str(project / "scripts/build-app.sh"), "debug"],
                                     env=environment, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Ad-hoc-Build", result.stdout)
        self.assertIn("swift-tool.sh", result.stderr)
        self.assertNotIn("Signatur fehlt", result.stderr)
        self.assertEqual((app / "sentinel").read_bytes(), b"previous valid installation")

    def test_invalid_signing_mode_stops_before_modifying_previous_bundle(self):
        project, app, environment = self.isolated_build_project()
        environment["TYPINGRT_SIGNING_MODE"] = "invalid"
        result = REAL_SUBPROCESS_RUN(["/bin/bash", str(project / "scripts/build-app.sh"), "debug"],
                                     env=environment, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Signaturmodus", result.stderr)
        self.assertEqual((app / "sentinel").read_bytes(), b"previous valid installation")

    def test_real_build_guard_missing_configuration_preserves_previous_bundle(self):
        project, app, environment = self.isolated_build_project()
        result = REAL_SUBPROCESS_RUN(["/bin/bash", str(project / "scripts/build-app.sh"), "debug"],
                                     env=environment, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Dauerhafte lokale Signatur fehlt", result.stderr)
        self.assertEqual((app / "sentinel").read_bytes(), b"previous valid installation")
        self.assertFalse((project / ".build").exists())
        self.assertEqual(list((project / "dist").iterdir()), [app])

    @unittest.skipUnless(Path("/usr/sbin/lsof").exists() and Path("/usr/bin/clang").exists(), "macOS executable-path guard")
    def test_development_guard_refuses_live_worker_without_running_main(self):
        project, app, environment = self.isolated_build_project()
        environment["TYPINGRT_SIGNING_MODE"] = "adhoc"
        development = project / "dist/typingRT-development.app"
        executable = development / "Contents/XPCServices/dev.typingrt.mac.development.TranscriptionWorker.xpc/Contents/MacOS/TranscriptionWorker"
        executable.parent.mkdir(parents=True)
        compiled = REAL_SUBPROCESS_RUN(["/usr/bin/clang", "-x", "c", "-o", str(executable), "-"],
                                       input="#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n",
                                       capture_output=True, text=True, timeout=15)
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        process = subprocess.Popen([str(executable)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            self.assertIsNone(process.poll())
            result = REAL_SUBPROCESS_RUN(["/bin/bash", str(project / "scripts/build-app.sh"),
                                         "debug", "typingRT-development", "development"],
                                        env=environment, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("läuft noch", result.stderr)
            self.assertEqual((app / "sentinel").read_bytes(), b"previous valid installation")
            self.assertTrue(executable.exists())
            self.assertFalse((project / ".build").exists())
        finally:
            process.terminate()
            process.wait(timeout=5)

    @unittest.skipUnless(Path("/usr/sbin/lsof").exists() and Path("/usr/bin/clang").exists(), "macOS executable-path guard")
    def test_real_build_guard_refuses_live_main_even_when_worker_path_is_missing(self):
        project, app, environment = self.isolated_build_project()
        executable = app / "Contents/MacOS/typingRT"
        executable.parent.mkdir(parents=True)
        # A copied Apple platform executable may be killed by AMFI. Build a
        # harmless local fixture instead; no certificate, keychain, or TCC use.
        compiled = REAL_SUBPROCESS_RUN(["/usr/bin/clang", "-x", "c", "-o", str(executable), "-"],
                                       input="#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n",
                                       capture_output=True, text=True, timeout=15)
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        # Only our own isolated sleep process is created or terminated.
        process = subprocess.Popen([str(executable)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            self.assertIsNone(process.poll())
            environment["TYPINGRT_ADHOC_PREVIEW"] = "1"
            result = REAL_SUBPROCESS_RUN(["/bin/bash", str(project / "scripts/build-app.sh"), "debug", "typingRT", "preview"],
                                         env=environment, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("läuft noch", result.stderr)
            self.assertEqual((app / "sentinel").read_bytes(), b"previous valid installation")
            self.assertFalse((project / ".build").exists())
        finally:
            process.terminate()
            process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
