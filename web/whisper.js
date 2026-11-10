// Speech to text on the phone itself, with Whisper (tiny, English) running in WebAssembly.
// The model (about 40 MB) downloads the first time and is cached for good after that.
import { pipeline, env } from "https://cdn.jsdelivr.net/npm/@huggingface/transformers@3.5.1";

env.allowLocalModels = false;
env.backends.onnx.wasm.numThreads = 1;   // iPhone home-screen apps can't use shared-memory threads

let asr = null;
function load() {
  if (!asr) {
    asr = pipeline("automatic-speech-recognition", "Xenova/whisper-tiny.en", {
      dtype: "q8", device: "wasm",
      progress_callback: (p) => { if (p.status === "progress" && p.total) postMessage({ type: "progress", file: p.file, loaded: p.loaded, total: p.total }); },
    }).then((a) => { postMessage({ type: "ready" }); return a; }, (e) => { asr = null; throw e; });
  }
  return asr;
}

onmessage = async (e) => {
  const m = e.data;
  try {
    if (m.type === "load") { await load(); return; }
    if (m.type === "transcribe") {
      const a = await load();
      const out = await a(m.audio);
      postMessage({ type: "text", id: m.id, text: (out.text || "").replace(/\[[^\]]*\]|\([^)]*\)/g, " ").replace(/\s+/g, " ").trim() });
    }
  } catch (err) {
    postMessage({ type: "error", id: m.id, message: String((err && err.message) || err) });
  }
};
