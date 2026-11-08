"""nomade-diag : diagnostic du système déployé, depuis la clé elle-même (D-048, SPEC E-46).

Deux phases, enchaînées par /usr/local/bin/nomade-diag :
- ``--phase session`` (utilisateur, dans la session graphique) : rendu OpenGL, type de session, son ;
- ``--phase systeme`` (root, par sudo) : tout le reste, puis l'archive.
Chaque section est indépendante : une erreur la note « non lu » sans arrêter le diagnostic.
Rien n'est modifié sur le PC ; sur la clé, seuls l'archive et, avec --mesures, un fichier
d'essai sans nom (O_TMPFILE, disparu même après un arrêt brutal) sont écrits.
"""

import argparse
import glob
import json
import os
import re
import shutil
import struct
import sys
import traceback

from . import SCHEMA, archive, materiel, mesures as M
from .anonymat import Anonymiseur, lire_ou_creer_sel
from .commun import (arrondi, commande, entier, est_root, horodatage, lire, log, maintenant, reduire,
                     sortie, valeurs_env)

DATA_MNT = "/media/NOMADE-DATA"
SEL = "/var/lib/nomade/diag-sel"
EFI = "/sys/firmware/efi/efivars"
GUID_GLOBAL = "8be4df61-93ca-11d2-aa0d-00e098032b8c"
GUID_DB = "d719b2cb-3d3a-4596-a3bc-dad00e67656f"
UNITES_RESEAU = ("NetworkManager", "wpa_supplicant", "avahi-daemon", "systemd-resolved", "dhclient",
                 "ModemManager", "cups", "cups-browsed", "systemd-networkd", "bluetoothd")


# --- Phase session (utilisateur) --------------------------------------------------------------

def phase_session(dossier):
    d = {"session_type": os.environ.get("XDG_SESSION_TYPE"), "bureau": os.environ.get("XDG_CURRENT_DESKTOP"),
         "glxinfo": sortie(["glxinfo", "-B"], 20), "pactl": sortie(["pactl", "info"], 10)}
    with open(os.path.join(dossier, "session.json"), "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False)
    return 0


# --- Aides -----------------------------------------------------------------------------------

def efivar(nom, guid):
    """Contenu d'une variable EFI, sans les 4 octets d'attributs (None si absente)."""
    try:
        with open(os.path.join(EFI, "%s-%s" % (nom, guid)), "rb") as f:
            return f.read()[4:]
    except OSError:
        return None


def entrees_signatures(donnees):
    """Nombre d'entrées d'une base de signatures UEFI (db, dbx) : suite d'EFI_SIGNATURE_LIST."""
    if donnees is None:
        return None
    n, i = 0, 0
    while i + 28 <= len(donnees):
        taille_liste, taille_entete, taille_sig = struct.unpack_from("<III", donnees, i + 16)
        if taille_liste < 28 or taille_sig == 0:
            break
        n += (taille_liste - 28 - taille_entete) // taille_sig
        i += taille_liste
    return n


def sujets(texte):
    """CN des certificats listés par mokutil (--db, --pk, --kek)."""
    s = []
    for ligne in texte.splitlines():
        if "Subject:" in ligne:
            m = re.search(r"CN\s*=\s*([^,/]+)", ligne)
            if m:
                s.append(m.group(1).strip())
    return s


def edid(chemin):
    """Fabricant (3 lettres), code produit, nom et numéros de série d'un EDID."""
    try:
        with open(chemin, "rb") as f:
            e = f.read()
    except OSError:
        return None
    if len(e) < 128 or e[:8] != b"\x00\xff\xff\xff\xff\xff\xff\x00":
        return None
    m = struct.unpack(">H", e[8:10])[0]
    fab = "".join(chr(((m >> s) & 0x1F) + 64) for s in (10, 5, 0))
    r = {"fabricant": fab, "produit": "%04x" % struct.unpack("<H", e[10:12])[0], "nom": None,
         "_series": []}
    serie = struct.unpack("<I", e[12:16])[0]
    if serie:
        r["_series"].append(str(serie))
    for k in range(4):
        b = e[54 + 18 * k:72 + 18 * k]
        if b[:3] == b"\x00\x00\x00" and b[3] in (0xFC, 0xFF):
            t = b[5:18].split(b"\x0a")[0].decode("ascii", "replace").strip()
            if b[3] == 0xFC:
                r["nom"] = t
            elif t:
                r["_series"].append(t)
    return r


def disque_racine():
    """(source de /, partition, disque) : /dev/mapper/nomade-root → /dev/sdX3 → sdX."""
    src = sortie(["findmnt", "-no", "SOURCE", "/"]).strip()
    part = None
    for ligne in sortie(["lsblk", "-nrspo", "NAME,TYPE", src]).splitlines():
        nom, _, typ = ligne.partition(" ")
        if typ == "part":
            part = nom
            break
    disque = sortie(["lsblk", "-ndo", "PKNAME", part]).strip() if part else None
    return src, part, disque or None


def compter(motif, texte):
    return len(re.findall(motif, texte, re.MULTILINE))


# --- Sections (chacune renvoie un dictionnaire ; ``ctx`` porte l'anonymiseur et les bruts) ----

def s_versions(ctx):
    b, d, o = valeurs_env("/etc/nomade/build-info"), valeurs_env("/etc/nomade/deploy-info"), \
        valeurs_env("/etc/os-release")
    paquets = {}
    for p in ("shim-signed", "grub-efi-amd64-signed", "libgl1-mesa-dri", "linux-firmware"):
        paquets[p] = (sortie(["dpkg-query", "-W", "-f=${Version}\\n", p]).split() or [None])[0]
    ctx["brut"]["brut/versions.txt"] = "\n".join(["# build-info", lire("/etc/nomade/build-info"),
                                                 "# deploy-info", lire("/etc/nomade/deploy-info"),
                                                 "# os-release", lire("/etc/os-release")])
    return {"nomade_version": b.get("NOMADE_VERSION"), "image": d.get("DEPLOY_IMAGE"),
            "deploy_version": d.get("DEPLOY_VERSION"), "deploy_date": d.get("DEPLOY_DATE"),
            "zorin": o.get("VERSION_ID"), "systeme": o.get("PRETTY_NAME"),
            "noyau": os.uname().release, "paquets": paquets, "deploye": bool(d)}


def s_autotest(ctx):
    st = os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "selftest.sh")
    if not os.path.exists(st):
        return None
    code, out, _ = commande(["bash", st, "--materiel"], delai=300)
    lignes = [x for x in out.splitlines() if x.startswith("NOMADE-SELFTEST:")]
    ctx["brut"]["brut/autotest.txt"] = "\n".join(lignes)
    echecs = [x.split("FAIL", 1)[1].strip() for x in lignes if " FAIL " in x]
    return {"pass": sum(" PASS " in x for x in lignes), "fail": len(echecs), "echecs": echecs,
            "code": code}


