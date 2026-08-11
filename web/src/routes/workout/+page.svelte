<script lang="ts">
	import { onMount } from 'svelte';
	import {
		completeSet,
		fetchActivePlan,
		fetchActiveSession,
		fetchDashboard,
		finishWorkout,
		startWorkout
	} from '$lib/workout-api';
	import type { ActivePlan, Dashboard, SessionEntry, SessionSet, WorkoutSession } from '$lib/types';
	import { pushToast } from '$lib/toast';
	import {
		displayWeightFromKg,
		getPreferredWeightUnit,
		onWeightUnitChange,
		parseNonNegativeInt,
		type WeightUnit,
		weightUnitLabel
	} from '$lib/ui';

	type WorkoutPreviewRow = {
		name: string;
		sets: number;
		reps: number;
		weightKg: number;
		tier?: string | null;
	};

	type PendingSetContext = {
		entry: SessionEntry;
		setItem: SessionSet;
		targetReps: number;
		weightKg: number;
	};

	let loading = $state(false);
	let errorMessage = $state('');
	let infoMessage = $state('');
	let activePlan = $state<ActivePlan | null>(null);
	let dashboard = $state<Dashboard | null>(null);
	let activeSession = $state<WorkoutSession | null>(null);
	let weightUnit = $state<WeightUnit>('lb');
	let timerSeconds = $state(0);
	let timerHandle: ReturnType<typeof setInterval> | null = null;
	let amrapPromptOpen = $state(false);
	let amrapPromptMode = $state<'success' | 'fail'>('success');
	let amrapPromptTargetReps = $state(0);
	let amrapPromptInput = $state('');
	let amrapPromptError = $state('');
	let amrapPromptResolver: ((value: number | null) => void) | null = null;

	function stopSetTimer() {
		if (timerHandle) {
			clearInterval(timerHandle);
			timerHandle = null;
		}
	}

	function restartSetTimer() {
		stopSetTimer();
		timerSeconds = 0;
		timerHandle = setInterval(() => {
			timerSeconds += 1;
		}, 1000);
	}

	const DIGIT_SEGMENTS: Record<string, string> = {
		'0': 'abcdef',
		'1': 'bc',
		'2': 'abdeg',
		'3': 'abcdg',
		'4': 'bcfg',
		'5': 'acdfg',
		'6': 'acdefg',
		'7': 'abc',
		'8': 'abcdefg',
		'9': 'abcdfg'
	};

	function formatTimer(seconds: number): string {
		const mins = Math.floor(seconds / 60);
		const secs = seconds % 60;
		return `${String(mins).padStart(2, '0')}:${String(secs).padStart(2, '0')}`;
	}

	function isSegmentOn(glyph: string, segment: string): boolean {
		return (DIGIT_SEGMENTS[glyph] ?? '').includes(segment);
	}

	function currentPendingSet(session: WorkoutSession | null = activeSession): PendingSetContext | null {
		if (!session) return null;
		for (const entry of session.entries) {
			for (const setItem of entry.sets) {
				if (setItem.completed) continue;
				return {
					entry,
					setItem,
					targetReps: setItem.targetReps ?? entry.plannedReps,
					weightKg: setItem.weightKg ?? entry.plannedWeightKg
				};
			}
		}
		return null;
	}

	function workoutPreviewRows(): WorkoutPreviewRow[] {
		if (activeSession) {
			return activeSession.entries.map((entry) => ({
				name: entry.exerciseName,
				sets: entry.plannedSets,
				reps: entry.plannedReps,
				weightKg: entry.plannedWeightKg,
				tier: null
			}));
		}

		if (!activePlan || activePlan.workouts.length === 0) return [];
		const index = Math.min(
			Math.max(activePlan.currentWorkoutIndex, 0),
			activePlan.workouts.length - 1
		);
		const workout = activePlan.workouts[index];
		return workout.exercises.map((exercise) => ({
			name: exercise.exerciseName,
			sets: exercise.sets,
			reps: exercise.reps,
			weightKg: exercise.targetWeightKg,
			tier: exercise.tier
		}));
	}

	function upcomingWorkoutName(): string | null {
		if (!activePlan || activePlan.workouts.length === 0) return null;
		const index = Math.min(
			Math.max(activePlan.currentWorkoutIndex, 0),
			activePlan.workouts.length - 1
		);
		return activePlan.workouts[index]?.name ?? null;
	}

	function syncSessionUiState() {
		if (typeof document === 'undefined') return;
		document.body.classList.toggle('session-active-workout', Boolean(activeSession));
	}

	async function loadWorkoutPage() {
		const [plan, dash, session] = await Promise.all([
			fetchActivePlan(),
			fetchDashboard(),
			fetchActiveSession()
		]);
		activePlan = plan;
		dashboard = dash;
		activeSession = session;
		syncSessionUiState();
	}

	async function runAction<T>(action: () => Promise<T>, okMessage?: string): Promise<T | undefined> {
		loading = true;
		errorMessage = '';
		try {
			const result = await action();
			await loadWorkoutPage();
			if (okMessage) {
				infoMessage = okMessage;
				pushToast(okMessage, 'success');
			}
			return result;
		} catch (error) {
			errorMessage = error instanceof Error ? error.message : String(error);
			pushToast(errorMessage, 'error');
			return undefined;
		} finally {
			loading = false;
		}
	}

	function showFinishAndStravaToast(
		result: WorkoutSession | undefined,
		baseMessage: string
	) {
		if (!result) return;
		const status = result.stravaExportStatus;
		if (status === 'SENT') {
			infoMessage = result.stravaActivityUrl
				? `${baseMessage} · Strava upload succeeded (${result.stravaActivityUrl})`
				: `${baseMessage} · Strava upload succeeded`;
			pushToast(infoMessage, 'success');
			return;
		}
		if (status === 'FAILED') {
			errorMessage = result.stravaLastError
				? `${baseMessage} · Strava upload failed: ${result.stravaLastError}`
				: `${baseMessage} · Strava upload failed`;
			pushToast(errorMessage, 'error');
			return;
		}
		infoMessage = baseMessage;
		pushToast(baseMessage, 'success');
	}

	function openAmrapPrompt(
		targetReps: number,
		mode: 'success' | 'fail'
	): Promise<number | null> {
		amrapPromptOpen = true;
		amrapPromptMode = mode;
		amrapPromptTargetReps = targetReps;
		amrapPromptInput = mode === 'success' ? String(targetReps) : String(Math.max(0, targetReps - 1));
		amrapPromptError = '';
		return new Promise((resolve) => {
			amrapPromptResolver = resolve;
		});
	}

	function closeAmrapPrompt(value: number | null) {
		amrapPromptOpen = false;
		const resolve = amrapPromptResolver;
		amrapPromptResolver = null;
		if (resolve) resolve(value);
	}

	function submitAmrapPrompt() {
		try {
			const reps = parseNonNegativeInt(amrapPromptInput, 'AMRAP reps');
			if (amrapPromptMode === 'success' && reps < amrapPromptTargetReps) {
				throw new Error(`AMRAP reps must be >= ${amrapPromptTargetReps}`);
			}
			if (amrapPromptMode === 'fail' && reps >= amrapPromptTargetReps) {
				throw new Error(`AMRAP reps must be < ${amrapPromptTargetReps} for a failed set`);
			}
			closeAmrapPrompt(reps);
		} catch (error) {
			amrapPromptError = error instanceof Error ? error.message : String(error);
		}
	}

	async function submitCurrentSet(mode: 'success' | 'fail') {
		const current = currentPendingSet();
		if (!current) return;

		let reps = current.targetReps;
		if (current.setItem.isAmrap) {
			const amrapReps = await openAmrapPrompt(current.targetReps, mode);
			if (amrapReps === null) return;
			reps = amrapReps;
		} else if (mode === 'fail') {
			reps = Math.max(0, current.targetReps - 1);
		}

		const durationSeconds = Math.max(0, timerSeconds);
		await runAction(() =>
			completeSet({
				sessionSetId: current.setItem.id,
				repsCompleted: reps,
				weightKg: current.weightKg,
				durationSeconds
			})
		);

		const sessionAfter = activeSession;
		const pendingAfter = currentPendingSet(sessionAfter);
		if (sessionAfter && !pendingAfter) {
			const finishResult = await runAction(() => finishWorkout(sessionAfter.id));
			showFinishAndStravaToast(finishResult, 'Workout finished');
			stopSetTimer();
			return;
		}

		if (activeSession) restartSetTimer();
	}

	async function onStartWorkout() {
		await runAction(() => startWorkout(), 'Workout started');
		if (activeSession) restartSetTimer();
	}

	async function onExitWorkoutEarly() {
		const session = activeSession;
		if (!session) return;
		const finishResult = await runAction(() => finishWorkout(session.id));
		showFinishAndStravaToast(finishResult, 'Workout ended early');
		stopSetTimer();
	}

	function currentSetExerciseName(): string {
		const current = currentPendingSet();
		if (!current) return 'Completing workout…';
		return current.entry.exerciseName;
	}

	function currentSetTargetLine(): string {
		const current = currentPendingSet();
		if (!current) return '';
		const repTarget = `${current.targetReps}${current.setItem.isAmrap ? '+' : ''}`;
		return `${repTarget} Reps @ ${displayWeightFromKg(current.weightKg, weightUnit)} ${weightUnitLabel(weightUnit)}`;
	}

	function currentExpectedRestSeconds(): number {
		const current = currentPendingSet();
		if (!current) return 90;
		return current.entry.expectedRestSeconds ?? 90;
	}

	function currentRestState(): 'ok' | 'warn' | 'over' {
		const expected = currentExpectedRestSeconds();
		if (timerSeconds > expected) return 'over';
		if (timerSeconds >= Math.max(0, expected - 15)) return 'warn';
		return 'ok';
	}

	function formatRestTargetLabel(seconds: number): string {
		const mins = Math.floor(seconds / 60);
		const secs = seconds % 60;
		return `${String(mins).padStart(2, '0')}:${String(secs).padStart(2, '0')}`;
	}

	onMount(() => {
		weightUnit = getPreferredWeightUnit();
		const offWeightUnit = onWeightUnitChange((unit) => {
			weightUnit = unit;
		});

		(async () => {
			loading = true;
			try {
				await loadWorkoutPage();
				if (activeSession) restartSetTimer();
			} catch (error) {
				errorMessage = error instanceof Error ? error.message : String(error);
			} finally {
				loading = false;
			}
		})();

		return () => {
			stopSetTimer();
			if (amrapPromptResolver) {
				amrapPromptResolver(null);
				amrapPromptResolver = null;
			}
			if (typeof document !== 'undefined') {
				document.body.classList.remove('session-active-workout');
			}
			offWeightUnit();
		};
	});
