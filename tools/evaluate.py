#!/usr/bin/env python3
"""Generate listening corpus and validate PCM/WAV properties, never intelligibility."""
import argparse, json, pathlib, struct, subprocess, wave
CASES = {
 "ja": ["アイウエオ", "コンニチワ", "オハヨウ", "モーバス", "メッセージ", "セツゾク", "バッテリー", "エラー"],
 "en": ["hello", "hello world", "system ready", "message received", "battery low", "network connected", "device disconnected", "warning", "system error"],
}
def inspect(path):
 with wave.open(str(path), "rb") as f:
  assert (f.getnchannels(), f.getsampwidth(), f.getframerate()) == (1, 2, 16000)
  count = f.getnframes()
  data = f.readframes(count)
  assert len(data) == count * 2
 samples = struct.unpack("<" + str(count) + "h", data)
 assert count > 0
 peak = max(abs(s) for s in samples)
 dc = sum(samples) / count
 jump = max(abs(b - a) for a, b in zip(samples, samples[1:]))
 assert peak < 30000, (path, peak)
 assert abs(dc) < 200, (path, dc)
 assert jump < 30000, (path, jump)
 return dict(frames=count, seconds=count/16000, peak=peak, dc=round(dc, 2), max_adjacent_delta=jump)
def main():
 parser=argparse.ArgumentParser()
 parser.add_argument("--binary", default="zig-out/bin/mimoc-voice")
 parser.add_argument("--output", default="zig-out/evaluation")
 args=parser.parse_args()
 out=pathlib.Path(args.output); out.mkdir(parents=True, exist_ok=True)
 report=[]
 for lang, phrases in CASES.items():
  for index, text in enumerate(phrases):
   path=out/f"{lang}-{index+1:02d}.wav"
   subprocess.run([args.binary,"synth","--lang",lang,text,"-o",str(path)],check=True,capture_output=True)
   report.append(dict(language=lang,text=text,file=path.name,**inspect(path)))
 for vowel in "aiueo":
  path=out/f"vowel-{vowel}.wav"
  subprocess.run([args.binary,"synth-phoneme",vowel,"-o",str(path)],check=True,capture_output=True)
  report.append(dict(language="phoneme",text=vowel,file=path.name,**inspect(path)))
 (out/"report.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n")
 print(f"Validated {len(report)} WAV files in {out}; human listening review remains separate.")
if __name__ == "__main__": main()
