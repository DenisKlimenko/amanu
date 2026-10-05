// Writes down who Google Meet shows as speaking, and when, and which call it
// is: the meeting code from the address and the tab's title, which Meet sets
// to "Meet - " and the meeting's title.
//
// Meet outlines the tile of whoever is talking, or animates a small level
// meter on it, and the tile carries the participant's id and name. This reads
// those a few times a second and sends amanu every change, plus the current
// state every few seconds, so that a timeline which stops means the tab
// stopped rather than that somebody went on talking.
//
// The waiting room reports its call too, with nobody speaking: a recording
// can start there, while the preview holds the microphone, and its folder is
// named when it starts. What tells the waiting room from the page Meet leaves
// after a call, which stays until the tab is closed, is whether the call's
// tiles have appeared yet. That reads none of Meet's wording, so it works in
// any language.
//
// Whether our own mic is off goes with every report too. What amanu hears
// through it then never reached the call, and is not part of the meeting.
//
// Nothing here leans on Meet's class names, which change with every release:
// tiles are found by `data-participant-id`, and "lit" means a coloured outline
// or a coloured sliver of a meter, however Meet happens to style either.

const SCAN_MS = 250;
// Shorter than amanu's `MeetSpeakers.stale`, with room for a throttled tab.
const HEARTBEAT_MS = 4000;
const TILE = "[data-participant-id]";
// An id for this tab, made once for each page load. One connection relays
// every Meet tab the browser has open, and a second tab can be on the same
// call — the page Meet shows before joining, left open beside the joined one —
// so the call's code alone does not tell amanu whose state a report is.
const TAB = crypto.randomUUID();

let inCall = false;
// Whether this page's call has had tiles on screen. Until it has, the page is
// the waiting room; once they have come and gone, the call is over.
let joined = false;
let page = location.pathname;
// A meeting's own page: its code is the whole path.
const MEETING_PAGE = /^\/[a-z]{3}-[a-z]{4}-[a-z]{3}$/i;
let sentState = "";
let sentAt = 0;

// Meet can move the call into a picture-in-picture window of its own when the
// tab is in the background; the tiles are then in that window's document.
function documents() {
  const docs = [document];
  try {
    const pip = window.documentPictureInPicture?.window?.document;
    if (pip) docs.push(pip);
  } catch {}
  return docs;
}

function style(el) {
  return (el.ownerDocument.defaultView ?? window).getComputedStyle(el);
}

// Meet's highlight colours are saturated; greys, white and black are not.
function colourful(color) {
  const m = /rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?/.exec(color ?? "");
  if (!m || (m[4] !== undefined && Number(m[4]) === 0)) return false;
  const [r, g, b] = [m[1], m[2], m[3]].map(Number);
  const high = Math.max(r, g, b);
  const low = Math.min(r, g, b);
  return high >= 40 && low <= 220 && high - low > 60;
}

// A coloured border or outline, two pixels or more. What Meet restyles with
// speech is not necessarily something it draws: the ring measured was 0×0,
// inside a `display: none` subtree, which is why only the element's own
// `display` is checked — asking whether it is rendered would lose the speaker
// too. Our own tile wears a similar ring whenever our mic is off, so it reads
// as lit with nobody talking; the `self` flag is what keeps amanu from
// believing it.
function outlined(el) {
  const s = style(el);
  if (s.display === "none") return false;
  for (const side of ["Top", "Right", "Bottom", "Left"]) {
    if (parseFloat(s[`border${side}Width`]) >= 2 && colourful(s[`border${side}Color`])) {
      return true;
    }
  }
  return s.outlineStyle !== "none" && parseFloat(s.outlineWidth) >= 2 && colourful(s.outlineColor);
}

// One bar of the level meter: a few pixels wide, filled with colour.
function meterBar(el) {
  const box = el.getBoundingClientRect();
  if (box.width <= 0 || box.width > 10 || box.height <= 0) return false;
  const s = style(el);
  return s.display !== "none" && colourful(s.backgroundColor);
}

function lit(tile) {
  // The outline is sometimes drawn by a wrapper just outside the tile.
  for (let el = tile, up = 0; el && up <= 2; el = el.parentElement, up++) {
    if (outlined(el)) return true;
  }
  // Controls on the tile — mute, pin, the menu — are never the indicator, and
  // a focused or toggled one can wear a coloured ring of its own.
  const walker = tile.ownerDocument.createTreeWalker(tile, NodeFilter.SHOW_ELEMENT, {
    acceptNode: (el) => el.tagName === "BUTTON" || el.getAttribute("role") === "button"
      ? NodeFilter.FILTER_REJECT
      : NodeFilter.FILTER_ACCEPT,
  });
  let looked = 0;
  for (let el = walker.nextNode(); el && looked < 400; el = walker.nextNode(), looked++) {
    if (outlined(el) || meterBar(el)) return true;
  }
  return false;
}

// "Daniel Craig (Presentation)", "Denis Klimenko (You)" → the person.
function person(text) {
  return text?.replace(/\s*\([^)]*\)\s*$/, "").trim() || null;
}

