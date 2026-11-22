// Throwaway design preview: shared phone chrome, the rest clock, and a few live controls.

const LB_PER_KG = 2.2046226218;
const REST_TARGET = 180; // T1 rest, seconds

const state = {
	rest: 94,
	ticking: true,
	hrConnected: true,
	unit: 'lb'
};

// ---------------------------------------------------------------- weights (mirrors WeightMath / BarbellMath)

function displayWeight(kg) {
	const value = state.unit === 'lb' ? kg * LB_PER_KG : kg;
	return Math.round(value * 2) / 2; // snap to 0.5, like WeightMath.displayWeightFromKg
}

function formatWeight(kg) {
	return displayWeight(kg).toFixed(1);
}

function platesPerSide(total) {
	const bar = state.unit === 'lb' ? 45 : 20;
	const plates = state.unit === 'lb' ? [45, 35, 25, 10, 5, 2.5] : [25, 20, 15, 10, 5, 2.5, 1.25];
	if (total < bar - 0.01) return 'BELOW BAR';
	let remaining = Math.round(((total - bar) / 2) * 100);
	const out = [];
	for (const p of plates) {
		const c = Math.round(p * 100);
		while (remaining >= c) {
			out.push(p);
			remaining -= c;
		}
	}
	if (!out.length) return 'EMPTY BAR';
	const text = `${out.join(' + ')} /SIDE`;
	return remaining > 0 ? `${text} (+${remaining / 100} SHORT)` : text;
}

function warmups(working) {
	const bar = state.unit === 'lb' ? 45 : 20;
	const inc = state.unit === 'lb' ? 5 : 2.5;
	if (working <= bar + inc) return [];
	const sets = [{ weight: bar, reps: 10 }];
	for (const [pct, reps] of [[0.4, 5], [0.6, 3], [0.8, 2]]) {
		const w = Math.round((working * pct) / inc) * inc;
		if (w <= sets[sets.length - 1].weight || w >= working) continue;
		sets.push({ weight: w, reps });
	}
	return sets;
}

// ---------------------------------------------------------------- rest clock (SegmentedDigitalClock)

const SEGMENTS = {
	0: 'abcdef',
	1: 'bc',
	2: 'abged',
	3: 'abcdg',
	4: 'fgbc',
	5: 'afgcd',
	6: 'afedcg',
	7: 'abc',
	8: 'abcdefg',
	9: 'abcdfg'
};

function digitHtml(glyph) {
	const on = SEGMENTS[glyph] ?? '';
	const seg = (name, dir) => `<span class="seg ${dir} ${name}${on.includes(name) ? ' on' : ''}"></span>`;
	return `<div class="digit">${seg('a', 'h')}${seg('g', 'h')}${seg('d', 'h')}${seg('f', 'v')}${seg('b', 'v')}${seg('e', 'v')}${seg('c', 'v')}</div>`;
}

function clockHtml(seconds) {
	const text = `${String(Math.floor(seconds / 60)).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`;
	return [...text].map((g) => (g === ':' ? '<div class="colon"><i></i><i></i></div>' : digitHtml(g))).join('');
}

/** Same thresholds as WorkoutView.timerColor: red over target, orange in the last 15 s. */
function clockState(seconds) {
	if (seconds > REST_TARGET) return 'over';
	if (seconds >= Math.max(0, REST_TARGET - 15)) return 'warn';
	return 'ok';
}

function renderClocks() {
	for (const el of document.querySelectorAll('[data-clock]')) {
		const seconds = el.dataset.clock === 'fresh' ? 0 : state.rest;
		el.innerHTML = clockHtml(Math.min(seconds, 99 * 60 + 59));
		el.classList.remove('warn', 'over');
		const s = clockState(seconds);
		if (s !== 'ok') el.classList.add(s);
	}
	const left = Math.max(0, REST_TARGET - state.rest);
	for (const el of document.querySelectorAll('[data-countdown]')) {
		el.textContent = left > 0 ? `${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}` : 'GO';
		el.classList.toggle('timer-go', left === 0);
	}
	for (const el of document.querySelectorAll('[data-rest-bar]')) {
		el.style.width = `${Math.min(100, (state.rest / REST_TARGET) * 100)}%`;
	}
	document.getElementById('rest-out').textContent =
		`${String(Math.floor(state.rest / 60)).padStart(2, '0')}:${String(state.rest % 60).padStart(2, '0')}`;
}

