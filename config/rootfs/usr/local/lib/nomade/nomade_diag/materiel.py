"""Ce que la clé et le système disent d'elle, sans rien mesurer (sysfs, udev, hwdb, SMART).

Parcours repris de Fabrique-Clé (app/src/disques/linux.rs, ``identifier``) : de /sys/block/<disque>
jusqu'à l'interface USB (pilote), puis au périphérique USB (VID:PID, norme, vitesse négociée).
Les numéros de série relevés sont rangés dans ``_secrets`` (anonymisation), jamais ailleurs.
"""

import glob
import json
import os

from .commun import PARTAGE, commande, entier, lire, sortie

ROLES = {"marque", "controleur", "pont", "suspect", "ssd"}


def charger_table(chemin=None):
    """Table fabricants-usb.txt : liste de {vid, pid (ou None), role, nom}."""
    chemin = chemin or os.path.join(PARTAGE, "fabricants-usb.txt")
    table = []
    for ligne in lire(chemin).splitlines():
        ligne = ligne.strip()
        if not ligne or ligne.startswith("#"):
            continue
        morceaux = ligne.split(None, 2)
        if len(morceaux) != 3 or morceaux[1] not in ROLES:
            raise ValueError("ligne mal formée dans %s : %s" % (chemin, ligne))
        ident, role, nom = morceaux
        vid, _, pid = ident.partition(":")
        table.append({"vid": int(vid, 16), "pid": int(pid, 16) if pid else None, "role": role,
                      "nom": nom.strip()})
    return table


def identification(table, vid, pid):
    """Entrée la plus précise : le modèle (VID:PID), sinon le fabricant (VID)."""
    if vid is None:
        return None
    for e in table:
        if e["vid"] == vid and e["pid"] is not None and e["pid"] == pid:
            return {"role": e["role"], "nom": e["nom"], "precision": "modele"}
    for e in table:
        if e["vid"] == vid and e["pid"] is None:
            return {"role": e["role"], "nom": e["nom"], "precision": "fabricant"}
    return None


def noms_hwdb(vid, pid):
    """Noms de la base usb.ids (hwdb de systemd) : (fabricant, produit)."""
    if vid is None:
        return None, None
    d = {}
    for ligne in sortie(["systemd-hwdb", "query", "usb:v%04Xp%04X" % (vid, pid or 0)]).splitlines():
        k, _, v = ligne.partition("=")
        d[k] = v
    return d.get("ID_VENDOR_FROM_DATABASE"), d.get("ID_MODEL_FROM_DATABASE")


def proprietes_udev(dev):
    d = {}
    for ligne in sortie(["udevadm", "info", "--query=property", "--name=" + dev]).splitlines():
        k, _, v = ligne.partition("=")
        d[k] = v
    return d


def bridee_usb2(version, vitesse):
    try:
        majeure = int(str(version).split(".")[0])
    except (TypeError, ValueError):
        return None
    if vitesse is None:
        return None
    return majeure >= 3 and vitesse <= 480


