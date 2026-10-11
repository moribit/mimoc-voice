#!/usr/bin/env python3
"""Fixed diagnostic corpus + one-factor contrasts. Metrics detect faults, never quality."""
import argparse
import cmath
import hashlib
import json
import math
import pathlib
import struct
import subprocess
import wave

EN_VOWELS = ["heed", "hid", "head", "had", "hod", "hood", "who'd"]
EN_CV = ["ha", "he", "ho", "la", "lee", "low", "ra", "ree", "row"]
EN_WORDS = ["hello", "ready", "world", "battery", "message", "system", "warning", "error"]
JA_VOWELS = [("a", "ア"), ("i", "イ"), ("u", "ウ"), ("e", "エ"), ("o", "オ")]
JA_CV = list(zip("ka ki ku ke ko sa shi su se so ta chi tsu te to".split(), "カキクケコサシスセソタチツテト"))
JA_PHRASES = [("konnichiwa", "コンニチワ"), ("ohayou", "オハヨウ"), ("mobus", "モーバス"), ("message", "メッセージ")]


def fft(values):
    """Small radix-2 FFT, no external numerical package."""
    n = len(values)
    data = list(map(complex, values))
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j ^= bit
        if i < j:
            data[i], data[j] = data[j], data[i]
    size = 2
    while size <= n:
        step = cmath.exp(-2j * math.pi / size)
        for start in range(0, n, size):
            factor = 1 + 0j
            for k in range(size // 2):
                even = data[start + k]
                odd = factor * data[start + k + size // 2]
                data[start + k], data[start + k + size // 2] = even + odd, even - odd
                factor *= step
        size *= 2
    return data


def metrics(samples, rate):
    count = len(samples)
    if not count:
        return dict(frames=0, rms=0, peak=0, dc=0, adjacent_delta=0, zero_crossing_rate=0, spectral_centroid_hz=0)
    rms = math.sqrt(sum(s * s for s in samples) / count)
    # Up to five Hann-windowed 512-point spectra, an anomaly aid, not a quality score.
    spectra = [0.0] * 257
    n = 512
    for fraction in [0, 0.25, 0.5, 0.75, 1]:
        start = int(max(0, count - n) * fraction)
        data = samples[start:start + n]
        padded = list(data) + [0] * (n - len(data))
        bins = fft([v * (0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1))) for i, v in enumerate(padded)])
        for k in range(1, 257):
            spectra[k] += abs(bins[k]) ** 2
    total = sum(spectra)
    centroid = sum(k * rate / n * p for k, p in enumerate(spectra)) / total if total else 0
    return dict(frames=count, duration_s=count / rate, rms=round(rms, 3), peak=max(abs(s) for s in samples),
                dc=round(sum(samples) / count, 3), adjacent_delta=max([0] + [abs(b - a) for a, b in zip(samples, samples[1:])]),
                zero_crossing_rate=round(sum((a >= 0) != (b >= 0) for a, b in zip(samples, samples[1:])) / max(count - 1, 1), 5),
                spectral_centroid_hz=round(centroid, 2))


def inspect(path, metadata=None):
    with wave.open(str(path), "rb") as f:
        assert (f.getnchannels(), f.getsampwidth(), f.getframerate()) == (1, 2, 16000), path
        count = f.getnframes()
        data = f.readframes(count)
        assert len(data) == count * 2, path
    samples = struct.unpack("<" + str(count) + "h", data)
    assert count, path
    result = metrics(samples, 16000)
    faults = []
    if result["peak"] >= 30000:
        faults.append("clipping_or_headroom_loss")
    if abs(result["dc"]) >= 200:
        faults.append("excessive_dc")
    if result["adjacent_delta"] >= 30000:
        faults.append("large_discontinuity")
    result["per_phoneme"] = []
    if metadata:
        assert math.isfinite(metadata["internal_peak"]), (path, "nonfinite internal peak")
        cursor = 0
        speed = metadata["synth"]["voice"]["speed"]
        voiced_frames = 0
        for index, target in enumerate(metadata["targets"]):
            frames = max(1, int(16000 * target["duration_ms"] / (1000 * speed)))
            segment = metrics(samples[cursor:cursor + frames], 16000)
            assert segment["frames"] == frames, (path, "invalid target boundary")
            segment.update(index=index + metadata["range"]["start"], phoneme=target["phoneme"], start_frame=cursor,
                           planned_voicing=target["voicing"], stress=target["stress"])
            intentional_silence = target["phoneme"] == "silence" or target["gain"] == 0 or max(target["amplitude_start"], target["amplitude_end"]) == 0
            if not intentional_silence and segment["rms"] < 5:
                faults.append(f"silent_phoneme:{segment['index']}:{target['phoneme']}")
            if target["voicing"] >= 0.5:
                voiced_frames += frames
            result["per_phoneme"].append(segment)
            cursor += frames
        assert cursor == count, (path, "unexpected duration")
        result["planned_voiced_ratio"] = round(voiced_frames / count, 4)
    result["faults"] = faults
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default="zig-out/bin/mimoc-voice")
    parser.add_argument("--output", default="zig-out/evaluation")
    parser.add_argument("--preset", default="Default", choices=["Default", "Robot", "Deep", "Bright", "Retro"])
    parser.add_argument("--against", help="Previous report.json; RMS/noise changes are anomaly flags only")
    args = parser.parse_args()
    out = pathlib.Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    rows = []
    comparisons = []
    preset = args.preset.lower()

    def generate(folder, name, command, text, lang="en", extra=(), reference=None):
        path = out / folder / f"{name}_{preset}.wav"
        path.parent.mkdir(parents=True, exist_ok=True)
        sidecar = path.with_suffix(".json")
        argv = [args.binary, command, "--lang", lang, text, "--preset", args.preset, "-o", str(path), *extra]
        if reference:
            argv.extend(["--reference", reference])
            meta = None
        else:
            argv.extend(["--targets", str(sidecar)])
        subprocess.run(argv, check=True, capture_output=True)
        if not reference:
            meta = json.loads(sidecar.read_text())
        row = dict(file=str(path.relative_to(out)), input=text, language=lang, preset=args.preset, reference=reference or "current",
                   command=argv[1:], sha256=hashlib.sha256(path.read_bytes()).hexdigest(), **inspect(path, meta))
        rows.append(row)
        return row

    for word in EN_VOWELS:
        generate("english/vowels", f"en_vowel_{word.replace(chr(39), '')}", "synth", word)
    for p in ["h", "l", "r", "w", "y", "k", "t", "p", "s", "sh", "f"]:
        generate("english/cv", f"en_isolated_{p}", "synth-sequence", p)
    for word in EN_CV:
        generate("english/cv", f"en_cv_{word}", "synth", word)
    for word in EN_WORDS:
        generate("english/words", f"en_word_{word}", "synth", word)
    for index, p in enumerate(["h", "schwa", "l", "ow"]):
        generate("english/cv", f"en_hello_selected_{p}", "synth", "hello", extra=["--scope", "selected", "--selected", str(index)])
    for index, name in enumerate(["h_schwa", "schwa_l", "l_ow"]):
        generate("english/cv", f"en_pair_{name}", "synth", "hello", extra=["--scope", "selected_next", "--selected", str(index)])
    for name, text in JA_VOWELS:
        generate("japanese/vowels", f"ja_vowel_{name}", "synth", text, "ja")
    for name, text in JA_CV:
        generate("japanese/cv", f"ja_cv_{name}", "synth", text, "ja")
    for name, text in JA_PHRASES:
        generate("japanese/phrases", f"ja_phrase_{name}", "synth", text, "ja")

    def contrast(folder, name, command, text, flag, values, hypothesis, lang="en", references=False):
        a = generate("experiments/" + folder, name + "_A_" + values[0], command, text, lang,
                     reference=values[0] if references else None, extra=[] if references else [flag, values[0]])
        b = generate("experiments/" + folder, name + "_B_" + values[1], command, text, lang,
                     reference=values[1] if references else None, extra=[] if references else [flag, values[1]])
        comparisons.append(dict(hypothesis=hypothesis, changed_factor=flag, baseline=a["file"], candidate=b["file"],
                                human_decision="pending", baseline_sha256=a["sha256"], candidate_sha256=b["sha256"]))

    for name, command, text, lang in [("h", "synth-phoneme", "h", "en"), ("l", "synth-phoneme", "l", "en"),
                                       ("hello", "synth", "hello", "en"), ("konnichiwa", "synth", "コンニチワ", "ja")]:
        contrast("01-envelope-frozen", name, command, text, "pre_output_envelope", ["phase5", "envelope_single"],
                 "H01: double envelope attenuates short acoustic cues", lang, True)
        contrast("02-envelope-current", name, command, text, "--envelope", ["legacy_double", "single"], "H01 replicated on identical Phase 6 targets", lang)
    for p in ["ey", "ay", "oy", "ow", "aw"]:
        contrast("03-diphthong", p, "synth-phoneme", p, "--glide", ["off", "on"], "H02: formant motion carries diphthong identity")
    contrast("04-duration", "hello", "synth", "hello", "--timing", ["fixed", "context"], "H03: reduction and stress timing preserve syllable cues")
    for p in ["l", "r", "w", "y"]:
        contrast("05-transition", f"eh_{p}_ow", "synth-sequence", f"eh {p} ow", "--transitions", ["fixed", "context"], "H04: neighbor-conditioned formant paths carry approximant identity")
    for p in ["s", "sh", "f", "h", "k", "t", "p"]:
        contrast("06-noise", p, "synth-phoneme", p, "--noise", ["legacy", "shaped"], "H05: noise spectra separate fricatives and bursts")
    for p in ["iy", "eh", "aa", "ah", "ao", "uh", "uw"]:
        contrast("07-vowel-table", p, "synth-sequence", p, "--vowels", ["japanese_approx", "english"], "H06: independent English vowel targets avoid collapsed contrasts")
    contrast("08-stress", "hello", "synth", "hello", "--stress", ["off", "on"], "H07: pitch/amplitude emphasis carries stressed syllable cues")

    baseline_path = pathlib.Path(__file__).resolve().parents[1] / "docs/envelope-baseline.json"
    if args.preset == "Default" and baseline_path.exists():
        hashes = {r["name"]: r["sha256"] for r in json.loads(baseline_path.read_text())}
        for row in rows:
            if row["reference"] == "phase5":
                name = pathlib.Path(row["file"]).name.split("_A_")[0]
                assert row["sha256"] == hashes[name], (name, "Phase 5 reference drift")

    regressions = []
    if args.against:
        previous = {r["file"]: r for r in json.loads(pathlib.Path(args.against).read_text())["artifacts"]}
        for row in rows:
            old = previous.get(row["file"])
            if not old:
                continue
            if old["rms"] > 20 and row["rms"] < old["rms"] * 0.25:
                regressions.append(dict(file=row["file"], flag="RMS_collapse"))
            if row["zero_crossing_rate"] > old["zero_crossing_rate"] + 0.2:
                regressions.append(dict(file=row["file"], flag="possible_excess_noise"))
            old_segments = {(r["index"], r["phoneme"]): r for r in old["per_phoneme"]}
            for segment in row["per_phoneme"]:
                prior = old_segments.get((segment["index"], segment["phoneme"]))
                if prior and prior["rms"] > 20 and segment["rms"] < prior["rms"] * 0.25:
                    regressions.append(dict(file=row["file"], phoneme=segment["phoneme"], flag="phoneme_RMS_collapse"))
    faults = [{"file": r["file"], "faults": r["faults"]} for r in rows if r["faults"]]
    report = dict(schema=2, quality_judgement="human_only", artifacts=rows, comparisons=comparisons, faults=faults, regressions=regressions)
    (out / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    markdown = "# Diagnostic evaluation\n\nQuality decisions: **pending human listening**. Metrics detect faults only.\n\n"
    markdown += f"WAV files: {len(rows)}; one-factor contrasts: {len(comparisons)}; integrity faults: {len(faults)}; regression flags: {len(regressions)}.\n\n"
    markdown += "| Hypothesis | Baseline | Candidate | Human decision |\n|---|---|---|---|\n"
    for c in comparisons:
        markdown += f"| {c['hypothesis']} | [{c['baseline']}]({c['baseline']}) | [{c['candidate']}]({c['candidate']}) | pending |\n"
    (out / "report.md").write_text(markdown)
    print(f"Generated {len(rows)} WAVs / {len(comparisons)} one-factor contrasts; faults={len(faults)}, regression flags={len(regressions)}.")
    if faults:
        raise SystemExit("Signal-integrity faults found; see report.json (no quality judgement).")


if __name__ == "__main__":
    main()
