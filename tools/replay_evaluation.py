#!/usr/bin/env python3
"""Replay an immutable human evaluation or archived blind side via the core CLI."""
import argparse
import json
import pathlib
import subprocess
import tempfile


def main():
    p = argparse.ArgumentParser()
    p.add_argument("session")
    choice = p.add_mutually_exclusive_group(required=True)
    choice.add_argument("--record", type=int, help="1-based human record index")
    choice.add_argument("--comparison", type=int, help="1-based archived comparison index")
    p.add_argument("--side", choices=["A", "B"], default="B")
    p.add_argument("--binary", default="zig-out/bin/mimoc-voice")
    p.add_argument("-o", "--output", default="replayed.wav")
    args = p.parse_args()
    session = json.loads(pathlib.Path(args.session).read_text())
    if args.record is not None:
        if not 1 <= args.record <= len(session.get("evaluations", [])):
            p.error("record index out of range")
        r = session["evaluations"][args.record - 1]
        targets, voice, envelope = r["parameter_snapshot"], r["voice"], r["envelope"]
        selected, scope = r.get("selected", 0), r.get("scope", "whole")
    else:
        if not 1 <= args.comparison <= len(session.get("comparisons", [])):
            p.error("comparison index out of range")
        r = session["comparisons"][args.comparison - 1]
        side = args.side.lower()
        targets, voice, envelope = r["targets_" + side], r["voice_" + side], r["envelope_" + side]
        selected, scope = r["selected"], r["scope"]
    if scope != "whole":
        if not 0 <= selected < len(targets):
            p.error("invalid archived selection")
        start = max(0, selected - 1) if scope in ("previous_selected", "context") else selected
        end = min(len(targets), selected + 2) if scope in ("selected_next", "context") else selected + 1
        targets = targets[start:end]
    document = dict(synth=dict(sample_rate=16000, voice=voice, envelope_mode=envelope), targets=targets)
    with tempfile.TemporaryDirectory(prefix="mimoc-replay-") as directory:
        path = pathlib.Path(directory) / "targets.json"
        path.write_text(json.dumps(document))
        subprocess.run([args.binary, "render-targets", str(path), "-o", args.output], check=True)
    print(f"Replayed immutable parameters to {args.output}; no frontend re-planning.")


if __name__ == "__main__":
    main()