def identifier(dev, table=None):
    """Identification d'un disque (/dev/sdX, /dev/loopN). Tous les champs peuvent valoir None."""
    table = table if table is not None else charger_table()
    nom = os.path.basename(os.path.realpath(dev))
    base = "/sys/block/" + nom
    q = lambda f: lire(os.path.join(base, "queue", f))
    secteurs = entier(lire(os.path.join(base, "size")))
    m = {
        "disque": nom,
        "capacite_octets": secteurs * 512 if secteurs is not None else None,
        "secteur_logique": entier(q("logical_block_size")),
        "secteur_physique": entier(q("physical_block_size")),
        "transfert_max_kio": entier(q("max_hw_sectors_kb")),
        "discard_max_octets": entier(q("discard_max_bytes")),
        "rotatif_declare": None,
        "ordonnanceur": None,
        "file_commandes": entier(lire(os.path.join(base, "device", "queue_depth"))),
        "provisioning_mode": None,
        "vid": None, "pid": None, "fabricant_usb": None, "produit_usb": None,
        "version_usb": None, "vitesse_mbps": None, "pilote": None, "concentrateur": None,
        "chemin_usb": None,
        "_secrets": [],
    }
    rot = q("rotational")
    m["rotatif_declare"] = (rot == "1") if rot in ("0", "1") else None
    for mot in q("scheduler").split():
        if mot.startswith("[") and mot.endswith("]"):
            m["ordonnanceur"] = mot[1:-1]
    pm = glob.glob(os.path.join(base, "device", "scsi_disk", "*", "provisioning_mode"))
    if pm:
        m["provisioning_mode"] = lire(pm[0]) or None

    # Remonter : …/usb2/2-1/2-1:1.0/host3/target3:0:0/3:0:0:0/block/sdb
    reel = os.path.realpath(base)
    d = reel
    while d not in ("/", ""):
        if m["pilote"] is None and os.path.exists(os.path.join(d, "bInterfaceClass")):
            pil = os.path.join(d, "driver")
            if os.path.islink(pil):
                m["pilote"] = os.path.basename(os.path.realpath(pil))
        if os.path.exists(os.path.join(d, "idVendor")):
            m["vid"] = entier(lire(os.path.join(d, "idVendor")), 16)
            m["pid"] = entier(lire(os.path.join(d, "idProduct")), 16)
            m["fabricant_usb"] = lire(os.path.join(d, "manufacturer")) or None
            m["produit_usb"] = lire(os.path.join(d, "product")) or None
            m["version_usb"] = lire(os.path.join(d, "version")) or None
            v = lire(os.path.join(d, "speed"))
            try:
                m["vitesse_mbps"] = int(float(v))
            except ValueError:
                pass
            serie = lire(os.path.join(d, "serial"))
            if serie:
                m["_secrets"].append(("cle", serie))
            # « 2-1.3 » : un point = un concentrateur entre le port et la clé
            m["chemin_usb"] = os.path.basename(d)
            m["concentrateur"] = "." in os.path.basename(d)
            break
        d = os.path.dirname(d)

    u = proprietes_udev("/dev/" + nom)
    for k in ("ID_SERIAL", "ID_SERIAL_SHORT", "ID_WWN", "ID_WWN_WITH_EXTENSION", "ID_SCSI_SERIAL",
              "ID_USB_SERIAL", "ID_USB_SERIAL_SHORT"):
        if u.get(k):
            m["_secrets"].append(("cle", u[k]))
    m["modele_declare"] = u.get("ID_MODEL") or None
    m["vendeur_declare"] = u.get("ID_VENDOR") or None
    # Liens /dev/disk/by-id : ils contiennent le numéro de série
    for lien in glob.glob("/dev/disk/by-id/*"):
        if os.path.realpath(lien) == "/dev/" + nom:
            m["_secrets"].append(("lien", os.path.basename(lien)))
    m["identification"] = identification(table, m["vid"], m["pid"])
    m["hwdb_fabricant"], m["hwdb_produit"] = noms_hwdb(m["vid"], m["pid"])
    m["bridee_usb2"] = bridee_usb2(m["version_usb"], m["vitesse_mbps"])
    quirks = lire("/sys/module/usb_storage/parameters/quirks")
    m["quirk_usb_storage"] = None
    if m["vid"] is not None and quirks:
        cle = "%04x:%04x:" % (m["vid"], m["pid"] or 0)
        for q_ in quirks.split(","):
            if q_.lower().startswith(cle):
                m["quirk_usb_storage"] = q_.split(":", 2)[2]
    return m


def empreinte_cle(anon, dev, ident=None):
    """Empreinte d'une clé (D-049) : numéro de série USB, sinon celui du disque, sinon WWN ; à défaut
    (fichier de test), capacité et nom du disque. Même calcul dans diag-cle, deploy.sh et nomade-diag :
    avec le même sel (celui de l'hôte, copié sur la clé), la même clé donne la même empreinte."""
    u = proprietes_udev(dev)
    serie = u.get("ID_USB_SERIAL_SHORT") or u.get("ID_SERIAL_SHORT") or u.get("ID_SERIAL") or u.get("ID_WWN")
    if serie:
        return anon.empreinte("cle", serie)
    nom = os.path.basename(os.path.realpath(dev))
    secteurs = entier(lire("/sys/block/%s/size" % nom))
    return anon.empreinte("cle", "sans-serie:%s:%s" % (secteurs * 512 if secteurs else None, nom))