def s_pc(ctx):
    a = ctx["anon"]
    dmi = lambda f: lire("/sys/class/dmi/id/" + f) or None
    for f in ("product_serial", "product_uuid", "board_serial", "chassis_serial", "board_asset_tag",
              "chassis_asset_tag"):
        a.secret("pc", dmi(f))
    ident = dmi("product_uuid") or dmi("product_serial") or dmi("board_serial")
    empreinte = a.empreinte("pc", ident) if ident else a.empreinte(
        "pc", "modele:%s:%s" % (dmi("product_name"), dmi("bios_version")))
    cpu = {}
    try:
        for e in json.loads(sortie(["lscpu", "-J"]))["lscpu"]:
            cpu[e["field"].rstrip(":")] = e["data"]
    except (ValueError, KeyError):
        pass
    mem = valeurs_meminfo()
    barrettes = []
    if est_root():
        bloc = {}
        for ligne in sortie(["dmidecode", "-t", "17"]).splitlines() + [""]:
            ligne = ligne.strip()
            if not ligne:
                if bloc.get("Size") and "No Module" not in bloc.get("Size", ""):
                    barrettes.append({"taille": bloc.get("Size"), "type": bloc.get("Type"),
                                      "vitesse": bloc.get("Configured Memory Speed") or bloc.get("Speed")})
                    a.secret("pc", bloc.get("Serial Number"))
                bloc = {}
            elif ":" in ligne:
                k, _, v = ligne.partition(":")
                bloc[k.strip()] = v.strip()
    batterie = None
    for bat in glob.glob("/sys/class/power_supply/BAT*"):
        plein = entier(lire(bat + "/energy_full")) or entier(lire(bat + "/charge_full"))
        neuf = entier(lire(bat + "/energy_full_design")) or entier(lire(bat + "/charge_full_design"))
        a.secret("pc", lire(bat + "/serial_number"))
        batterie = {"sante_pct": round(100 * plein / neuf) if plein and neuf else None,
                    "cycles": entier(lire(bat + "/cycle_count"))}
    return {"empreinte": empreinte, "fabricant": dmi("sys_vendor"), "modele": dmi("product_name"),
            "version": dmi("product_version"), "famille": dmi("product_family"),
            "carte": {"fabricant": dmi("board_vendor"), "modele": dmi("board_name")},
            "type_chassis": entier(dmi("chassis_type")),
            "firmware": {"editeur": dmi("bios_vendor"), "version": dmi("bios_version"), "date": dmi("bios_date")},
            "cpu": cpu.get("Model name"), "cpu_fils": entier(cpu.get("CPU(s)")),
            "ram_mib": mem.get("MemTotal", 0) // 1024 or None, "barrettes": barrettes,
            "batterie": batterie, "tpm": os.path.exists("/sys/class/tpm/tpm0"),
            "tpm_version": entier(lire("/sys/class/tpm/tpm0/tpm_version_major")),
            "uefi_bits": entier(lire("/sys/firmware/efi/fw_platform_size"))}


