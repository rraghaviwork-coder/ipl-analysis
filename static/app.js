// IPL Match Analysis — frontend logic: fetch JSON from Flask and draw charts
const $ = (id) => document.getElementById(id);
const charts = {};
let META = null;

Chart.defaults.font.family = "Inter, system-ui, sans-serif";
Chart.defaults.color = "#6b7489";
Chart.defaults.plugins.legend.labels.usePointStyle = true;

const color = (team) => (META.info[team] || {}).color || "#94a3b8";
const short = (team) => (META.info[team] || {}).short || team;
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const range = () => `from=${$("from").value}&to=${$("to").value}`;

function draw(id, config) {
  if (charts[id]) charts[id].destroy();
  config.options = Object.assign({ responsive: true, maintainAspectRatio: false }, config.options);
  charts[id] = new Chart($(id), config);
}

function hbar(id, labels, values, colors, suffix = "") {
  draw(id, {
    type: "bar",
    data: { labels, datasets: [{ data: values, backgroundColor: colors, borderRadius: 6, barThickness: "flex", maxBarThickness: 22 }] },
    options: {
      indexAxis: "y",
      plugins: { legend: { display: false }, tooltip: { callbacks: { label: (c) => ` ${c.raw}${suffix}` } } },
      scales: { x: { grid: { color: "#eef1f7" } }, y: { grid: { display: false } } },
    },
  });
}

function doughnut(id, labels, values, colors) {
  draw(id, {
    type: "doughnut",
    data: { labels, datasets: [{ data: values, backgroundColor: colors, borderWidth: 0 }] },
    options: {
      cutout: "65%",
      plugins: {
        legend: { position: "bottom" },
        tooltip: { callbacks: { label: (c) => ` ${c.label}: ${c.raw} (${((c.raw / c.dataset.data.reduce((a, b) => a + b, 0)) * 100).toFixed(1)}%)` } },
      },
    },
  });
}

async function loadSummary() {
  const d = await (await fetch(`/api/summary?${range()}`)).json();

  // KPIs
  $("k-matches").textContent = d.kpis.matches.toLocaleString();
  $("k-seasons").textContent = d.kpis.seasons;
  $("k-teams").textContent = d.kpis.teams;
  $("k-venues").textContent = d.kpis.venues;
  $("k-chase").textContent = d.kpis.chase_pct + "%";
  $("k-titles").textContent = d.kpis.most_titles.map(short).join(" / ") || "–";
  $("k-titles-l").textContent = `Most titles (${d.kpis.most_titles_n})`;

  // Champions timeline
  $("champions").innerHTML = d.champions.map((c) => `
    <div class="champ" style="--c:${color(c.champion)}">
      <div class="yr">${c.season}</div>
      <div class="badge">${esc(short(c.champion))}</div>
      <div class="nm">${esc(c.champion)}</div>
      <div class="ru">beat ${esc(short(c.runner_up))} · POTM ${esc(c.potm)}</div>
    </div>`).join("");

  // Teams
  const t = d.teams;
  hbar("c-wins", t.map((r) => r.team), t.map((r) => r.wins), t.map((r) => color(r.team)), " wins");
  const pct = t.filter((r) => r.played >= 20).sort((a, b) => b.pct - a.pct);
  hbar("c-pct", pct.map((r) => r.team), pct.map((r) => r.pct), pct.map((r) => color(r.team)), "%");
  hbar("c-titles", d.titles.map((r) => r.label), d.titles.map((r) => r.value), d.titles.map((r) => color(r.label)), " titles");

  draw("c-season", {
    type: "line",
    data: { labels: d.per_season.map((r) => r.season), datasets: [{ data: d.per_season.map((r) => r.matches), borderColor: "#ff7a1a", backgroundColor: "rgba(255,122,26,.12)", fill: true, tension: 0.2, pointRadius: 3 }] },
    options: { plugins: { legend: { display: false } }, scales: { x: { grid: { display: false } }, y: { beginAtZero: true, grid: { color: "#eef1f7" } } } },
  });

  // Toss & strategy
  doughnut("c-decision", ["Field first", "Bat first"], [d.toss.field, d.toss.bat], ["#2561AE", "#ffc531"]);
  doughnut("c-tosswin", ["Yes", "No"], [d.toss.won_match, d.toss.lost_match], ["#16a34a", "#e5e7eb"]);
  doughnut("c-chase", ["Chasing team", "Batting first team"], [d.chase.chase_wins, d.chase.bat_first_wins], ["#ff7a1a", "#1a2a5e"]);

  draw("c-trend", {
    type: "bar",
    data: {
      labels: d.toss.trend.seasons,
      datasets: [
        { label: "Field first", data: d.toss.trend.field, backgroundColor: "#2561AE", borderRadius: 4 },
        { label: "Bat first", data: d.toss.trend.bat, backgroundColor: "#ffc531", borderRadius: 4 },
      ],
    },
    options: { scales: { x: { stacked: true, grid: { display: false } }, y: { stacked: true, grid: { color: "#eef1f7" } } } },
  });

  draw("c-chasetrend", {
    type: "line",
    data: {
      labels: d.chase.seasons,
      datasets: [
        { label: "Chasing win %", data: d.chase.pct, borderColor: "#ff7a1a", tension: 0.2, pointRadius: 3 },
        { label: "50% line", data: d.chase.seasons.map(() => 50), borderColor: "#cbd2e1", borderDash: [5, 5], pointRadius: 0 },
      ],
    },
    options: { scales: { x: { grid: { display: false } }, y: { min: 20, max: 80, grid: { color: "#eef1f7" }, ticks: { callback: (v) => v + "%" } } } },
  });

  // Players & venues
  hbar("c-potm", d.potm.map((r) => r.label), d.potm.map((r) => r.value), "#ff7a1a", " awards");
  hbar("c-cities", d.cities.map((r) => r.label), d.cities.map((r) => r.value), "#2561AE", " matches");
}