// Material icons are ligatures — "mic_off", "keep" — set in a symbol font,
// and controls hold nothing but icons and labels for them.
const NOT_A_NAME = 'button, i, [role="button"], .google-symbols, .google-material-icons';

// The caption under the tile. `data-self-name` is not used for this, although
// it looks like it should be: it holds *our* name, and an element holding it
// can sit above every tile — read that way, the whole call is us.
function nameOf(tile) {
  for (const span of tile.querySelectorAll("span.notranslate")) {
    if (span.closest(NOT_A_NAME)) continue;
    const text = span.textContent.trim();
    if (text.length >= 2 && text.length <= 60 && !text.includes("_")) return person(text);
  }
  return person(tile.getAttribute("aria-label"));
}

// Our own tile. amanu knows our words from the microphone already, so this is
// only a hint that lets it ignore the tile. Meet marks it with our name in
// `data-self-name`, mirrors the local camera preview and nobody else's video,
// labels the tile as ours, and puts the background-effects and reframing
// controls on it alone.
function isSelf(tile) {
  if (tile.hasAttribute("data-self-name") || tile.querySelector("[data-self-name]")) return true;
  for (const video of tile.querySelectorAll("video")) {
    if (/^matrix(3d)?\(\s*-1\b/.test(style(video).transform)) return true;
  }
  for (const icon of tile.querySelectorAll("i.google-symbols, i.google-material-icons")) {
    const glyph = icon.textContent.trim();
    if ((glyph === "visual_effects" || glyph === "frame_person")
      && !icon.closest('[role="menu"], [role="menuitem"], [role="dialog"]')) return true;
  }
  return /\((you|вы)\)/i.test(tile.textContent ?? "");
}

// Whether this tile shows its mic as off. Meet marks every muted tile with a
// mic_off icon; the button in the toolbar is not read instead, because only
// its label, in the page's language, tells it from the camera's. That our
// own tile carries the icon is reasoned from the others', not yet seen.
function micOff(tile) {
  for (const icon of tile.querySelectorAll("i.google-symbols, i.google-material-icons")) {
    if (icon.textContent.trim() === "mic_off"
      && icon.getClientRects().length > 0
      && style(icon).visibility !== "hidden"
      && !icon.closest('button, [role="button"], [role="menu"], [role="dialog"]')) return true;
  }
  return false;
}

function scan() {
  const speaking = new Map();
  let tiles = 0;
  let muted = false;
  for (const doc of documents()) {
    for (const tile of doc.querySelectorAll(TILE)) {
      const id = tile.getAttribute("data-participant-id");
      if (!id) continue;
      const box = tile.getBoundingClientRect();
      if (box.width < 50 || box.height < 50) continue;
      tiles += 1;
      if (!muted && micOff(tile) && isSelf(tile)) muted = true;
      // A participant can be on screen twice — the stage and the strip.
      if (speaking.has(id) || !lit(tile)) continue;
      const speaker = { id, name: nameOf(tile) };
      if (isSelf(tile)) speaker.self = true;
      speaking.set(id, speaker);
    }
  }
  return { tiles, speaking: [...speaking.values()], muted };
}

function stateOf(speaking, muted) {
  return speaking.map((s) => s.id).sort().join("\n") + (muted ? "\nmuted" : "");
}

function send(speaking, muted = false) {
  const now = Date.now();
  sentState = stateOf(speaking, muted);
  sentAt = now;
  const report = {
    t: now, meeting: location.pathname.slice(1), tab: TAB, title: document.title, speaking,
  };
  if (muted) report.muted = true;
  // A rejected promise is a worker that is restarting; the next state gets through.
  Promise.resolve(chrome.runtime.sendMessage(report)).catch(() => {});
}

const timer = setInterval(() => {
  try {
    // Meet moves from one meeting to another without loading a page.
    if (location.pathname !== page) {
      page = location.pathname;
      joined = false;
    }
    const { tiles, speaking, muted } = scan();
    if (!tiles) {
      // Out of the call — or never in it: the lobby has no tiles. Two things
      // here are reasoned, not seen: that the waiting room shows no tile that
      // counts, and that the page Meet leaves after a call is not reloaded.
      // Reloaded, it would report its call as a waiting room again.
      if (inCall) send([]);
      inCall = false;
      if (!joined && MEETING_PAGE.test(page) && Date.now() - sentAt >= HEARTBEAT_MS) send([]);
      return;
    }
    inCall = true;
    joined = true;
    const state = stateOf(speaking, muted);
    if (state !== sentState || Date.now() - sentAt >= HEARTBEAT_MS) {
      if (state !== sentState) {
        console.debug("amanu: speaking", speaking.map((s) => s.name), muted ? "(muted)" : "");
      }
      send(speaking, muted);
    }
  } catch (error) {
    // The extension was reloaded or removed under a live page; this copy of
    // the script can no longer reach it, and a new one is already running.
    clearInterval(timer);
  }
}, SCAN_MS);

addEventListener("pagehide", () => {
  try {
    if (inCall) send([]);
  } catch {}
});