def s_secure_boot(ctx):
    etat = sortie(["mokutil", "--sb-state"])
    sb = efivar("SecureBoot", GUID_GLOBAL)
    setup = efivar("SetupMode", GUID_GLOBAL)
    db_txt, pk_txt, kek_txt = sortie(["mokutil", "--db"], 20), sortie(["mokutil", "--pk"]), \
        sortie(["mokutil", "--kek"])
    db = sujets(db_txt)
    ctx["brut"]["brut/secure-boot.txt"] = "\n".join(
        ["# mokutil --sb-state", etat, "# db (sujets)", "\n".join(db), "# PK", "\n".join(sujets(pk_txt)),
         "# KEK", "\n".join(sujets(kek_txt)), "# SBAT", sortie(["mokutil", "--list-sbat-revocations"])])
    return {"actif": (sb[0] == 1) if sb else (False if os.path.isdir(EFI) else None),
            "mode_installation": (setup[0] == 1) if setup else None,
            "ms_uefi_ca_2011": any("Microsoft Corporation UEFI CA 2011" in s for s in db) if db else None,
            "ms_uefi_ca_2023": any("Microsoft UEFI CA 2023" in s for s in db) if db else None,
            "windows_pca_2011": any("Windows Production PCA 2011" in s for s in db) if db else None,
            "db": db, "pk": (sujets(pk_txt) or [None])[0],
            "db_entrees": entrees_signatures(efivar("db", GUID_DB)),
            "dbx_entrees": entrees_signatures(efivar("dbx", GUID_DB))}


def lspci_appareils():
    """Appareils PCI : liste de {classe, id, nom, pilote}."""
    app, cur = [], {}
    for ligne in sortie(["lspci", "-vmm", "-nn", "-k"]).splitlines() + [""]:
        if not ligne.strip():
            if cur:
                app.append(cur)
            cur = {}
            continue
        k, _, v = ligne.partition(":")
        cur[k.strip()] = v.strip()
    r = []
    for a in app:
        ids = re.findall(r"\[([0-9a-f]{4})\]", a.get("Vendor", "") + a.get("Device", ""))
        r.append({"classe": (re.search(r"\[([0-9a-f]{4})\]", a.get("Class", "")) or [None, None])[1],
                  "id": ":".join(ids[:2]) if len(ids) >= 2 else None,
                  "nom": re.sub(r"\s*\[[0-9a-f]{4}\]", "", "%s %s" % (a.get("Vendor", ""), a.get("Device", ""))).strip(),
                  "pilote": a.get("Driver")})
    return r


def s_affichage(ctx, session):
    gpu = [x for x in lspci_appareils() if (x["classe"] or "").startswith("03")]
    glx = (session or {}).get("glxinfo") or ""
    moteur = (re.search(r"OpenGL renderer string:\s*(.+)", glx) or [None, None])[1]
    accel = (re.search(r"Accelerated:\s*(\w+)", glx) or [None, None])[1]
    ecrans = []
    for c in sorted(glob.glob("/sys/class/drm/card*-*")):
        if lire(c + "/status") != "connected":
            continue
        e = edid(c + "/edid") or {}
        for s in e.pop("_series", []):
            ctx["anon"].secret("ecran", s)
        modes = lire(c + "/modes").splitlines()
        ecrans.append({"connecteur": os.path.basename(c).split("-", 1)[1], "fabricant": e.get("fabricant"),
                       "produit": e.get("produit"), "nom": e.get("nom"), "mode": modes[0] if modes else None})
    ctx["brut"]["brut/glxinfo.txt"] = glx
    return {"gpu": gpu, "session": (session or {}).get("session_type"), "bureau": (session or {}).get("bureau"),
            "moteur": moteur.strip() if moteur else None,
            "logiciel": bool(moteur and re.search(r"llvmpipe|softpipe|swrast", moteur)) if moteur else None,
            "accelere": (accel == "yes") if accel else None, "ecrans": ecrans}


def s_peripheriques(ctx, session):
    a = ctx["anon"]
    reseau = []
    etats = {}
    for ligne in sortie(["nmcli", "-t", "-f", "DEVICE,TYPE,STATE", "device"]).splitlines():
        p = ligne.split(":")
        if len(p) >= 3:
            etats[p[0]] = (p[1], p[2])
    for n in sorted(os.listdir("/sys/class/net")):
        if n == "lo" or n.startswith(("veth", "docker", "br-", "virbr")):
            continue
        base = "/sys/class/net/" + n
        mac = lire(base + "/address")
        a.secret("mac", mac)
        a.secret("mac", mac.replace(":", ""))
        if not os.path.exists(base + "/device"):
            continue
        sans_fil = os.path.exists(base + "/wireless") or os.path.exists(base + "/phy80211")
        dev = os.path.realpath(base + "/device")
        ident = None
        if os.path.exists(dev + "/vendor"):
            ident = "%s:%s" % (lire(dev + "/vendor")[2:], lire(dev + "/device")[2:])
        else:
            d = dev
            while d not in ("/", "") and not os.path.exists(d + "/idVendor"):
                d = os.path.dirname(d)
            if os.path.exists(d + "/idVendor"):
                ident = "%s:%s" % (lire(d + "/idVendor"), lire(d + "/idProduct"))
        pilote = os.path.basename(os.path.realpath(base + "/device/driver")) \
            if os.path.exists(base + "/device/driver") else None
        etat = etats.get(n, (None, None))[1]
        reseau.append({"type": "wifi" if sans_fil else "ethernet", "id": ident, "pilote": pilote,
                       "etat": etat, "fonctionne": (etat or "").startswith("connect") and "dis" not in (etat or "")})
    sans_pilote = [x for x in lspci_appareils() if (x["classe"] or "").startswith("02") and not x["pilote"]]
    for h in glob.glob("/sys/class/bluetooth/hci*"):
        a.secret("mac", lire(h + "/address"))
    cartes = [l_.strip() for l_ in lire("/proc/asound/cards").splitlines() if re.match(r"\s*\d+ \[", l_)]
    webcams = sorted({lire(v + "/name") for v in glob.glob("/sys/class/video4linux/video*")} - {""})
    for d in glob.glob("/sys/bus/usb/devices/*/serial"):
        a.secret("usb", lire(d))
    ctx["brut"]["brut/lspci.txt"] = sortie(["lspci", "-nnk"])
    ctx["brut"]["brut/lsusb.txt"] = sortie(["lsusb"]) + "\n" + sortie(["lsusb", "-t"])
    pactl = (session or {}).get("pactl") or ""
    return {"reseau": reseau, "reseau_sans_pilote": [{"id": x["id"], "nom": x["nom"]} for x in sans_pilote],
            "bluetooth": bool(glob.glob("/sys/class/bluetooth/hci*")), "son": cartes,
            "serveur_son": (re.search(r"Server Name:\s*(.+)", pactl) or [None, None])[1], "webcams": webcams}


