#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Mecena ClipDB per DaVinci Resolve.

Dalla timeline corrente:
  1. raccoglie gli originali delle clip video (anche se in timeline si lavora con i proxy);
  2. aggiorna il database MecenaClipDB con mecena-clipdb (solo le clip nuove o cambiate);
  3. scrive la mappa timeline -> clip in MecenaClipDB/timelines/ e la rende attiva.

Con la mappa attiva, Mecena Stabilize su un adjustment clip stabilizza ogni frame con i dati giroscopio, accelerometro e
ottica della clip che si trova sotto. Su una clip normale il database basta anche senza mappa.

Installazione: copiare in
  ~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/
e avviare da Workspace > Scripts > Utility > Mecena ClipDB.

Variabili facoltative: MECENA_CLIPDB (cartella del database), MECENA_CLIPDB_BIN (percorso di mecena-clipdb).
"""
import json
import os
import re
import subprocess
import sys

BUNDLE_BIN = "/Library/OFX/Plugins/MecenaMotion.ofx.bundle/Contents/Resources/mecena-clipdb"
FORMAT = "mecena-clipdb-timeline"


def config_path():
    home = os.path.expanduser("~")
    if sys.platform == "darwin":
        return os.path.join(home, "Library/Application Support/Mecena/clipdb.json")
    return os.path.join(home, ".config/mecena/clipdb.json")


def read_config():
    try:
        with open(config_path()) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def write_config(cfg):
    os.makedirs(os.path.dirname(config_path()), exist_ok=True)
    with open(config_path(), "w") as f:
        json.dump(cfg, f, indent=2)


def get_resolve():
    # Resolve's script menu provides `resolve` (and Fusion's `app`) as globals
    if globals().get("resolve"):
        return globals()["resolve"]
    if globals().get("app"):
        return globals()["app"].GetResolve()
    try:
        import DaVinciResolveScript as dvr
        return dvr.scriptapp("Resolve")
    except ImportError:
        return None


def number(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def item_source_range(item, clip_fps, timeline_fps, duration):
    """Primo frame dell'originale e frame dell'originale per frame di timeline."""
    start = end = None
    if hasattr(item, "GetSourceStartFrame"):
        start = item.GetSourceStartFrame()
        end = item.GetSourceEndFrame() if hasattr(item, "GetSourceEndFrame") else None
    if start is None:
        start = item.GetLeftOffset() or 0
    start = number(start)
    rate = 0.0
    if end is not None and duration > 0:
        rate = (number(end) - start) / duration
    if rate <= 0:
        # Senza retime Resolve riproduce a velocità reale: 50p su 25p avanza di due frame dell'originale
        rate = clip_fps / timeline_fps if clip_fps > 0 and timeline_fps > 0 else 1.0
    return start, rate


def main():
    resolve = get_resolve()
    if not resolve:
        print("Resolve non raggiungibile: avviare lo script da Workspace > Scripts.")
        return 1
    project = resolve.GetProjectManager().GetCurrentProject()
    timeline = project and project.GetCurrentTimeline()
    if not timeline:
        print("Nessuna timeline aperta.")
        return 1

    cfg = read_config()
    db = os.environ.get("MECENA_CLIPDB") or (cfg.get("databases") or [None])[0] or os.path.expanduser("~/Movies/MecenaClipDB")
    tool = os.environ.get("MECENA_CLIPDB_BIN") or BUNDLE_BIN
    tl_fps = number(timeline.GetSetting("timelineFrameRate"), 25.0)
    tl_start = int(timeline.GetStartFrame())

    segments, adjustments, media = [], [], []
    for track in range(1, int(timeline.GetTrackCount("video")) + 1):
        for item in timeline.GetItemListInTrack("video", track) or []:
            start = int(item.GetStart())
            duration = int(item.GetDuration())
            mpi = item.GetMediaPoolItem()
            path = mpi.GetClipProperty("File Path") if mpi else ""
            kind = (mpi.GetClipProperty("Type") if mpi else "") or ""
            if not path:
                if "adjust" in (item.GetName() or "").lower() or "adjust" in kind.lower():
                    adjustments.append({"start": start, "end": start + duration, "track": track})
                continue
            clip_fps = number(mpi.GetClipProperty("FPS"), tl_fps)
            source_start, rate = item_source_range(item, clip_fps, tl_fps, duration)
            segments.append({"start": start, "end": start + duration, "track": track, "media": path,
                             "source_start": source_start, "source_rate": rate})
            if path not in media:
                media.append(path)

    online = [m for m in media if os.path.isfile(m)]
    if online and os.path.isfile(tool):
        print("Aggiorno %s con %d originali…" % (db, len(online)))
        subprocess.call([tool, "scan", db] + online)
    elif online:
        print("mecena-clipdb non trovato in %s: la mappa viene scritta, il database non si aggiorna." % tool)
    offline = len(media) - len(online)
    if offline:
        print("%d originali offline: servono già nel database (scansione delle schede all'ingest)." % offline)

    name = re.sub(r"[^\w.-]+", "_", "%s__%s" % (project.GetName(), timeline.GetName()))
    out_dir = os.path.join(db, "timelines")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, name + ".json")
    data = {"format": FORMAT, "version": 1, "timeline": timeline.GetName(), "fps": tl_fps, "start_frame": tl_start,
            "db": "", "adjustments": adjustments, "segments": segments}
    with open(out + ".tmp", "w") as f:
        json.dump(data, f, indent=1)
    os.replace(out + ".tmp", out)

    cfg = read_config()
    cfg["active_timeline"] = os.path.abspath(out)
    dbs = cfg.setdefault("databases", [])
    if os.path.abspath(db) not in dbs:
        dbs.append(os.path.abspath(db))
    write_config(cfg)
    print("Mappa attiva: %s · %d clip, %d adjustment clip" % (out, len(segments), len(adjustments)))
    if len(adjustments) > 1:
        print("Più adjustment clip: Stabilize li distingue dalla durata; con durate uguali usa il primo.")
    return 0


if __name__ == "__main__":
    main()
