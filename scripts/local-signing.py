#!/usr/bin/env python3
"""Local development signing only. Run setup in the user's normal Terminal.

Private keys never enter this repository. The persistent config contains only a
public certificate fingerprint and keychain path, not executable shell content.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

NAME = "typingRT Local Signing"
LEGACY_NAME = "typingRT Local Development"
SECURITY = "/usr/bin/security"
CODESIGN = "/usr/bin/codesign"
OPENSSL = "/usr/bin/openssl"
CONFIG = Path(os.environ.get("TYPINGRT_SIGNING_CONFIG", str(
    Path.home() / "Library/Application Support/typingRT/Development/signing.json")))


class SigningError(Exception):
    pass


def safe_security_error(stderr):
    # Only security's own bounded error lines; never stdout, arguments or PEM data.
    if "-----BEGIN" in stderr or "-----END" in stderr:
        return "Diagnosedetails mit PEM-Daten ausgeblendet."
    lines = [line.strip() for line in stderr.splitlines() if line.strip().startswith("security:")]
    return " ".join(lines)[:600]


def run(args, *, input=None, allow_failure=False, step=None):
    result = subprocess.run(args, input=input, capture_output=True, text=True)
    if result.returncode and not allow_failure:
        operation = step or f"{Path(args[0]).name} {args[1] if len(args) > 1 else ''}"
        detail = safe_security_error(result.stderr) if args[0] == SECURITY else ""
        raise SigningError(f"{operation} fehlgeschlagen (Exit {result.returncode})." + (f" {detail}" if detail else ""))
    return result


def validate_config(data):
    if not isinstance(data, dict) or not isinstance(data.get("identity_sha1"), str) or not re.fullmatch(r"[A-Fa-f0-9]{40}", data["identity_sha1"]):
        raise SigningError("Signaturkonfiguration enthält keinen gültigen Zertifikatsfingerprint.")
    keychain = data.get("keychain_path")
    if not isinstance(keychain, str) or not Path(keychain).is_absolute() or any(c in keychain for c in "\r\n\0"):
        raise SigningError("Signaturkonfiguration enthält keinen gültigen Schlüsselbundpfad.")
    return {"identity_sha1": data["identity_sha1"].upper(), "keychain_path": keychain}


def read_config():
    try:
        return validate_config(json.loads(CONFIG.read_text()))
    except FileNotFoundError:
        raise SigningError("Dauerhafte lokale Signatur fehlt. Einmal im normalen Terminal ausführen: "
                           "bash scripts/enable-local-app.sh") from None
    except (ValueError, OSError):
        raise SigningError("Signaturkonfiguration ist nicht lesbar; nicht automatisch ersetzen.") from None


def identity_entries(result):
    # The name/quotes and output stream are presentation details, not identity.
    output = result.stdout + "\n" + result.stderr
    return {match[1].upper(): re.findall(r"\bCSSMERR_[A-Z0-9_]+\b", match[2])
            for match in re.finditer(r'^\s*\d+\)\s+([A-Fa-f0-9]{40})(?=\s|$)([^\r\n]*)$', output, re.MULTILINE)}


def require_identity(data):
    valid = run([SECURITY, "find-identity", "-v", "-p", "codesigning", data["keychain_path"]])
    if data["identity_sha1"] in identity_entries(valid):
        return
    all_identities = run([SECURITY, "find-identity", "-p", "codesigning", data["keychain_path"]])
    entries = identity_entries(all_identities)
    if data["identity_sha1"] in entries:
        status = ", ".join(entries[data["identity_sha1"]]) or "keine gültige Code-Signing-Freigabe"
        reason = f"Zertifikat und Schlüssel werden als Identität gefunden, aber nicht als gültig: {status}."
    else:
        reason = "Für dieses Zertifikat wird kein zugängliches Zertifikat-Schlüssel-Paar gefunden."
    raise SigningError(reason + " Diagnose ohne Änderungen: python3 scripts/local-signing.py diagnose. "
                       "Kein Ersatz-Zertifikat und kein Ad-hoc-Fallback erzeugt.")


def user_keychain():
    output = run([SECURITY, "default-keychain", "-d", "user"]).stdout.strip()
    try:
        parsed = shlex.split(output)
    except ValueError:
        parsed = []
    allowed = {str(Path.home() / "Library/Keychains" / name) for name in ("login.keychain", "login.keychain-db")}
    if len(parsed) != 1 or parsed[0] not in allowed:
        raise SigningError("Als Benutzer-Standardschlüsselbund muss Anmeldung/login ausgewählt sein. "
                           "In der Schlüsselbundverwaltung Anmeldung als Standardschlüsselbund auswählen; erneut starten.")
    return parsed[0]


def named_certificates(name, keychain):
    result = run([SECURITY, "find-certificate", "-a", "-c", name, "-p", keychain], allow_failure=True)
    if result.returncode not in (0, 44):
        raise SigningError("Zertifikatsmetadaten nicht lesbar. " + safe_security_error(result.stderr))
    certificates = {}
    for block in re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", result.stdout, re.DOTALL):
        metadata = run([OPENSSL, "x509", "-noout", "-subject", "-nameopt", "RFC2253", "-fingerprint", "-sha1"],
                       input=block + "\n").stdout
        subject = re.search(r"^subject=\s*(.*)$", metadata, re.MULTILINE)
        # security -c matches substrings. Keep escaped RFC2253 separators inside their field.
        fields = re.findall(r"(?:\\.|[^,+])+", subject[1]) if subject else []
        if [field[3:] for field in fields if field.startswith("CN=")] != [name]:
            continue
        fingerprint = re.search(r"^sha1 Fingerprint=([A-Fa-f0-9:]+)\s*$", metadata, re.MULTILINE | re.IGNORECASE)
        pin = fingerprint[1].replace(":", "").upper() if fingerprint else ""
        if not re.fullmatch(r"[A-F0-9]{40}", pin):
            raise SigningError("Zertifikatsfingerprint konnte nicht gelesen werden.")
        certificates[pin] = block + "\n"
    return certificates


def diagnose():
    """Public metadata only; no setup, unlock, trust change or private key export."""
    print("Signaturkonfiguration:", "vorhanden" if CONFIG.exists() else "noch nicht gespeichert")
    keychain = read_config()["keychain_path"] if CONFIG.exists() else user_keychain()
    certificates = {pin: name for name in (NAME, LEGACY_NAME) for pin in named_certificates(name, keychain)}
    print("typingRT-Zertifikate:", len(certificates))
    valid = identity_entries(run([SECURITY, "find-identity", "-v", "-p", "codesigning", keychain]))
    available = identity_entries(run([SECURITY, "find-identity", "-p", "codesigning", keychain]))
    for number, (pin, name) in enumerate(certificates.items(), 1):
        if pin in valid:
            state = "gültige Signieridentität gefunden"
        elif pin in available:
            state = "Identität gefunden, ungültig: " + (", ".join(available[pin]) or "ohne OS-Fehlercode")
        else:
            state = "Zertifikat vorhanden, passender privater Schlüssel nicht als zugängliche Identität gefunden"
        print(f"Zertifikat {number} ({name}): {state}")


def requirement(path):
    result = run([CODESIGN, "--display", "-r-", str(path)])
    match = re.search(r'^(?:# )?designated => (.+)$', result.stdout + result.stderr, re.MULTILINE)
    terms = re.sub(r'"(?:\\.|[^"\\])*"', '""', match[1]) if match else ""
    if not match or re.search(r"\bcdhash\b", terms) or not re.search(r'\banchor\s+H""|\bcertificate\s+(?:leaf|root|\d+)\b', terms):
        raise SigningError("Signatur ist nicht kryptografisch an ein dauerhaftes Zertifikat gebunden.")
    return match[1]


def probe_identity(data, directory):
    """Actual different native binaries must satisfy each other's certificate DR."""
    paths = [directory / "probe-a", directory / "probe-b"]
    for number, path in enumerate(paths):
        run(["/usr/bin/clang", "-x", "c", "-o", str(path), "-"],
            input=f"int main(void) {{ return {number}; }}\n")
        run([CODESIGN, "--force", "--sign", data["identity_sha1"], "--keychain", data["keychain_path"],
             "--timestamp=none", "--identifier", "dev.typingrt.mac.signing-probe", str(path)])
    requirements = [requirement(path) for path in paths]
    for path, other in zip(paths, reversed(requirements)):
        run([CODESIGN, "--verify", "--strict", "-R", "=" + other, str(path)])
    if requirements[0] != requirements[1] or paths[0].read_bytes() == paths[1].read_bytes():
        raise SigningError("Signaturidentität bleibt zwischen unterschiedlichen Test-Builds nicht stabil.")