def s_cle(ctx):
    a = ctx["anon"]
    src, part, disque = disque_racine()
    if not disque:
        return None
    ident = materiel.identifier("/dev/" + disque)
    for g, v in ident.pop("_secrets"):
        a.secret(g, v)
    d = valeurs_env("/etc/nomade/deploy-info")
    empreinte = d.get("DEPLOY_CLE_EMPREINTE") or materiel.empreinte_cle(a, "/dev/" + disque, ident)
    for ligne in sortie(["lsblk", "-nro", "UUID,PARTUUID,PTUUID", "/dev/" + disque]).splitlines():
        for v in ligne.split():
            a.secret("uuid", v)
    luks = None
    if src.startswith("/dev/mapper/"):
        st = sortie(["cryptsetup", "status", os.path.basename(src)])
        drapeaux = (re.search(r"flags:\s*(.+)", st) or [None, ""])[1].split()
        luks = {"chiffrement": (re.search(r"cipher:\s*(\S+)", st) or [None, None])[1],
                "taille_cle_bits": entier((re.search(r"keysize:\s*(\d+)", st) or [None, None])[1]),
                "drapeaux": drapeaux}
        a.secret("uuid", sortie(["cryptsetup", "luksUUID", part]).strip() if part else None)
    noyau = ctx["noyau"]
    fstrim = sortie(["journalctl", "-u", "fstrim.service", "-n", "20", "-o", "cat", "--no-pager"])
    data = None
    if os.path.ismount(DATA_MNT):
        st_ = os.statvfs(DATA_MNT)
        data = {"taille_gio": arrondi(st_.f_blocks * st_.f_frsize / 2 ** 30, 1),
                "libre_gio": arrondi(st_.f_bavail * st_.f_frsize / 2 ** 30, 1)}
    ctx["disque"] = "/dev/" + disque
    idf = ident.get("identification")
    return {"empreinte": empreinte,
            "vid_pid": "%04x:%04x" % (ident["vid"], ident["pid"]) if ident.get("vid") is not None else None,
            "identification": {"role": idf["role"], "nom": idf["nom"], "precision": idf["precision"]} if idf else None,
            "usb": {"version": ident.get("version_usb"), "vitesse_mbps": ident.get("vitesse_mbps"),
                    "pilote": ident.get("pilote"), "bridee_usb2": ident.get("bridee_usb2"),
                    "concentrateur": ident.get("concentrateur"), "quirk_usb_storage": ident.get("quirk_usb_storage")},
            "capacite_gio": arrondi((ident.get("capacite_octets") or 0) / 2 ** 30, 1),
            "trim": (ident["discard_max_octets"] > 0) if ident.get("discard_max_octets") is not None else None,
            "provisioning_mode": ident.get("provisioning_mode"), "file_commandes": ident.get("file_commandes"),
            "rotatif_declare": ident.get("rotatif_declare"), "ordonnanceur": ident.get("ordonnanceur"),
            "reinitialisations_usb": compter(r"uas_eh|reset (?:SuperSpeed|high-speed|full-speed)", noyau),
            "erreurs_es": compter(r"I/O error, dev %s|Buffer I/O error on dev %s" % (disque, disque), noyau),
            "luks": luks, "fstrim_dernier": (fstrim.strip().splitlines() or [None])[-1],
            "deploy_discard": entier(d.get("DEPLOY_DISCARD")), "data_gib": entier(d.get("DEPLOY_DATA_GIB")),
            "data": data}


