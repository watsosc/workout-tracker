<script lang="ts">
	import { onMount } from 'svelte';
	import {
		cancelWorkout,
		completeSet,
		fetchActivePlan,
		fetchActiveSession,
		fetchDashboard,
		finishWorkout,
		startWorkout,
		uncompleteSet
	} from '$lib/workout-api';
	import type {
		ActivePlan,
		Dashboard,
		PersonalRecord,
		SessionEntry,
		SessionSet,
		WorkoutSession
	} from '$lib/types';
	import { formatPlates, usesBarbell, warmupSets, type WarmupSet } from '$lib/barbell';
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
	let exitMenuOpen = $state(false);

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

	function lastCompletedSet(session: WorkoutSession | null = activeSession): SessionSet | null {
		if (!session) return null;
		let last: SessionSet | null = null;
		for (const entry of session.entries) {
			for (const setItem of entry.sets) {
				if (setItem.completed) last = setItem;
			}
		}
		return last;
	}

	function displayWeight(weightKg: number): number {
		return Number(displayWeightFromKg(weightKg, weightUnit));
	}

	function currentIsBarbell(): boolean {
		const current = currentPendingSet();
		return Boolean(current && usesBarbell(current.entry.equipmentType, current.entry.tier));
	}

	/** Warm-ups are shown before the first working set of a barbell lift. */
	function currentWarmups(): WarmupSet[] {
		const current = currentPendingSet();
		if (!current || !currentIsBarbell()) return [];
		if (current.entry.sets.some((setItem) => setItem.completed)) return [];
		return warmupSets(displayWeight(current.weightKg), weightUnit);
	}

	function describeRecord(pr: PersonalRecord): string {
		const value = `${displayWeightFromKg(pr.valueKg, weightUnit)} ${weightUnitLabel(weightUnit)}`;
		return pr.kind === 'WEIGHT'
			? `${pr.exerciseName} heaviest: ${value} × ${pr.reps}`
			: `${pr.exerciseName} est. 1RM: ${value}`;
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

	function showPersonalRecordToasts(result: WorkoutSession | undefined) {
		for (const pr of result?.personalRecords ?? []) {
			pushToast(`🏆 New PR · ${describeRecord(pr)}`, 'success');
		}
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

		// When the last set is logged we stop here (rather than auto-finishing) so a mistaken
		// final set can still be undone before progression is applied.
		if (activeSession && !currentPendingSet()) {
			stopSetTimer();
			return;
		}
		if (activeSession) restartSetTimer();
	}

	async function onUndoLastSet() {
		const last = lastCompletedSet();
		if (!last) return;
		await runAction(() => uncompleteSet(last.id), 'Set undone');
		if (activeSession && !timerHandle) restartSetTimer();
	}

	async function onFinishWorkout(message: string) {
		const session = activeSession;
		if (!session) return;
		exitMenuOpen = false;
		const finishResult = await runAction(() => finishWorkout(session.id));
		showFinishAndStravaToast(finishResult, message);
		showPersonalRecordToasts(finishResult);
		stopSetTimer();
	}

	async function onDiscardWorkout() {
		const session = activeSession;
		if (!session) return;
		if (!window.confirm('Discard this workout? Logged sets are thrown away and the plan does not advance.')) {
			return;
		}
		exitMenuOpen = false;
		await runAction(() => cancelWorkout(session.id), 'Workout discarded');
		stopSetTimer();
	}

	async function onStartWorkout() {
		await runAction(() => startWorkout(), 'Workout started');
		if (activeSession) restartSetTimer();
	}

	function currentSetExerciseName(): string {
		const current = currentPendingSet();
		if (!current) return 'All sets complete';
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
				pushToast(errorMessage, 'error');
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
		<button class="exit-btn" onclick={() => (exitMenuOpen = true)} disabled={loading}>Exit</button>
		{#if lastCompletedSet()}
			<button class="undo-btn" onclick={onUndoLastSet} disabled={loading} title="Undo the last logged set">
				↶ Undo set
			</button>
		{/if}
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
			{#if currentIsBarbell()}
				<span class="plate-line">{formatPlates(displayWeight(currentPendingSet()?.weightKg ?? 0), weightUnit)}</span>
			{/if}
		</p>
		{#if currentWarmups().length > 0}
			<div class="warmups">
				<span class="warmups-title">Warm-up</span>
				<ul>
					{#each currentWarmups() as warmup}
						<li>
							<strong>{warmup.weight} {weightUnitLabel(weightUnit)} × {warmup.reps}</strong>
							<span class="subtle">{formatPlates(warmup.weight, weightUnit)}</span>
						</li>
					{/each}
				</ul>
			</div>
		{/if}
		{#if !currentPendingSet()}
			<div class="complete-actions">
				<button type="button" class="primary finish-btn" onclick={() => onFinishWorkout('Workout finished')} disabled={loading}>
					Finish workout
				</button>
				<p class="subtle">Logged a set wrong? Use Undo before finishing.</p>
			</div>
		{/if}
		<div class="session-actions" class:hidden={!currentPendingSet()}>
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

		{#if exitMenuOpen}
			<div class="amrap-backdrop" role="presentation">
				<div class="amrap-modal" role="dialog" aria-modal="true" aria-label="Exit workout">
					<span class="amrap-label">Exit workout</span>
					<button type="button" class="primary" onclick={() => onFinishWorkout('Workout ended early')} disabled={loading}>
						Finish now (save &amp; progress)
					</button>
					<button type="button" class="danger" onclick={onDiscardWorkout} disabled={loading}>
						Discard workout
					</button>
					<button type="button" onclick={() => (exitMenuOpen = false)} disabled={loading}>Keep going</button>
				</div>
			</div>
		{/if}

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
				<p class="subtle">No active plan. Create a plan or activate an existing one.</p>
			</div>
			<a class="link-btn" href="/plan">Manage Plans</a>
		{/if}
	</section>

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

	.undo-btn {
		position: absolute;
		top: 0.9rem;
		left: 0.9rem;
		padding: 0.35rem 0.6rem;
		font-size: 0.85rem;
	}

	.plate-line {
		font-size: 0.95rem;
		color: #94a3b8;
	}

	.warmups {
		width: min(100%, 420px);
		text-align: left;
		border: 1px solid #1f2937;
		border-radius: 10px;
		padding: 0.55rem 0.8rem;
	}

	.warmups-title {
		font-size: 0.8rem;
		text-transform: uppercase;
		letter-spacing: 0.05em;
		color: #94a3b8;
	}

	.warmups ul {
		margin: 0.3rem 0 0;
		padding: 0;
		list-style: none;
		display: grid;
		gap: 0.2rem;
	}

	.warmups li {
		display: flex;
		justify-content: space-between;
		gap: 0.8rem;
	}

	.complete-actions {
		display: grid;
		gap: 0.4rem;
		justify-items: center;
	}

	.finish-btn {
		font-size: 1.2rem;
		padding: 0.8rem 1.6rem;
	}

	.session-actions.hidden {
		display: none;
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

		.undo-btn {
			top: calc(env(safe-area-inset-top, 0px) + 0.5rem);
			left: 0.85rem;
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
