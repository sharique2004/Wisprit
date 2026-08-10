/* The hero demo: a scripted re-enactment of Wisprit's real pipeline.
   Hold the keycap (pointer) or the space bar to "dictate": raw partials stream
   in underlined (marked text, exactly like Live Typing), and on release the
   cleaned text commits. Idle visitors get an auto-played loop; holding takes
   over. Reduced-motion visitors get the committed text with no theatrics. */

(function () {
  const committedEl = document.getElementById("demo-committed");
  const volatileEl = document.getElementById("demo-volatile");
  const stateEl = document.getElementById("demo-state");
  const keycap = document.getElementById("keycap");
  const micDot = document.getElementById("mic-dot");
  if (!committedEl || !keycap) return;

  // Each utterance: the raw partial stream (what the recognizer hears,
  // fillers and all) and the committed result after cleanup. All three are
  // real behaviors from the app: filler stripping, homophone repair, and
  // spoken-spelling correction.
  const SCRIPT = [
    {
      partials: ["ok so", "ok so um the", "ok so um the the migration", "ok so um the the migration went fine", "ok so um the the migration went fine but the redis cash layer is acting up"],
      committed: "The migration went fine, but the Redis cache layer is acting up.",
    },
    {
      partials: ["this workload", "this workload is really", "this workload is really right heavy", "this workload is really right heavy so batch the rights"],
      committed: "This workload is really write-heavy, so batch the writes.",
    },
    {
      partials: ["add Sharik to", "add Sharik to the invite", "add Sharik to the invite actually it's", "add Sharik to the invite actually it's S-H-A-R-I-Q-U-E"],
      committed: "Add Sharique to the invite.",
    },
  ];

  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduced) {
    committedEl.textContent = SCRIPT[0].committed + " ";
    stateEl.textContent = "Hold the key to dictate.";
  }

  let idx = 0;          // which utterance
  let holding = false;  // pointer/space currently down
  let playing = false;  // an utterance is mid-flight
  let autoTimer = null;
  let step = 0;
  let stepTimer = null;

  function setHot(on) {
    micDot.classList.toggle("hot", on);
    keycap.classList.toggle("held", on);
    stateEl.textContent = on ? "Listening…" : "Hold the key to dictate — or just watch.";
  }

  function clearField() {
    committedEl.textContent = "";
    volatileEl.textContent = "";
  }

  function streamStep(utt, done) {
    if (step < utt.partials.length) {
      volatileEl.textContent = utt.partials[step];
      step += 1;
      stepTimer = setTimeout(() => streamStep(utt, done), 520 + Math.random() * 240);
    } else if (done) {
      finishUtterance(utt);
    }
    // When driven by a real hold, we linger on the last partial until release.
  }

  function finishUtterance(utt) {
    clearTimeout(stepTimer);
    volatileEl.textContent = "";
    committedEl.textContent = utt.committed + " ";
    setHot(false);
    playing = false;
    idx = (idx + 1) % SCRIPT.length;
    scheduleAuto(4200);
  }

  function startUtterance(auto) {
    if (playing) return;
    playing = true;
    step = 0;
    clearField();
    setHot(true);
    const utt = SCRIPT[idx];
    if (auto) {
      streamStep(utt, true);
    } else {
      streamStep(utt, false);
    }
  }

  function scheduleAuto(delay) {
    if (reduced) return;
    clearTimeout(autoTimer);
    autoTimer = setTimeout(() => {
      if (!holding && !playing && !document.hidden) startUtterance(true);
    }, delay);
  }

  // --- manual hold ---
  function holdStart(e) {
    if (e) e.preventDefault();
    if (holding) return;
    holding = true;
    clearTimeout(autoTimer);
    if (playing) { clearTimeout(stepTimer); playing = false; }
    startUtterance(false);
  }
  function holdEnd() {
    if (!holding) return;
    holding = false;
    if (playing) finishUtterance(SCRIPT[(idx) % SCRIPT.length]);
  }

  keycap.addEventListener("pointerdown", holdStart);
  window.addEventListener("pointerup", holdEnd);
  keycap.addEventListener("pointercancel", holdEnd);
  keycap.addEventListener("keydown", (e) => {
    if ((e.key === " " || e.key === "Enter") && !e.repeat) holdStart(e);
  });
  keycap.addEventListener("keyup", (e) => {
    if (e.key === " " || e.key === "Enter") holdEnd();
  });
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) { clearTimeout(autoTimer); }
    else scheduleAuto(2000);
  });

  if (!reduced) scheduleAuto(1400);
})();