def partitions(dev):
    """Partitions actuelles : taille, type de système de fichiers, et noms GPT de zorin-nomade
    seulement (les autres étiquettes peuvent être personnelles)."""
    out = sortie(["lsblk", "-J", "-b", "-o", "NAME,SIZE,TYPE,FSTYPE,PARTLABEL", dev])
    try:
        enfants = json.loads(out)["blockdevices"][0].get("children", [])
    except (ValueError, KeyError, IndexError):
        return {"nombre": None, "liste": [], "nomade": False}
    liste = []
    nomade = False
    for e in enfants:
        etiquette = e.get("partlabel")
        connue = etiquette in ("nomade-root", "NOMADE-DATA", "nomade-boot", "EFI System Partition")
        nomade = nomade or etiquette in ("nomade-root", "NOMADE-DATA")
        liste.append({"taille_gio": round(int(e.get("size") or 0) / 2 ** 30, 1),
                      "fs": e.get("fstype"), "nom": etiquette if connue else None})
    return {"nombre": len(liste), "liste": liste, "nomade": nomade}


def types_smart(ident):
    """Types smartctl à essayer, du plus probable au moins probable, d'après le pont."""
    vid = ident.get("vid")
    nom = ((ident.get("identification") or {}).get("nom") or "").lower()
    essais = []
    if "nvme" in nom:
        essais += {0x152D: ["sntjmicron"], 0x174C: ["sntasmedia"], 0x0BDA: ["sntrealtek"]}.get(vid, [])
    essais += ["sat", "auto"]
    return essais


def smart(dev, ident):
    """SMART par smartctl (si installé) ; None si absent ou non relayé par le pont. Renvoie
    (résumé, json brut)."""
    for t in types_smart(ident):
        code, out, _ = commande(["smartctl", "-j", "-a", "-d", t, dev], delai=30)
        if code is None:
            return None, None
        try:
            j = json.loads(out)
        except ValueError:
            continue
        # Bits 0 et 1 du code : erreur de ligne de commande ou ouverture impossible
        if code & 0x3 or not (j.get("smart_status") or j.get("nvme_smart_health_information_log")
                              or j.get("ata_smart_attributes")):
            continue
        return resumer_smart(j, t), j
    return None, None


def resumer_smart(j, type_):
    r = {"type": type_, "modele": j.get("model_name"), "sain": (j.get("smart_status") or {}).get("passed"),
         "heures": (j.get("power_on_time") or {}).get("hours"), "ecrit_gio": None, "usure_pct": None,
         "reserve_pct": None, "temperature_c": (j.get("temperature") or {}).get("current")}
    nv = j.get("nvme_smart_health_information_log")
    if nv:
        if nv.get("data_units_written") is not None:
            r["ecrit_gio"] = round(nv["data_units_written"] * 512000 / 2 ** 30, 1)
        r["usure_pct"] = nv.get("percentage_used")
        r["reserve_pct"] = nv.get("available_spare")
    for a in (j.get("ata_smart_attributes") or {}).get("table", []):
        nom = (a.get("name") or "").lower()
        brut = (a.get("raw") or {}).get("value")
        if a.get("id") == 241 and "lba" in nom and brut is not None:
            r["ecrit_gio"] = round(brut * 512 / 2 ** 30, 1)
        if a.get("id") in (231, 233, 177, 202) and ("life" in nom or "wear" in nom):
            v = a.get("value")
            if v is not None and r["usure_pct"] is None:
                r["usure_pct"] = max(0, 100 - v)
    return r


def secrets_smart(j):
    if not j:
        return []
    s = [("cle", j.get("serial_number"))]
    w = j.get("wwn") or {}
    if w:
        s.append(("cle", "%x %06x %09x" % (w.get("naa", 0), w.get("oui", 0), w.get("id", 0))))
    s.append(("cle", j.get("logical_unit_id")))
    return [x for x in s if x[1]]