// ---------------------------------------------------------------- weights / plates / warm-ups

function renderWeights() {
	for (const el of document.querySelectorAll('[data-w]')) el.textContent = formatWeight(Number(el.dataset.w));
	for (const el of document.querySelectorAll('[data-u]')) el.textContent = state.unit.toUpperCase();
	for (const el of document.querySelectorAll('[data-plates]')) {
		el.textContent = platesPerSide(displayWeight(Number(el.dataset.plates)));
	}
	const list = document.getElementById('warmup-list');
	const unit = state.unit.toUpperCase();
	list.innerHTML = warmups(displayWeight(102.1))
		.map((w) => `<li><span>${w.weight} ${unit} × ${w.reps}</span><span>${platesPerSide(w.weight)}</span></li>`)
		.join('');
}

// ---------------------------------------------------------------- heart rate

let hrPhase = 0;
function renderHeartRate() {
	const path = document.getElementById('hr-path');
	const bpm = document.getElementById('hr-bpm');
	const panel = path.closest('.hr-panel');
	panel.classList.toggle('hr-off', !state.hrConnected);
	for (const dot of document.querySelectorAll('[data-hr-dot]')) dot.classList.toggle('off', !state.hrConnected);
	if (!state.hrConnected) {
		bpm.textContent = '—';
		return;
	}
	const points = [];
	for (let x = 0; x <= 220; x += 10) {
		const v = 35 + 18 * Math.sin((x + hrPhase) / 28) + 6 * Math.sin((x + hrPhase) / 9);
		points.push(`${x},${v.toFixed(1)}`);
	}
	path.setAttribute('d', `M${points.join(' L')}`);
	bpm.textContent = String(Math.round(118 + 12 * Math.sin(hrPhase / 40)));
}

// ---------------------------------------------------------------- shared phone chrome

const ICONS = {
	workout: '<svg viewBox="0 0 24 24"><path d="M3 9v6M6 7v10M18 7v10M21 9v6M6 12h12"/></svg>',
	analytics: '<svg viewBox="0 0 24 24"><path d="M3 20h18M5 16l4-5 4 3 6-8"/></svg>',
	history: '<svg viewBox="0 0 24 24"><path d="M4 12a8 8 0 1 0 3-6.2M4 4v4h4M12 8v4l3 2"/></svg>',
	settings: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M4.9 19.1 7 17M17 7l2.1-2.1"/></svg>'
};

function addChrome() {
	for (const phone of document.querySelectorAll('.phone')) {
		const isLock = phone.classList.contains('lock');
		const isIslandDemo = phone.classList.contains('island-demo');
		const hasOwnIsland = isLock || isIslandDemo;
		phone.insertAdjacentHTML(
			'afterbegin',
			`<div class="statusbar"><span>${isLock || isIslandDemo ? '' : '9:41'}</span><span class="sb-icons">●●●● ⌔ <i class="sb-battery"></i></span></div>${hasOwnIsland ? '' : '<div class="island-pill"></div>'}`
		);
		if (isLock || isIslandDemo) continue;
		const active = phone.dataset.tab;
		const tabs = ['workout', 'analytics', 'history', 'settings']
			.map((t) => `<div class="tab${t === active ? ' on' : ''}">${ICONS[t]}<span>${t.toUpperCase()}</span></div>`)
			.join('');
		phone.insertAdjacentHTML('beforeend', `<nav class="tabbar">${tabs}</nav>`);
	}
}

// ---------------------------------------------------------------- controls

function bindControls() {
	const rest = document.getElementById('rest');
	rest.addEventListener('input', () => {
		state.rest = Number(rest.value);
		renderClocks();
	});
	document.getElementById('tick').addEventListener('change', (e) => (state.ticking = e.target.checked));
	document.getElementById('hr').addEventListener('change', (e) => {
		state.hrConnected = e.target.checked;
		renderHeartRate();
	});
	document.getElementById('kg').addEventListener('change', (e) => {
		state.unit = e.target.checked ? 'kg' : 'lb';
		renderWeights();
	});

	setInterval(() => {
		if (!state.ticking) return;
		state.rest = state.rest >= 240 ? 0 : state.rest + 1;
		rest.value = String(state.rest);
		renderClocks();
	}, 1000);
	setInterval(() => {
		hrPhase += 4;
		renderHeartRate();
	}, 120);
}

addChrome();
renderClocks();
renderWeights();
renderHeartRate();
bindControls();