def setup():
    os.umask(0o077)
    CONFIG.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (CONFIG.parent / ".signing-setup.lock").open("a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SigningError("Eine Signatur-Einrichtung läuft bereits. Nicht parallel starten.") from None
        setup_locked()


def setup_locked():
    if CONFIG.exists():
        data = read_config()
        require_identity(data)
        with tempfile.TemporaryDirectory(prefix="typingrt-signing-check-") as tmp:
            probe_identity(data, Path(tmp))
        print("Vorhandene dauerhafte Signatur wiederverwendet.")
        return

    keychain = user_keychain()
    certificates = named_certificates(NAME, keychain)
    if not certificates:
        raise SigningError(f"Keine Identität '{NAME}' vorhanden. Einmalig in der Schlüsselbundverwaltung: "
                           f"Zertifikatsassistent → Zertifikat erstellen; Name '{NAME}', "
                           "Self Signed Root, Code Signing, Schlüsselbund Anmeldung/login. "
                           "Danach bash scripts/enable-local-app.sh erneut ausführen. Der alte Zertifikatseintrag bleibt unverändert.")
    if len(certificates) != 1:
        raise SigningError(f"Mehrere Zertifikate mit exakt dem Namen '{NAME}' vorhanden; nicht automatisch auswählen.")
    pin, pem = next(iter(certificates.items()))
    data = validate_config({"identity_sha1": pin, "keychain_path": keychain})
    available = identity_entries(run([SECURITY, "find-identity", "-p", "codesigning", keychain]))
    if pin not in available:
        raise SigningError(f"Für '{NAME}' wird kein zugängliches Zertifikat-Schlüssel-Paar gefunden. "
                           "In der Schlüsselbundverwaltung unter Anmeldung/login → Meine Zertifikate prüfen, "
                           "ob der Eintrag aufklappbar ist und einen privaten Schlüssel enthält; Anmeldung muss entsperrt sein. "
                           "Kein Vertrauen geändert und keinen Schlüssel erzeugt oder importiert.")
    valid = identity_entries(run([SECURITY, "find-identity", "-v", "-p", "codesigning", keychain]))
    needs_trust = pin not in valid
    if needs_trust and set(available[pin]) != {"CSSMERR_TP_NOT_TRUSTED"}:
        reason = ", ".join(available[pin]) or "unbekannter Gültigkeitsfehler"
        raise SigningError(f"Vorhandene Signieridentität ungültig: {reason}. "
                           "Zertifikat in der Schlüsselbundverwaltung prüfen; kein Vertrauen geändert.")
    with tempfile.TemporaryDirectory(prefix="typingrt-local-signing-") as tmp:
        directory = Path(tmp)
        if needs_trust:
            certificate = directory / "certificate.pem"
            certificate.write_text(pem)
            # Public certificate only; user scope and code-signing policy only.
            run([SECURITY, "add-trusted-cert", "-r", "trustRoot", "-p", "codeSign", "-k", keychain, str(certificate)],
                step="Benutzerspezifisches Code-Signing-Vertrauen einrichten")
        require_identity(data)
        probe_identity(data, directory)
        with tempfile.NamedTemporaryFile(mode="w", dir=CONFIG.parent, prefix=".signing-", delete=False) as handle:
            temporary = Path(handle.name)
            json.dump(data, handle, indent=2)
            handle.write("\n")
        try:
            # Don't overwrite a config produced by a concurrent setup.
            os.link(temporary, CONFIG)
        finally:
            temporary.unlink()
    print("Dauerhafte lokale Signatur eingerichtet; zwei unterschiedliche Test-Builds geprüft.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["setup", "settings", "verify", "diagnose"])
    parser.add_argument("app", nargs="?")
    args = parser.parse_args()
    try:
        if args.command == "setup":
            setup()
        elif args.command == "diagnose":
            diagnose()
        elif args.command == "settings":
            data = read_config()
            require_identity(data)
            print(data["identity_sha1"])
            print(data["keychain_path"])
        else:
            if not args.app:
                raise SigningError("verify benötigt einen Bundle-Pfad.")
            data = read_config()
            require_identity(data)
            # Explicitly bind the sealed bundle to the pinned leaf certificate.
            run([CODESIGN, "--verify", "--strict", "-R", f'=certificate leaf = H"{data["identity_sha1"]}"', args.app])
            requirement(Path(args.app))
    except (SigningError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