def s_demarrage(ctx):
    t = sortie(["systemd-analyze", "time"], 30)
    r = {}

    def secondes(texte):
        s = 0.0
        for v, u in re.findall(r"([\d.]+)(min|ms|s)", texte):
            s += float(v) * {"min": 60, "s": 1, "ms": 0.001}[u]
        return round(s, 1)

    for valeur, phase in re.findall(r"((?:\d+min )?[\d.]+m?s) \((\w+)\)", t):
        r[{"firmware": "firmware_s", "loader": "chargeur_s", "kernel": "noyau_s", "initrd": "initrd_s",
           "userspace": "espace_utilisateur_s"}.get(phase, phase + "_s")] = secondes(valeur)
    tot = re.search(r"= ((?:\d+min )?[\d.]+m?s)", t)
    r["total_s"] = secondes(tot.group(1)) if tot else None
    plus_lents = []
    for ligne in sortie(["systemd-analyze", "blame", "--no-pager"], 30).splitlines()[:15]:
        p = ligne.split()
        if len(p) >= 2:
            plus_lents.append({"unite": p[-1], "s": secondes(" ".join(p[:-1]))})
    r["plus_lents"] = plus_lents
    ctx["brut"]["brut/demarrage.txt"] = t + "\n" + sortie(["systemd-analyze", "critical-chain", "--no-pager"], 30)
    return r


def valeurs_meminfo():
    d = {}
    for ligne in lire("/proc/meminfo").splitlines():
        k, _, v = ligne.partition(":")
        d[k] = entier(v.split()[0]) if v.split() else None
    return d


def s_memoire(ctx):
    m = valeurs_meminfo()
    zram, taux = None, None
    for ligne in sortie(["zramctl", "--bytes", "--noheadings", "--raw", "--output", "DISKSIZE,DATA,COMPR"]).splitlines():
        p = [entier(x) for x in ligne.split()]
        if len(p) == 3 and p[0]:
            zram = p[0] // 2 ** 20
            taux = round(p[1] / p[2], 2) if p[2] else None
    psi = (re.search(r"some avg10=[\d.]+ avg60=[\d.]+ avg300=([\d.]+)", lire("/proc/pressure/memory")) or [None, None])[1]
    ctx["brut"]["brut/memoire.txt"] = "\n".join([lire("/proc/meminfo"), sortie(["zramctl"]),
                                                 lire("/proc/pressure/memory"),
                                                 "\n".join(sortie(["ps", "-eo", "comm,rss", "--sort=-rss"])
                                                           .splitlines()[:16])])
    return {"totale_mib": (m.get("MemTotal") or 0) // 1024, "disponible_mib": (m.get("MemAvailable") or 0) // 1024,
            "zram_mib": zram, "zram_taux": taux,
            "swap_utilise_mib": ((m.get("SwapTotal") or 0) - (m.get("SwapFree") or 0)) // 1024,
            "psi_memoire_avg300": float(psi) if psi else None,
            "plus_gros": [l_.split()[0] for l_ in sortie(["ps", "-eo", "comm,rss", "--sort=-rss", "--no-headers"])
                          .splitlines()[:10] if l_.split()]}


def s_ecritures(ctx):
    disque = ctx.get("disque")
    if not disque:
        return None
    nom = os.path.basename(disque)
    ecrit = None
    for ligne in lire("/proc/diskstats").splitlines():
        p = ligne.split()
        if len(p) > 9 and p[2] == nom:
            ecrit = int(p[9]) * 512
    up = float(lire("/proc/uptime").split()[0] or 0)
    src = sortie(["findmnt", "-no", "SOURCE", "/"]).strip()
    dm = os.path.basename(os.path.realpath(src))
    ext4 = entier(lire("/sys/fs/ext4/%s/lifetime_write_kbytes" % dm))
    return {"depuis_demarrage_mib": ecrit // 2 ** 20 if ecrit is not None else None, "uptime_s": round(up),
            "debit_mib_h": round(ecrit / 2 ** 20 / (up / 3600), 1) if ecrit and up > 60 else None,
            "ext4_total_gib": round(ext4 / 2 ** 20, 1) if ext4 else None}


def s_erreurs(ctx):
    noyau = ctx["noyau"]
    echecs = [l_.split()[0] for l_ in sortie(["systemctl", "--failed", "--plain", "--no-legend"]).splitlines()
              if l_.split()]
    par_unite, lignes = {}, []
    code, out, _ = commande(["journalctl", "-b", "-p", "err", "-o", "json", "--no-pager"], delai=60)
    for ligne in out.splitlines():
        try:
            e = json.loads(ligne)
        except ValueError:
            continue
        u = e.get("_SYSTEMD_UNIT") or e.get("SYSLOG_IDENTIFIER") or "?"
        par_unite[u] = par_unite.get(u, 0) + 1
        if not any(r in u for r in UNITES_RESEAU) and isinstance(e.get("MESSAGE"), str) and len(lignes) < 400:
            lignes.append("%s: %s" % (u, e["MESSAGE"]))
    ctx["brut"]["journal/erreurs.txt"] = "\n".join(lignes)
    fw = sorted(set(re.findall(r"(?:Direct firmware load for|firmware: failed to load) (\S+)", noyau)))
    coredumps = []
    try:
        for e in json.loads(sortie(["coredumpctl", "list", "--json=short", "--no-pager", "-q"]) or "[]"):
            coredumps.append(os.path.basename(e.get("exe") or "?"))
    except ValueError:
        pass
    return {"unites_en_echec": echecs, "journal_err": sum(par_unite.values()),
            "par_unite": dict(sorted(par_unite.items(), key=lambda x: -x[1])[:20]),
            "firmwares_manquants": fw, "acpi": compter(r"ACPI (?:BIOS )?Error", noyau),
            "oops": compter(r"Oops|BUG:|WARNING: CPU", noyau),
            "gpu_blocages": compter(r"GPU HANG|ring \S+ timeout|GPU reset|gpu reset", noyau),
            "noyau_contamine": entier(lire("/proc/sys/kernel/tainted")), "plantages": coredumps}