</script>

{#if activeSession}
	<section class="card session-overlay">
		<button class="exit-btn" onclick={onExitWorkoutEarly} disabled={loading}>Exit</button>
		<div class="timer-panel">
			<div
				class="segment-clock"
				class:rest-warn={currentRestState() === 'warn'}
				class:rest-over={currentRestState() === 'over'}
				aria-label={`Timer ${formatTimer(timerSeconds)}`}
			>
				{#each formatTimer(timerSeconds).split('') as glyph}
					{#if glyph === ':'}
						<div class="segment-colon" aria-hidden="true">
							<span></span>
							<span></span>
						</div>
					{:else}
						<div class="segment-digit" aria-hidden="true">
							<span class="seg a" class:on={isSegmentOn(glyph, 'a')}></span>
							<span class="seg b" class:on={isSegmentOn(glyph, 'b')}></span>
							<span class="seg c" class:on={isSegmentOn(glyph, 'c')}></span>
							<span class="seg d" class:on={isSegmentOn(glyph, 'd')}></span>
							<span class="seg e" class:on={isSegmentOn(glyph, 'e')}></span>
							<span class="seg f" class:on={isSegmentOn(glyph, 'f')}></span>
							<span class="seg g" class:on={isSegmentOn(glyph, 'g')}></span>
						</div>
					{/if}
				{/each}
			</div>
		</div>
		<p class="rest-target" class:warn={currentRestState() === 'warn'} class:over={currentRestState() === 'over'}>
			Rest target {formatRestTargetLabel(currentExpectedRestSeconds())}
		</p>
		<p class="set-description">
			<span class="set-exercise">{currentSetExerciseName()}</span>
			{#if currentSetTargetLine()}
				<span class="set-target">{currentSetTargetLine()}</span>
			{/if}
		</p>
		<div class="session-actions">
			<div class="action-ring success-ring">
				<button
					type="button"
					class="action-btn success-btn"
					onclick={() => submitCurrentSet('success')}
					disabled={loading || !currentPendingSet()}
					aria-label="Mark set successful"
				>
					✓
				</button>
			</div>
			<div class="action-ring fail-ring">
				<button
					type="button"
					class="action-btn fail-btn"
					onclick={() => submitCurrentSet('fail')}
					disabled={loading || !currentPendingSet()}
					aria-label="Mark set failed"
				>
					✕
				</button>
			</div>
		</div>

		{#if amrapPromptOpen}
			<div class="amrap-backdrop" role="presentation">
				<div class="amrap-modal" role="dialog" aria-modal="true" aria-label="Enter total reps">
					<label>
						<span class="amrap-label">Total reps</span>
						<input
							type="number"
							min="0"
							step="1"
							bind:value={amrapPromptInput}
							disabled={loading}
							onkeydown={(e) => {
								if (e.key === 'Enter') submitAmrapPrompt();
								if (e.key === 'Escape') closeAmrapPrompt(null);
							}}
						/>
					</label>
					{#if amrapPromptError}
						<p class="banner error amrap-error">{amrapPromptError}</p>
					{/if}
					<div class="amrap-actions">
						<button type="button" onclick={() => closeAmrapPrompt(null)} disabled={loading}>Cancel</button>
						<button type="button" class="primary" onclick={submitAmrapPrompt} disabled={loading}>
							Save
						</button>
					</div>
				</div>
			</div>
		{/if}
	</section>
{:else}
	<section class="card hero">
		{#if activePlan}
			<div class="hero-head">
				<h1>Workout</h1>
				<div class="hero-identifiers">
					<div><span class="subtle">Plan</span> <strong>{activePlan.name}</strong></div>
					<div><span class="subtle">Week</span> <strong>{activePlan.currentWeek}</strong></div>
					<div><strong>{upcomingWorkoutName() ?? '—'}</strong></div>
				</div>
			</div>
			<div class="hero-body">
				<div class="preview-list-wrap">
					{#if workoutPreviewRows().length === 0}
						<p class="subtle">No exercises found for this day yet.</p>
					{:else}
						<ul class="preview-list">
							{#each workoutPreviewRows() as row}
								<li>
									<strong>{row.name}</strong>
									<span class="subtle">
										{row.sets}×{row.reps} @ {displayWeightFromKg(row.weightKg, weightUnit)}
										{weightUnitLabel(weightUnit)}
										{#if row.tier} · {row.tier}{/if}
									</span>
								</li>
							{/each}
						</ul>
					{/if}
				</div>
				<div class="hero-action">
					<div class="play-ring">
						<button
							type="button"
							class="primary play-btn"
							onclick={onStartWorkout}
							disabled={loading}
							aria-label="Start workout"
							title="Start workout"
						>
							▶
						</button>
					</div>
				</div>
			</div>
		{:else}
			<div>
				<h1>Workout</h1>
				<p class="subtle">No active plan. Create one first.</p>
			</div>
			<a class="link-btn" href="/plan">Create Plan</a>
		{/if}
	</section>

	{#if infoMessage}
		<p class="banner success">{infoMessage}</p>
	{/if}
	{#if errorMessage}
		<p class="banner error">{errorMessage}</p>
	{/if}

	{#if dashboard?.status && dashboard.status.needsNew1rmExercises.length > 0}
		<section class="card">
			<h2>1RM update required</h2>
			<p>
				Update 1RM before continuing: <strong>{dashboard.status.needsNew1rmExercises.join(', ')}</strong>
			</p>
			<p class="subtle">Go to Settings to update 1RM values.</p>
		</section>
	{/if}
{/if}

<style>
	.session-overlay {
		position: relative;
		width: min(100%, 760px);
		margin: 0 auto;
		display: grid;
		grid-template-rows: 1fr auto auto;
		justify-items: center;
		align-items: center;
		gap: 1rem;
		min-height: clamp(520px, 82vh, 760px);
		padding: 1rem 1rem 1.4rem;
		text-align: center;
	}

	.exit-btn {
		position: absolute;
		top: 0.9rem;
		right: 0.9rem;
		padding: 0.35rem 0.6rem;
		font-size: 0.85rem;
	}

	.timer-panel {
		width: 100%;
		min-height: 50%;
		display: grid;
		place-items: center;
		padding: clamp(0.9rem, 2.5vw, 1.4rem) clamp(0.6rem, 2vw, 1rem);
	}

	.segment-clock {
		display: flex;
		align-items: center;
		justify-content: center;
		gap: clamp(0.3rem, 1.8vw, 0.85rem);
		--timer-on: #b6ff9f;
		--timer-glow-a: rgba(182, 255, 159, 0.55);
		--timer-glow-b: rgba(34, 197, 94, 0.45);
		--timer-off: rgba(182, 255, 159, 0.1);
	}

	.segment-clock.rest-warn {
		--timer-on: #f59e0b;
		--timer-glow-a: rgba(245, 158, 11, 0.55);
		--timer-glow-b: rgba(251, 191, 36, 0.45);
		--timer-off: rgba(245, 158, 11, 0.12);
	}

	.segment-clock.rest-over {
		--timer-on: #ef4444;
		--timer-glow-a: rgba(239, 68, 68, 0.55);
		--timer-glow-b: rgba(248, 113, 113, 0.45);
		--timer-off: rgba(239, 68, 68, 0.13);
	}

	.segment-digit {
		position: relative;
		width: clamp(2.8rem, 14vw, 5.4rem);
		height: clamp(4.8rem, 24vw, 9rem);
		--seg-thick: clamp(0.32rem, 1.5vw, 0.7rem);
		--seg-pad: clamp(0.22rem, 1vw, 0.42rem);
	}

	.seg {
		position: absolute;
		background: var(--timer-off);
		border-radius: 999px;
		opacity: 0.28;
	}

	.seg.on {
		background: var(--timer-on);
		opacity: 1;
		box-shadow:
			0 0 7px var(--timer-glow-a),
			0 0 14px var(--timer-glow-b);
	}

	.seg.a,
	.seg.g,
	.seg.d {
		left: var(--seg-pad);
		right: var(--seg-pad);
		height: var(--seg-thick);
	}

	.seg.a {
		top: 0;
	}

	.seg.g {
		top: calc(50% - (var(--seg-thick) / 2));
	}

	.seg.d {
		top: calc(100% - var(--seg-thick));
	}

	.seg.f,
	.seg.e,
	.seg.b,
	.seg.c {
		width: var(--seg-thick);
	}

	.seg.f,
	.seg.b {
		top: var(--seg-pad);
		height: calc(50% - var(--seg-pad) - (var(--seg-thick) / 2));
	}

	.seg.e,
	.seg.c {
		top: calc(50% + (var(--seg-thick) / 2));
		height: calc(50% - var(--seg-pad) - (var(--seg-thick) / 2));
	}

	.seg.f,
	.seg.e {
		left: 0;
	}

	.seg.b,
	.seg.c {
		right: 0;
	}

	.segment-colon {
		display: grid;
		gap: clamp(0.6rem, 2.8vw, 1.15rem);
		justify-items: center;
	}

	.segment-colon span {
		width: clamp(0.35rem, 1.8vw, 0.7rem);
		height: clamp(0.35rem, 1.8vw, 0.7rem);
		border-radius: 999px;
		background: var(--timer-on);
		box-shadow:
			0 0 6px var(--timer-glow-a),
			0 0 12px var(--timer-glow-b);
	}

	.rest-target {
		margin: 0;
		font-size: 0.95rem;
		color: #94a3b8;
	}

	.rest-target.warn {
		color: #f59e0b;
	}

	.rest-target.over {
		color: #ef4444;
	}

	.set-description {
		margin: 0;
		display: grid;
		gap: 0.25rem;
		color: #e2e8f0;
	}

	.set-exercise {
		font-size: clamp(1.35rem, 5.2vw, 2.1rem);
		font-weight: 700;
		line-height: 1.1;
	}

	.set-target {
		font-size: clamp(1.02rem, 4.1vw, 1.45rem);
		line-height: 1.2;
		color: #cbd5e1;
	}

	.session-actions {
		width: min(100%, 500px);
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 1rem;
		margin-top: auto;
	}

	.action-ring {
		padding: 4px;
		border-radius: 999px;
	}

	.success-ring {
		border: 5px solid #16a34a;
	}

	.fail-ring {
		border: 5px solid #dc2626;
	}

	.action-btn {
		width: 5.25rem;
		height: 5.25rem;
		padding: 0;
		border-radius: 999px;
		font-size: 2rem;
		font-weight: 700;
		display: inline-flex;
		align-items: center;
		justify-content: center;
	}

	.success-btn {
		background: #16a34a;
		border-color: #15803d;
	}

	.fail-btn {
		background: #dc2626;
		border-color: #b91c1c;
	}

	.amrap-backdrop {
		position: absolute;
		inset: 0;
		background: rgba(2, 6, 23, 0.72);
		display: grid;
		place-items: center;
		padding: 1rem;
		z-index: 20;
	}

	.amrap-modal {
		width: min(100%, 320px);
		background: #111827;
		border: 1px solid #334155;
		border-radius: 12px;
		padding: 0.85rem;
		display: grid;
		gap: 0.7rem;
		text-align: left;
	}

	.amrap-modal label {
		display: grid;
		gap: 0.55rem;
	}

	.amrap-label {
		font-size: 1.2rem;
		font-weight: 700;
	}

	.amrap-actions {
		display: flex;
		justify-content: flex-end;
		gap: 0.55rem;
	}

	.amrap-error {
		margin: 0;
	}

	.hero {
		display: grid;
		gap: 1rem;
		width: 100%;
		max-width: 820px;
		margin: 0 auto;
		padding: 1.35rem;
	}

	.hero-head {
		display: flex;
		justify-content: space-between;
		align-items: flex-start;
		gap: 1rem;
		flex-wrap: wrap;
	}

	.hero-identifiers {
		display: grid;
		gap: 0.25rem;
		text-align: right;
		font-size: 0.92rem;
	}

	.hero-body {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 1rem;
		width: 100%;
	}

	.preview-list-wrap {
		flex: 1 1 auto;
		min-width: 0;
	}

	.preview-list {
		margin: 0;
		padding-left: 1rem;
		display: grid;
		gap: 0.4rem;
	}

	.preview-list li {
		display: grid;
		gap: 0.15rem;
	}

	.hero-action {
		display: grid;
		align-items: center;
		justify-items: end;
		margin-left: auto;
	}

	.play-ring {
		border: 5px solid #2563eb;
		padding: 4px;
		border-radius: 999px;
	}

	.play-btn {
		width: 5.25rem;
		height: 5.25rem;
		padding: 0;
		border-radius: 999px;
		font-size: 2rem;
		font-weight: 700;
		display: inline-flex;
		align-items: center;
		justify-content: center;
	}

	.link-btn {
		display: inline-block;
		padding: 0.55rem 0.85rem;
		border-radius: 10px;
		background: #2563eb;
		border: 1px solid #1d4ed8;
		color: #fff;
		text-decoration: none;
	}

	@media (max-width: 760px) {
		.session-overlay {
			position: fixed;
			inset: 0;
			z-index: 40;
			width: 100vw;
			height: 100dvh;
			min-height: 100dvh;
			max-width: none;
			margin: 0;
			padding:
				calc(env(safe-area-inset-top, 0px) + 0.75rem)
				0.85rem
				calc(env(safe-area-inset-bottom, 0px) + 1rem);
			border-radius: 0;
			border: none;
		}

		.exit-btn {
			top: calc(env(safe-area-inset-top, 0px) + 0.5rem);
			right: 0.85rem;
		}

		.hero-identifiers {
			text-align: left;
		}

		.hero-body {
			flex-direction: column;
			align-items: stretch;
		}

		.hero-action {
			justify-items: start;
			margin-left: 0;
		}

		.session-actions {
			width: 100%;
			justify-content: space-around;
		}
	}
</style>