async function loadH2H() {
  const a = $("team-a").value, b = $("team-b").value;
  $("a-name").textContent = a;
  $("b-name").textContent = b;
  const d = await (await fetch(`/api/h2h?a=${encodeURIComponent(a)}&b=${encodeURIComponent(b)}&${range()}`)).json();

  $("a-wins").textContent = d.a_wins;
  $("b-wins").textContent = d.b_wins;
  $("a-wins").style.color = color(a);
  $("b-wins").style.color = color(b);
  $("h-total").textContent = `${d.matches} matches`;
  $("h-nr").textContent = d.no_result ? `${d.no_result} no result` : "";

  const total = d.a_wins + d.b_wins || 1;
  Object.assign($("split-a").style, { width: (d.a_wins / total) * 100 + "%", background: color(a) });
  Object.assign($("split-b").style, { width: (d.b_wins / total) * 100 + "%", background: color(b) });

  $("h-rows").innerHTML = d.rows.length
    ? d.rows.map((r) => `<tr>
        <td>${esc(r.date)}</td><td>${esc(r.city)}</td><td>${esc(r.toss)}</td>
        <td><span class="pill" style="background:${color(r.winner)}">${esc(short(r.winner))}</span></td>
        <td>${esc(r.potm)}</td></tr>`).join("")
    : `<tr><td colspan="5" class="muted">These teams never met in the selected seasons.</td></tr>`;
}

async function init() {
  META = await (await fetch("/api/meta")).json();
  const opts = (list) => list.map((v) => `<option value="${esc(v)}">${esc(v)}</option>`).join("");

  $("from").innerHTML = opts(META.seasons);
  $("to").innerHTML = opts(META.seasons);
  $("to").value = META.seasons[META.seasons.length - 1];
  $("team-a").innerHTML = opts(META.teams);
  $("team-b").innerHTML = opts(META.teams);
  $("team-a").value = "Mumbai Indians";
  $("team-b").value = "Chennai Super Kings";

  const refresh = () => { loadSummary(); loadH2H(); };
  $("from").onchange = $("to").onchange = refresh;
  $("team-a").onchange = $("team-b").onchange = loadH2H;
  refresh();
}

init();