# --- Mesures (--mesures) ---------------------------------------------------------------------

def mesures(ctx, ecriture_max_mib):
    r = {"lecture": None, "ecriture": None, "aes_xts": None}
    if ctx.get("disque"):
        log("mesures : lectures directes sur %s (≈ 24 s, rien n'est écrit)" % ctx["disque"])
        lec = M.lecture(ctx["disque"])
        ctx["brut"]["mesures/lecture.json"] = archive.json_texte(lec)
        r["lecture"] = {"directes": lec["directes"], "sequentielle_mo_s": lec["sequentielle"]["mo_s"],
                        "aleatoire_1": resume_alea(lec["aleatoire_1"]), "aleatoire_8": resume_alea(lec["aleatoire_8"]),
                        "gain_parallele": lec["gain_parallele"]}
    if ecriture_max_mib > 0:
        r["ecriture"] = ecriture_plafonnee(ctx, ecriture_max_mib)
    code, out, _ = commande(["cryptsetup", "benchmark", "-c", "aes-xts-plain64", "-s", "512"], delai=60)
    m = re.search(r"aes-xts\s+512b\s+([\d.]+)\s+MiB/s\s+([\d.]+)\s+MiB/s", out or "")
    if m:
        r["aes_xts"] = {"chiffrement_mio_s": float(m.group(1)), "dechiffrement_mio_s": float(m.group(2))}
    return r


def resume_alea(x):
    return {k: x.get(k) for k in ("en_parallele", "operations", "iops", "mo_s", "mediane_us", "p90_us", "p99_us",
                                  "max_us")}


class SupportFd(M.Support):
    """Fichier d'essai sans nom (O_TMPFILE) sur la racine, rouvert ``n`` fois par /proc/self/fd."""

    def __init__(self, dossier, n):
        self.fds, self.directes = [], True
        drap = os.O_RDWR | os.O_TMPFILE
        try:
            fd = os.open(dossier, drap | os.O_DIRECT, 0o600)
        except OSError:
            fd = os.open(dossier, drap, 0o600)
            self.directes = False
        self.fds.append(fd)
        for _ in range(n - 1):
            self.fds.append(os.open("/proc/self/fd/%d" % fd, os.O_RDWR | (os.O_DIRECT if self.directes else 0)))
        self.taille = 0


