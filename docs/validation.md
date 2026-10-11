# Phase 1–5 validation

2026-10-11 / Zig 0.17.0 / macOS / Apple M2。

## Verified

- `zig build test`: DSP、frontend、Synth、WAV header、Studio modelの20テスト。
- `zig build test-studio`: native UIの3操作テスト。
  入力、language切替、pointerでのPlay/Stop、6フレーズのCoreAudio再生完了、WAV export、
  音素選択、Inspector編集、timelineページ移動、sliderの編集前A保持、JSON保存・復元・invalid session拒否を確認。
- `zig build check-embedded`: RV32 freestandingでSynthをcompile。
  ESP32-S3/I2S上での動作を確認したものではありません。
- `zig build check-studio`: 既存mimoc-uiのmacOS window/font backendでcompile。
- native rendererの1000×720 snapshotを目視で確認。見切れ・項目の重なりなし。
- CLIで`hello world`をCoreAudioへstream再生し正常終了。
- `tools/evaluate.py`が17フレーズと5母音、計22 WAVを生成・検査。

22 WAVの信号検査結果:

| Metric | Result |
|---|---:|
| Maximum absolute PCM peak | 10,202 / 32,768 |
| Maximum absolute DC mean | 10.89 PCM units |
| Maximum adjacent sample delta | 6,690 PCM units |
| Format | RIFF / PCM / i16 little-endian / mono / 16kHz |

技術的な閾値の検査であり、発音・音素識別・言葉の聞き取りやすさの評価ではありません。
Synth内のピークがfiniteであることを確認し、integer出力はsoft limiterとDC blockerで境界内に収めます。
イベント開始・終端のenvelopeと25msのformant補間を使用します。

## Benchmark

`zig build bench -Doptimize=fast`で、子音・母音・鼻音・休止を含む日本語イベント列を10秒に切り詰めてstream生成。
frontend処理、device再生、WAV I/Oは測定区間に含めません。

| Metric | Representative run |
|---|---:|
| Sample rate | 16,000 Hz |
| PCM frames | 160,000 (10s) |
| Render wall time | 7.349 ms |
| PCM throughput | 21,771,670 frames/s |
| Synth peak heap allocation | 0 bytes |
| Synth state | 200 bytes |
| PCM chunk | 1,024 bytes (512 frames) |

処理時間は参考値で、実行ごとに変動します。CPU負荷・clock resolution・optimize modeの影響を受けます。
heap 0はSynthにallocatorが存在しない設計に基づくSynth単体の値です。
caller-ownedイベントmemory、プロセス起動、UI、audio device、JSONに使うmemoryは別です。
ESP32性能の予測やESP32での測定値としては扱えません。

## Human listening review — pending

Codexが人間の聴覚評価を実施したとは扱いません。
以下のコーパスをStudioまたは`zig-out/evaluation`のWAVで人が試聴し、音色を調整してください。

| Japanese | English |
|---|---|
| アイウエオ | hello |
| コンニチワ | hello world |
| オハヨウ | system ready |
| モーバス | message received |
| メッセージ | battery low |
| セツゾク | network connected |
| バッテリー | device disconnected |
| エラー | warning |
| — | system error |

試聴手順:

1. まず5母音を個別に聴き、聞き分けられるか記録する。
2. 文字を見ない状態で各フレーズを聴き、聞こえた言葉と不明瞭な音素を記録する。
3. Studioで問題の音素を選択し、F1/F2/F3、noise、duration、transition相手の音色を調整する。
4. Play A/Bで同じ発話の編集前後を比べる。必要ならStore phoneme profileを使う。
5. Save sessionで調整結果を保存し、WAV exportで比較用音声を残す。

初期defaultはsimple glottalです。sawtooth/pulseはRobot/Retro preset、または保存したJSONのwaveformで比較可能です。
自然なaccent、英語の精密な発音、録音音声に近い品質は現在の達成判定に含めません。
