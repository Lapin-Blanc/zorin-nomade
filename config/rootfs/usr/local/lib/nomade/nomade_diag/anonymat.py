"""Anonymisation des rapports (D-049).

- Les identifiants relevés (numéros de série, UUID, machine-id…) sont déclarés par ``secret`` :
  ils deviennent une empreinte HMAC-SHA-256 tronquée, salée, et sont remplacés à l'identique
  dans tout le texte nettoyé.
- ``nettoyer`` efface en plus par motif : adresses MAC, IPv4 et IPv6, courriels, nom de
  l'utilisateur et /home/<nom>.
- ``trouvailles`` est le contrôle final : si une valeur déclarée ou un motif reste dans ce qui
  part, l'archive n'est pas écrite.
"""

import hashlib
import hmac
import os
import re

# Valeurs génériques des firmwares et ponts : pas des identifiants, ne pas les traiter.
GENERIQUES = {
    "", "0", "none", "null", "n/a", "na", "unknown", "default string", "to be filled by o.e.m.",
    "to be filled by oem", "system serial number", "not specified", "not applicable", "chassis serial number",
    "base board serial number", "0123456789", "123456789", "1234567890", "00000000", "000000000000",
    "ffffffff", "03000200-0400-0500-0006-000700080009", "invalid",
}

RE_MAC = re.compile(r"(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:])")
RE_IPV4 = re.compile(r"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![\d.])")
RE_IPV6 = re.compile(
    r"(?<![0-9A-Fa-f:])(?:(?:[0-9A-Fa-f]{1,4}:){4,7}[0-9A-Fa-f]{1,4}"
    r"|(?:[0-9A-Fa-f]{1,4}:)+:(?:[0-9A-Fa-f]{1,4}:)*[0-9A-Fa-f]{1,4}"
    r"|::(?:[0-9A-Fa-f]{1,4}:)+[0-9A-Fa-f]{1,4})(?![0-9A-Fa-f:])")
# Courriel, mais pas une unité systemd instanciée (user@1000.service, getty@tty1.service…)
UNITES_SYSTEMD = "service|socket|timer|mount|automount|target|path|slice|scope|device|swap"
RE_COURRIEL = re.compile(r"[A-Za-z0-9._%%+-]+@[A-Za-z0-9.-]+\.(?!(?:%s)\b)[A-Za-z]{2,}" % UNITES_SYSTEMD)
RE_HOME = re.compile(r"/home/[^/\s'\"]+")


def ipv4_publique(adresse):
    return not (adresse.startswith("127.") or adresse.startswith("0.") or adresse == "255.255.255.255")


def lire_ou_creer_sel(chemin, uid=None, gid=None):
    """Sel (octets) lu dans ``chemin`` ; tiré au hasard et écrit (0600) s'il n'existe pas."""
    try:
        with open(chemin, "r", encoding="ascii") as f:
            texte = f.read().strip()
        if re.fullmatch(r"[0-9a-f]{64}", texte):
            return bytes.fromhex(texte)
    except OSError:
        pass
    sel = os.urandom(32)
    os.makedirs(os.path.dirname(os.path.abspath(chemin)), exist_ok=True)
    fd = os.open(chemin, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="ascii") as f:
        f.write(sel.hex() + "\n")
    if uid is not None:
        os.chown(chemin, uid, gid if gid is not None else -1)
    return sel


class Anonymiseur:
    def __init__(self, sel, actif=True, utilisateur=None, machine=None):
        self.sel = sel
        self.actif = actif
        self.secrets = {}          # valeur → étiquette de remplacement
        self.utilisateur = utilisateur if utilisateur and len(utilisateur) >= 3 else None
        self.machine = machine if machine and machine != "zorin-nomade" and len(machine) >= 3 else None

    def empreinte(self, genre, valeur):
        mac = hmac.new(self.sel, ("%s:%s" % (genre, valeur.strip())).encode(), hashlib.sha256)
        return mac.hexdigest()[:16]

    def secret(self, genre, valeur):
        """Déclare un identifiant ; renvoie son empreinte (ou None si générique)."""
        if valeur is None:
            return None
        v = str(valeur).strip()
        if v.lower() in GENERIQUES or len(v) < 4 or len(set(v.replace("-", ""))) <= 1:
            return None
        e = self.empreinte(genre, v)
        self.secrets.setdefault(v, "«empreinte:%s:%s»" % (genre, e))
        return e

    def nettoyer(self, texte, motifs=True):
        """Identifiants déclarés remplacés ; avec ``motifs``, MAC, IP, courriels, nom de
        l'utilisateur et de la machine aussi (pas pour resume.json : des numéros de version y
        ressemblent à des IPv4, et ses champs sont choisis un à un)."""
        if not self.actif or not texte:
            return texte
        for v in sorted(self.secrets, key=len, reverse=True):
            texte = texte.replace(v, self.secrets[v])
            if v.lower() != v:
                texte = texte.replace(v.lower(), self.secrets[v])
        if not motifs:
            return texte
        texte = RE_MAC.sub("«mac»", texte)
        texte = RE_IPV4.sub(lambda m: "«ip»" if ipv4_publique(m.group(0)) else m.group(0), texte)
        texte = RE_IPV6.sub(lambda m: m.group(0) if m.group(0) == "::1" else "«ip»", texte)
        texte = RE_COURRIEL.sub("«courriel»", texte)
        texte = RE_HOME.sub("/home/utilisateur", texte)
        if self.utilisateur:
            texte = re.sub(r"\b%s\b" % re.escape(self.utilisateur), "utilisateur", texte)
        if self.machine:
            texte = re.sub(r"\b%s\b" % re.escape(self.machine), "machine", texte)
        return texte

    def trouvailles(self, nom, texte, motifs=True):
        """Ce qui reste d'identifiant dans ``texte`` (liste de descriptions, vide si propre)."""
        if not self.actif:
            return []
        t = []
        for v in self.secrets:
            if v in texte or v.lower() in texte:
                t.append("%s : identifiant déclaré (%s)" % (nom, self.secrets[v]))
        if motifs:
            if RE_MAC.search(texte):
                t.append("%s : adresse MAC" % nom)
            if any(ipv4_publique(m.group(0)) for m in RE_IPV4.finditer(texte)):
                t.append("%s : adresse IPv4" % nom)
            if RE_COURRIEL.search(texte):
                t.append("%s : courriel" % nom)
        if self.utilisateur and re.search(r"\b%s\b" % re.escape(self.utilisateur), texte):
            t.append("%s : nom de l'utilisateur" % nom)
        return t