def ecriture_plafonnee(ctx, plafond_mib):
    """Écritures sur la racine (ext4 sur LUKS, le chemin réel), au plus ``plafond_mib`` au total."""
    dossier = "/var/tmp"
    st = os.statvfs(dossier)
    if st.f_bavail * st.f_frsize < 2 * 2 ** 30:
        return {"refus": "moins de 2 Gio libres sur la racine"}
    plafond = plafond_mib * 2 ** 20
    zone = max(min(256 * 2 ** 20, plafond // 4) // M.BLOC_SEQUENTIEL, 1) * M.BLOC_SEQUENTIEL
    budget_alea = plafond // 16 // M.BLOC_ALEATOIRE       # opérations par test aléatoire
    log("mesures : écritures sur la racine, %d Mio au plus (fichier d'essai sans nom)" % plafond_mib)
    sup = SupportFd(dossier, M.EN_PARALLELE)
    try:
        r = {"directes": sup.directes, "plafond_mib": plafond_mib}
        rempli = M.ecriture_longue(sup, (0, zone), 30)
        sup.taille = rempli["octets"]
        z = (0, sup.taille)
        d = M.DUREE_ECRITURE_S
        r["ecriture_4k_1"] = resume_alea(M.aleatoire(sup, z, d, M.ECRITURE, 1, budget_alea))
        r["ecriture_4k_8"] = resume_alea(M.aleatoire(sup, z, d, M.ECRITURE, M.EN_PARALLELE, budget_alea))
        r["ecriture_synchro"] = resume_alea(M.aleatoire(sup, z, d, M.ECRITURE_SYNCHRO, 1, budget_alea // 4))
        reste = plafond - zone - (2 * budget_alea + budget_alea // 4) * M.BLOC_ALEATOIRE
        longue = M.ecriture_longue(sup, (zone, zone + max(reste, 0)), 30, plafond_octets=max(reste, 0))
        r["ecriture_seq_mo_s"] = longue["mo_s"]
        r["ecrit_mib"] = (zone + longue["octets"]) // 2 ** 20 + (2 * budget_alea + budget_alea // 4) * 4 // 1024
    finally:
        sup.fermer()
    return r


# --- Assemblage ------------------------------------------------------------------------------

def alertes(res):
    A_ = []
    sb, pc = res.get("secure_boot") or {}, res.get("pc") or {}
    if sb.get("ms_uefi_ca_2011") is False:
        A_.append("Pas de « Microsoft Corporation UEFI CA 2011 » dans la base db de ce PC : avec Secure Boot "
                  "actif, la clé ne démarre que si l'option « Microsoft UEFI CA » (ou « tiers ») du firmware est "
                  "activée.")
    aff = res.get("affichage") or {}
    if aff.get("logiciel"):
        A_.append("Rendu graphique logiciel (%s) : pilote graphique absent ou en échec." % aff.get("moteur"))
    cle = res.get("cle") or {}
    if (cle.get("usb") or {}).get("bridee_usb2"):
        A_.append("La clé est en USB 2 sur ce port : essaie un autre port (bleu, USB 3) ou retire la rallonge.")
    if cle.get("reinitialisations_usb"):
        A_.append("%d réinitialisation(s) USB de la clé depuis le démarrage (journal du noyau)."
                  % cle["reinitialisations_usb"])
    if cle.get("erreurs_es"):
        A_.append("%d erreur(s) d'entrée-sortie sur la clé." % cle["erreurs_es"])
    err = res.get("erreurs") or {}
    if err.get("unites_en_echec"):
        A_.append("Unités en échec : %s." % ", ".join(err["unites_en_echec"]))
    if err.get("firmwares_manquants"):
        A_.append("Firmwares manquants : %s." % ", ".join(err["firmwares_manquants"][:8]))
    per = res.get("peripheriques") or {}
    if per.get("reseau_sans_pilote"):
        A_.append("Carte réseau sans pilote : %s." % ", ".join(x["nom"] for x in per["reseau_sans_pilote"]))
    if (pc.get("ram_mib") or 99999) < 3800:
        A_.append("Moins de 4 Gio de RAM : le bureau sera à l'étroit.")
    at = (res.get("systeme") or {}).get("autotest") or {}
    if at.get("fail"):
        A_.append("Autotest : %d contrôle(s) en échec (%s)." % (at["fail"], "; ".join(at["echecs"][:5])))
    return A_


def fr(x):
    """Valeur lisible en français dans rapport.txt."""
    return {True: "oui", False: "non", None: "?"}.get(x, x) if isinstance(x, (bool, type(None))) else x


def texte_rapport(res):
    pc, sy, cle, dem = res.get("pc") or {}, res.get("systeme") or {}, res.get("cle") or {}, res.get("demarrage") or {}
    sb, aff, mem = res.get("secure_boot") or {}, res.get("affichage") or {}, res.get("memoire") or {}
    L = ["Diagnostic zorin-nomade (%s, %s)" % (res["outil"]["version"], res["date"]), "",
         "PC : %s %s (%s), firmware %s du %s" % (pc.get("fabricant"), pc.get("modele"), pc.get("cpu"),
                                                 (pc.get("firmware") or {}).get("version"),
                                                 (pc.get("firmware") or {}).get("date")),
         "  RAM %s Mio, Secure Boot %s, CA Microsoft 2011 : %s, 2023 : %s"
         % (pc.get("ram_mib"), "actif" if sb.get("actif") else "inactif", fr(sb.get("ms_uefi_ca_2011")),
            fr(sb.get("ms_uefi_ca_2023"))),
         "  affichage : %s (%s), session %s" % (aff.get("moteur"), "logiciel" if aff.get("logiciel") else "matériel",
                                                aff.get("session")),
         "Système : zorin-nomade %s, Zorin %s, noyau %s" % (sy.get("nomade_version"), sy.get("zorin"), sy.get("noyau")),
         "Clé : %s %s, %s, %s Mbit/s, TRIM %s, %s réinitialisation(s)"
         % (cle.get("vid_pid"), (cle.get("identification") or {}).get("nom"), (cle.get("usb") or {}).get("pilote"),
            (cle.get("usb") or {}).get("vitesse_mbps"), fr(cle.get("trim")), cle.get("reinitialisations_usb")),
         "Démarrage : firmware %s s, chargeur %s s, noyau %s s (saisie de la phrase comprise), espace utilisateur %s s"
         % (dem.get("firmware_s"), dem.get("chargeur_s"), dem.get("noyau_s"), dem.get("espace_utilisateur_s")),
         "Mémoire : %s Mio disponibles, zram %s Mio (×%s), échange utilisé %s Mio"
         % (mem.get("disponible_mib"), mem.get("zram_mib"), mem.get("zram_taux"), mem.get("swap_utilise_mib"))]
    me = res.get("mesures")
    if me and me.get("lecture"):
        lec = me["lecture"]
        L.append("Mesures : lecture %s Mo/s ; 4 Kio : %s IOPS (1), %s IOPS (8)"
                 % (lec["sequentielle_mo_s"], lec["aleatoire_1"]["iops"], lec["aleatoire_8"]["iops"]))
    if me and me.get("ecriture") and "refus" not in me["ecriture"]:
        e = me["ecriture"]
        L.append("  écriture (racine chiffrée) : %s Mo/s séquentielle, 4 Kio %s Mo/s, synchronisée médiane %s µs"
                 % (e["ecriture_seq_mo_s"], e["ecriture_4k_1"]["mo_s"], e["ecriture_synchro"]["mediane_us"]))
    if me and me.get("aes_xts"):
        L.append("  AES-XTS : %s Mio/s" % me["aes_xts"]["chiffrement_mio_s"])
    L += ["", "Alertes :"] + (["  - " + x for x in res["alertes"]] or ["  (aucune)"])
    return "\n".join(L) + "\n"


def destination(sortie_):
    if sortie_:
        return sortie_
    if os.path.ismount(DATA_MNT):
        return os.path.join(DATA_MNT, "nomade-diag")
    util = os.environ.get("SUDO_USER") or valeurs_env("/etc/nomade/expected.env").get("TARGET_USER") or "root"
    maison = os.path.expanduser("~" + util)
    return os.path.join(maison, "nomade-diag")


def main(argv):
    p = argparse.ArgumentParser(prog="nomade-diag")
    p.add_argument("--phase", choices=("session", "systeme"), default="systeme")
    p.add_argument("--session-dir")
    p.add_argument("--mesures", action="store_true")
    p.add_argument("--ecriture-max", type=int, default=1024, help="Mio écrits au plus par --mesures (0 : aucun)")
    p.add_argument("--brut", action="store_true")
    p.add_argument("--sortie")
    p.add_argument("--test", action="store_true", help="lancé par l'autotest QEMU (noté dans le résumé)")
    a = p.parse_args(argv)
    if a.phase == "session":
        return phase_session(a.session_dir or ".")
    if not est_root():
        log("la partie système demande root : lance « nomade-diag » (il demande le mot de passe)")
        return 1

    session = None
    if a.session_dir and os.path.exists(os.path.join(a.session_dir, "session.json")):
        with open(os.path.join(a.session_dir, "session.json"), encoding="utf-8") as f:
            session = json.load(f)
        shutil.rmtree(a.session_dir, ignore_errors=True)
    attendu = valeurs_env("/etc/nomade/expected.env")
    util = os.environ.get("SUDO_USER") or attendu.get("TARGET_USER")
    sel = lire_ou_creer_sel(SEL)
    anon = Anonymiseur(sel, actif=not a.brut, utilisateur=util, machine=os.uname().nodename)
    for f in ("/etc/machine-id", "/proc/sys/kernel/random/boot_id"):
        anon.secret("systeme", lire(f))
    ctx = {"anon": anon, "brut": {}, "test": a.test,
           "noyau": sortie(["journalctl", "-k", "-b", "-o", "short-monotonic", "--no-pager"], 60)}
    res = {"schema": SCHEMA, "type": "systeme",
           "outil": {"nom": "nomade-diag", "version": valeurs_env("/etc/nomade/build-info").get("NOMADE_VERSION") or "?"},
           "date": maintenant(), "anonymise": not a.brut,
           "options": {"mesures": a.mesures, "ecriture_max_mib": a.ecriture_max if a.mesures else None,
                       "test": a.test},
           "non_lu": {}}
    sections = [("systeme", lambda: s_versions(ctx)), ("pc", lambda: s_pc(ctx)),
                ("secure_boot", lambda: s_secure_boot(ctx)), ("affichage", lambda: s_affichage(ctx, session)),
                ("peripheriques", lambda: s_peripheriques(ctx, session)), ("cle", lambda: s_cle(ctx)),
                ("demarrage", lambda: s_demarrage(ctx)), ("memoire", lambda: s_memoire(ctx)),
                ("ecritures", lambda: s_ecritures(ctx)), ("erreurs", lambda: s_erreurs(ctx))]
    for nom, f in sections:
        log("relevé : " + nom)
        try:
            res[nom] = f()
        except Exception as e:                      # une section en échec n'arrête pas le diagnostic
            res[nom] = None
            res["non_lu"][nom] = "%s: %s" % (type(e).__name__, e)
            ctx["brut"]["erreurs-internes/%s.txt" % nom] = traceback.format_exc()
    if res.get("systeme") is not None:
        try:
            res["systeme"]["autotest"] = s_autotest(ctx)
        except Exception as e:
            res["non_lu"]["autotest"] = str(e)
    res["mesures"] = None
    if a.mesures:
        try:
            res["mesures"] = mesures(ctx, a.ecriture_max)
        except Exception as e:
            res["non_lu"]["mesures"] = "%s: %s" % (type(e).__name__, e)
    res["alertes"] = alertes(res)
    rapport = texte_rapport(res)

    fichiers = {"resume.json": archive.json_texte(res), "rapport.txt": rapport,
                "journal/noyau.txt": "\n".join(ctx["noyau"].splitlines()[-5000:])}
    fichiers.update(ctx["brut"])
    fichiers = {k: anon.nettoyer(v, motifs=k != "resume.json") for k, v in fichiers.items()}
    probleme = []
    for nom, texte in fichiers.items():
        probleme += anon.trouvailles(nom, texte, motifs=nom != "resume.json")
    if probleme:
        for x in probleme[:20]:
            log("ANONYMISATION : " + x)
        log("archive non écrite : identifiant résiduel (voir ci-dessus)")
        return 3
    dest = destination(a.sortie)
    uid = gid = None
    if util and not dest.startswith("/run"):
        try:
            import pwd
            pw = pwd.getpwnam(util)
            uid, gid = pw.pw_uid, pw.pw_gid
        except KeyError:
            pass
    modele = reduire((res.get("pc") or {}).get("modele") or "pc-inconnu")
    nom = "nomade-diag-%s-%s%s" % (horodatage(), modele, "-brut" if a.brut else "")
    chemin = archive.ecrire(dest, nom, fichiers, uid, gid)
    sys.stdout.write(rapport)
    sys.stdout.write("\nArchive : %s\n" % chemin)
    return 0
