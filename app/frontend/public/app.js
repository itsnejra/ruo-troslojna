// Klijent govori samo s frontendom (isti origin, /api/...); do backenda ga vodi nginx.
"use strict";

const $ = (id) => document.getElementById(id);

async function api(path, options = {}) {
  const res = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.detail || body.status || `HTTP ${res.status}`);
  return body;
}

function prikaziGresku(poruka) {
  $("greska").textContent = poruka;
  $("greska").hidden = !poruka;
}

async function provjeriStanje() {
  try {
    const r = await api("/api/readyz");
    $("status").textContent = `spremno · backend: ${r.served_by}`;
    $("status").className = "status ok";
  } catch (e) {
    $("status").textContent = `nije spremno: ${e.message}`;
    $("status").className = "status lose";
  }
}

async function ucitaj() {
  try {
    const r = await api("/api/notes");
    const lista = $("lista");
    lista.replaceChildren(
      ...r.notes.map((n) => {
        const li = document.createElement("li");
        const tekst = document.createElement("span");
        tekst.textContent = n.text; // textContent: unos korisnika se nikad ne tumači kao HTML
        const vrijeme = document.createElement("time");
        vrijeme.textContent = new Date(n.created_at).toLocaleString("bs-BA");
        li.append(tekst, vrijeme);
        return li;
      }),
    );
    $("podnozje").textContent = `${r.notes.length} bilješki · odgovorio: ${r.served_by}`;
    prikaziGresku("");
  } catch (e) {
    prikaziGresku(`Učitavanje nije uspjelo: ${e.message}`);
  }
}

$("forma").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const polje = $("tekst");
  const text = polje.value.trim();
  if (!text) return;
  try {
    await api("/api/notes", { method: "POST", body: JSON.stringify({ text }) });
    polje.value = "";
    await ucitaj();
  } catch (e) {
    prikaziGresku(`Upis nije uspio: ${e.message}`);
  }
});

provjeriStanje();
ucitaj();
