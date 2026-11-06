// Unlocks the encrypted data.json.
//
// The build encrypts the data with AES-256-GCM using a key derived from your passphrase
// (PBKDF2-SHA256). Here that key is derived again in the browser after you type the
// passphrase, or recovered with Face ID: a passkey's PRF output wraps the key, and only
// the wrapped copy is stored on the device. Without the passphrase or that passkey,
// data.json can't be read.
window.HomeSolarLock = (() => {
  "use strict";
  const STORE = "home-solar-unlock";
  const PRF_SALT = new TextEncoder().encode("home-solar prf v1");
  const enc = new TextEncoder(), dec = new TextDecoder();
  const b64d = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
  const b64e = (b) => btoa(String.fromCharCode(...new Uint8Array(b)));
  const rnd = (n) => crypto.getRandomValues(new Uint8Array(n));

  const load = () => { try { return JSON.parse(localStorage.getItem(STORE) || "null"); } catch { return null; } };
  const save = (v) => { try { localStorage.setItem(STORE, JSON.stringify(v)); } catch {} };
  const forget = () => { try { localStorage.removeItem(STORE); } catch {} idbDel(); };

  async function keyFromPassphrase(pass, box) {
    const base = await crypto.subtle.importKey("raw", enc.encode(pass.normalize("NFKC")), "PBKDF2", false, ["deriveBits"]);
    return new Uint8Array(await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt: b64d(box.salt), iterations: box.iter }, base, 256));
  }
  async function decryptWith(key, box) {
    const k = key instanceof CryptoKey ? key : await crypto.subtle.importKey("raw", key, "AES-GCM", false, ["decrypt"]);
    return JSON.parse(dec.decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: b64d(box.iv) }, k, b64d(box.ct))));
  }

  // ---- passkey (Face ID) ----
  const passkeysPossible = () => !!(window.PublicKeyCredential && navigator.credentials && crypto.subtle);
  async function wrapKeyFrom(prf) {
    const base = await crypto.subtle.importKey("raw", prf, "HKDF", false, ["deriveKey"]);
    return crypto.subtle.deriveKey({ name: "HKDF", hash: "SHA-256", salt: new Uint8Array(32), info: enc.encode("home-solar wrap") },
      base, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
  }
  async function prfFromPasskey(credId) {
    const cred = await navigator.credentials.get({ publicKey: {
      challenge: rnd(32), rpId: location.hostname, userVerification: "required", timeout: 60000,
      allowCredentials: [{ type: "public-key", id: b64d(credId) }],
      extensions: { prf: { eval: { first: PRF_SALT } } },
    } });
    const r = cred && cred.getClientExtensionResults().prf;
    if (!r || !r.results || !r.results.first) throw new Error("This device's passkeys can't unlock data yet.");
    return r.results.first;
  }
  // Creates a passkey and stores the data key wrapped by its PRF output. Two Face ID
  // prompts on some iPhones: one to create the passkey, one to read its secret.
  async function setUpFaceId(rawKey) {
    const cred = await navigator.credentials.create({ publicKey: {
      rp: { name: "Home Solar", id: location.hostname },
      user: { id: rnd(16), name: "Home Solar", displayName: "Home Solar" },
      challenge: rnd(32), timeout: 60000,
      pubKeyCredParams: [{ type: "public-key", alg: -7 }, { type: "public-key", alg: -257 }],
      authenticatorSelection: { residentKey: "required", userVerification: "required" },
      extensions: { prf: { eval: { first: PRF_SALT } } },
    } });
    const ext = cred.getClientExtensionResults().prf || {};
    if (ext.enabled === false) throw new Error("unsupported");
    const credId = b64e(cred.rawId);
    const prf = (ext.results && ext.results.first) || await prfFromPasskey(credId);
    const iv = rnd(12);
    const wrapped = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await wrapKeyFrom(prf), rawKey);
    save({ kind: "passkey", credId, iv: b64e(iv), wrapped: b64e(wrapped) });
  }
  async function keyFromFaceId(s) {
    const prf = await prfFromPasskey(s.credId);
    return new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: b64d(s.iv) }, await wrapKeyFrom(prf), b64d(s.wrapped)));
  }

  // ---- fallback: keep a non-extractable key on this device ----
  const idb = () => new Promise((res, rej) => { const r = indexedDB.open("home-solar", 1); r.onupgradeneeded = () => r.result.createObjectStore("k"); r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); });
  async function idbPut(v) { const db = await idb(); return new Promise((res, rej) => { const t = db.transaction("k", "readwrite"); t.objectStore("k").put(v, "key"); t.oncomplete = res; t.onerror = () => rej(t.error); }); }
  async function idbGet() { const db = await idb(); return new Promise((res) => { const q = db.transaction("k").objectStore("k").get("key"); q.onsuccess = () => res(q.result || null); q.onerror = () => res(null); }); }
  function idbDel() { try { idb().then((db) => db.transaction("k", "readwrite").objectStore("k").delete("key")).catch(() => {}); } catch {} }
  async function keepOnDevice(rawKey) {
    const k = await crypto.subtle.importKey("raw", rawKey, "AES-GCM", false, ["decrypt"]);
    await idbPut(k);
    save({ kind: "device" });
  }

  // ---- screens ----
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const lockIcon = '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/></svg>';
  const faceIcon = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 8V6a2 2 0 0 1 2-2h2M16 4h2a2 2 0 0 1 2 2v2M20 16v2a2 2 0 0 1-2 2h-2M8 20H6a2 2 0 0 1-2-2v-2"/><path d="M9 9v1.5M15 9v1.5M12 9v4h-1M9.5 16a4 4 0 0 0 5 0"/></svg>';

  function shell(view, inner) {
    document.body.classList.add("locked");
    view.innerHTML = `<section class="lock"><span class="lock-ic">${lockIcon}</span><h1 style="font-size:28px">Home Solar</h1>${inner}</section>`;
  }

  // Resolves with the decrypted data, asking for Face ID or the passphrase as needed.
  function unlock(view, box) {
    return new Promise((resolve) => {
      let rawKey = null;
      const done = (data) => { document.body.classList.remove("locked"); resolve(data); };

      const offerFaceId = (data) => {
        if (!passkeysPossible()) return askKeep(data);
        shell(view, `<p class="small" style="text-align:center;margin:0">Unlock with Face ID next time instead of typing your passphrase?</p>
          <button class="btn" type="button" id="fid">${faceIcon}<span>Use Face ID</span></button>
          <button class="btn secondary" type="button" id="skip">Not now</button><p class="small err" id="err" role="alert"></p>`);
        view.querySelector("#skip").onclick = () => done(data);
        view.querySelector("#fid").onclick = async (e) => {
          e.target.closest("button").disabled = true;
          try { await setUpFaceId(rawKey); done(data); }
          catch (err) {
            if (err && err.message === "unsupported" || /extension|prf|can't unlock/i.test(String(err && err.message))) return askKeep(data, true);
            view.querySelector("#err").textContent = "Face ID wasn't set up. You can try again or skip.";
            e.target.closest("button").disabled = false;
          }
        };
      };
      const askKeep = (data, noPrf) => {
        shell(view, `<p class="small" style="text-align:center;margin:0">${noPrf ? "This device can't use Face ID to unlock data. " : ""}Keep Home Solar unlocked on this device? Anyone holding it unlocked could open the app.</p>
          <button class="btn" type="button" id="keep">Keep unlocked here</button>
          <button class="btn secondary" type="button" id="skip">Ask every time</button>`);
        view.querySelector("#skip").onclick = () => done(data);
        view.querySelector("#keep").onclick = async () => { try { await keepOnDevice(rawKey); } catch {} done(data); };
      };

      const askPassphrase = (msg) => {
        shell(view, `<form id="pf" class="lock-form" autocomplete="on">
            <input type="text" name="username" value="Home Solar" autocomplete="username" hidden>
            <label class="small" for="pass" style="align-self:flex-start">Passphrase</label>
            <input id="pass" name="password" type="password" autocomplete="current-password" required enterkeyhint="go">
            <p class="small err" id="err" role="alert">${msg ? esc(msg) : ""}</p>
            <button class="btn" type="submit">Unlock</button>
          </form>`);
        const input = view.querySelector("#pass");
        input.oninput = () => (view.querySelector("#err").textContent = "");
        view.querySelector("#pf").onsubmit = async (e) => {
          e.preventDefault();
          if (!input.value.trim()) { view.querySelector("#err").textContent = "Enter your passphrase first."; return; }
          const btn = e.target.querySelector("button"); btn.disabled = true; btn.textContent = "Unlocking…";
          try {
            rawKey = await keyFromPassphrase(input.value, box);
            const data = await decryptWith(rawKey, box);
            const s = load();
            if (s && s.kind) done(data); else offerFaceId(data);
          } catch {
            btn.disabled = false; btn.textContent = "Unlock";
            view.querySelector("#err").textContent = "That passphrase didn't work.";
            input.select();
          }
        };
      };

      const askFaceId = (s, msg) => {
        shell(view, `<button class="btn" type="button" id="fid">${faceIcon}<span>Unlock with Face ID</span></button>
          <button class="btn secondary" type="button" id="usepass">Use passphrase</button>
          <p class="small err" id="err" role="alert">${msg ? esc(msg) : ""}</p>`);
        view.querySelector("#usepass").onclick = () => askPassphrase();
        view.querySelector("#fid").onclick = async (e) => {
          e.target.closest("button").disabled = true;
          try { rawKey = await keyFromFaceId(s); done(await decryptWith(rawKey, box)); }
          catch (err) {
            e.target.closest("button").disabled = false;
            if (err && err.name === "OperationError") { forget(); askPassphrase("The passphrase has changed. Enter the new one."); }
            else view.querySelector("#err").textContent = "Face ID didn't unlock it. Try again or use your passphrase.";
          }
        };
      };

      const s = load();
      if (s && s.kind === "passkey") return askFaceId(s);
      if (s && s.kind === "device") {
        return idbGet().then((k) => k ? decryptWith(k, box).then(done) : Promise.reject())
          .catch(() => { forget(); askPassphrase("The passphrase has changed. Enter the new one."); });
      }
      askPassphrase();
    });
  }

  function status() {
    const s = load();
    return s && s.kind === "passkey" ? "Face ID" : s && s.kind === "device" ? "Kept unlocked on this device" : "Passphrase each time";
  }

  return { unlock, forget, status, isEncrypted: (d) => !!(d && d.ct && d.iv && d.salt) };
})();
