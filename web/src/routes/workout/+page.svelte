<script lang="ts">
	import { onMount } from 'svelte';
	import {
		addExerciseToWorkout,
		addSet,
		cancelWorkout,
		completeSet,
		fetchActivePlan,
		fetchActiveSession,
		fetchDashboard,
		fetchExerciseNames,
		finishWorkout,
		skipExercise,
		startEmptyWorkout,
		startWorkout,
		swapExercise,
		uncompleteSet,
		unskipExercise
	} from '$lib/workout-api';
	import type { ActivePlan, Dashboard, PersonalRecord, WorkoutSession } from '$lib/types';
	import { pushToast } from '$lib/toast';
	import { formatPlates, usesBarbell, warmupSets, type WarmupSet } from '$lib/barbell';
	import {
		entryStatus,
		lastCompletedSet,
		pendingSet,
		validateReps,
		type PendingSet
	} from '$lib/workout-logic';
	import {
		convertUnitToKg,
		displayWeightFromKg,
		getPreferredWeightUnit,
		onWeightUnitChange,
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

	type PromptRequest = {
		title: string;
		inputType: 'number' | 'text';
		initial: string;
		hint?: string;
		validate: (value: string) => string | null;
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
	let exitMenuOpen = $state(false);
	let exercisesOpen = $state(false);
	let exerciseNames = $state<string[]>([]);
	/** Weight chosen for an exercise during this workout (entry id -> kg). */
	let weightOverrides = $state<Record<number, number>>({});

	let prompt = $state<PromptRequest | null>(null);
	let promptValue = $state('');
	let promptError = $state('');
	let promptResolver: ((value: string | null) => void) | null = null;

	let addName = $state('');
	let addSets = $state('3');
	let addReps = $state('10');
	let addWeight = $state('0');

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

	function current(): PendingSet | null {
		return pendingSet(activeSession, weightOverrides);
	}

	function displayWeight(weightKg: number): number {
		return Number(displayWeightFromKg(weightKg, weightUnit));
	}

	function unitLabel(): string {
		return weightUnitLabel(weightUnit);
	}

	function currentIsBarbell(): boolean {
		const c = current();
		return Boolean(c && usesBarbell(c.entry.equipmentType, c.entry.tier));
	}

	/** Warm-ups are shown before the first working set of a barbell lift. */
	function currentWarmups(): WarmupSet[] {
		const c = current();
		if (!c || !currentIsBarbell()) return [];
		if (c.entry.sets.some((setItem) => setItem.completed)) return [];
		return warmupSets(displayWeight(c.weightKg), weightUnit);
	}

	function describeRecord(pr: PersonalRecord): string {
		const value = `${displayWeightFromKg(pr.valueKg, weightUnit)} ${unitLabel()}`;
		return pr.kind === 'WEIGHT'
			? `${pr.exerciseName} heaviest: ${value} × ${pr.reps}`
			: `${pr.exerciseName} est. 1RM: ${value}`;
	}

	function workoutPreviewRows(): WorkoutPreviewRow[] {
		if (!activePlan || activePlan.workouts.length === 0) return [];
		const index = Math.min(Math.max(activePlan.currentWorkoutIndex, 0), activePlan.workouts.length - 1);
		return activePlan.workouts[index].exercises.map((exercise) => ({
			name: exercise.exerciseName,
			sets: exercise.sets,
			reps: exercise.reps,
			weightKg: exercise.targetWeightKg,
			tier: exercise.tier
		}));
	}

	function upcomingWorkoutName(): string | null {
		if (!activePlan || activePlan.workouts.length === 0) return null;
		const index = Math.min(Math.max(activePlan.currentWorkoutIndex, 0), activePlan.workouts.length - 1);
		return activePlan.workouts[index]?.name ?? null;
	}

	function syncSessionUiState() {
		if (typeof document === 'undefined') return;
		document.body.classList.toggle('session-active-workout', Boolean(activeSession));
	}

	async function loadWorkoutPage() {
		const [plan, dash, session] = await Promise.all([fetchActivePlan(), fetchDashboard(), fetchActiveSession()]);
		activePlan = plan;
		dashboard = dash;
		activeSession = session;
		if (!session) weightOverrides = {};
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

	function showFinishAndStravaToast(result: WorkoutSession | undefined, baseMessage: string) {
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

	// ------------------------------------------------------------ generic prompt dialog

	function openPrompt(request: PromptRequest): Promise<string | null> {
		prompt = request;
		promptValue = request.initial;
		promptError = '';
		return new Promise((resolve) => {
			promptResolver = resolve;
		});
	}

	function closePrompt(value: string | null) {
		prompt = null;
		const resolve = promptResolver;
		promptResolver = null;
		resolve?.(value);
	}

	function submitPrompt() {
		if (!prompt) return;
		const problem = prompt.validate(String(promptValue).trim());
		if (problem) {
			promptError = problem;
			return;
		}
		closePrompt(String(promptValue).trim());
	}

	function validateWeight(value: string): string | null {
		const n = Number(value);
		return Number.isFinite(n) && n >= 0 ? null : 'Enter a weight of 0 or more';
	}

	// ------------------------------------------------------------ set actions

	async function submitCurrentSet(mode: 'success' | 'fail') {
		const c = current();
		if (!c) return;

		let reps = c.targetReps;
		if (c.setItem.isAmrap || mode === 'fail') {
			const raw = await openPrompt({
				title: mode === 'fail' ? 'Reps completed' : 'Total reps',
				hint: mode === 'fail' ? `Target was ${c.targetReps}` : `At least ${c.targetReps}`,
				inputType: 'number',
				initial: String(mode === 'fail' ? Math.max(0, c.targetReps - 1) : c.targetReps),
				validate: (v) => validateReps(v, c.targetReps, mode, c.setItem.isAmrap)
			});
			if (raw === null) return;
			reps = Number(raw);
		}

		const durationSeconds = Math.max(0, timerSeconds);
		await runAction(() =>
			completeSet({ sessionSetId: c.setItem.id, repsCompleted: reps, weightKg: c.weightKg, durationSeconds })
		);

		// After the last set we stop here (no auto-finish) so a mistaken set can still be undone.
		if (activeSession && !current()) {
			stopSetTimer();
			return;
		}
		if (activeSession) restartSetTimer();
	}

	async function onChangeWeight() {
		const c = current();
		if (!c) return;
		const raw = await openPrompt({
			title: `Weight for ${c.entry.exerciseName} (${unitLabel()})`,
			hint: 'Applies to the remaining sets of this exercise',
			inputType: 'number',
			initial: displayWeightFromKg(c.weightKg, weightUnit),
			validate: validateWeight
		});
		if (raw === null) return;
		weightOverrides = { ...weightOverrides, [c.entry.id]: convertUnitToKg(Number(raw), weightUnit) };
	}

	async function onUndoLastSet() {
		const last = lastCompletedSet(activeSession);
		if (!last) return;
		await runAction(() => uncompleteSet(last.id), 'Set undone');
		if (activeSession && !timerHandle) restartSetTimer();
	}

	// ------------------------------------------------------------ exercise changes

	async function onSkip(entryId: number) {
		await runAction(() => skipExercise(entryId), 'Exercise skipped');
	}

	async function onUnskip(entryId: number) {
		await runAction(() => unskipExercise(entryId));
		if (activeSession && !timerHandle) restartSetTimer();
	}

	async function onAddSet(entryId: number) {
		await runAction(() => addSet(entryId), 'Set added');
		if (activeSession && !timerHandle) restartSetTimer();
	}

	async function onSwap(entryId: number, currentName: string) {
		const name = await openPrompt({
			title: `Swap ${currentName} for…`,
			hint: "Swapped exercises are logged but don't change the plan's progression",
			inputType: 'text',
			initial: '',
			validate: (v) => (v ? null : 'Enter an exercise name')
		});
		if (name === null) return;
		const { [entryId]: _dropped, ...rest } = weightOverrides;
		weightOverrides = rest;
		await runAction(() => swapExercise(entryId, name), `Swapped to ${name}`);
	}

	async function onAddExercise(event: SubmitEvent) {
		event.preventDefault();
		const session = activeSession;
		if (!session) return;
		const sets = Number(addSets);
		const reps = Number(addReps);
		const weight = Number(addWeight);
		if (!addName.trim()) return pushToast('Enter an exercise name', 'error');
		if (!Number.isInteger(sets) || sets < 1 || !Number.isInteger(reps) || reps < 1 || !(weight >= 0)) {
			return pushToast('Use whole numbers for sets/reps and a weight of 0 or more', 'error');
		}
		const added = await runAction(
			() =>
				addExerciseToWorkout({
					sessionId: session.id,
					exerciseName: addName.trim(),
					sets,
					reps,
					weightKg: convertUnitToKg(weight, weightUnit)
				}),
			`Added ${addName.trim()}`
		);
		if (added) {
			addName = '';
			if (!timerHandle) restartSetTimer();
		}
	}

	async function openExercises() {
		exercisesOpen = true;
		if (exerciseNames.length === 0) {
			exerciseNames = await fetchExerciseNames().catch(() => []);
		}
	}

	// ------------------------------------------------------------ start / finish

	async function onStartWorkout() {
		weightOverrides = {};
		await runAction(() => startWorkout(), 'Workout started');
		if (activeSession) restartSetTimer();
	}

	async function onStartEmptyWorkout() {
		const name = await openPrompt({
			title: 'Name this workout',
			hint: "Empty workouts aren't part of your plan; add exercises as you go",
			inputType: 'text',
			initial: 'Workout',
			validate: (v) => (v ? null : 'Enter a name')
		});
		if (name === null) return;
		weightOverrides = {};
		await runAction(() => startEmptyWorkout(name), 'Workout started');
		if (activeSession) {
			restartSetTimer();
			await openExercises();
		}
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

	// ------------------------------------------------------------ display helpers

	function currentSetExerciseName(): string {
		const c = current();
		if (!c) return 'All sets complete';
		return c.entry.exerciseName;
	}

	function currentSetTargetLine(): string {
		const c = current();
		if (!c) return '';
		const repTarget = `${c.targetReps}${c.setItem.isAmrap ? '+' : ''}`;
		return `Set ${c.setItem.setIndex}/${c.entry.sets.length} · ${repTarget} reps @ ${displayWeightFromKg(c.weightKg, weightUnit)} ${unitLabel()}`;
	}

	function currentExpectedRestSeconds(): number {
		return current()?.entry.expectedRestSeconds ?? 90;
	}

	function currentRestState(): 'ok' | 'warn' | 'over' {
		const expected = currentExpectedRestSeconds();
		if (timerSeconds > expected) return 'over';
		if (timerSeconds >= Math.max(0, expected - 15)) return 'warn';
		return 'ok';
	}

	function statusLabel(status: ReturnType<typeof entryStatus>): string {
		return { done: 'Done', skipped: 'Skipped', 'in-progress': 'In progress', todo: 'To do' }[status];
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
			promptResolver?.(null);
			promptResolver = null;
			if (typeof document !== 'undefined') {
				document.body.classList.remove('session-active-workout');
			}
			offWeightUnit();
		};
	});
</script>

{#if activeSession}
	<section class="card session-overlay">
		<div class="session-toolbar">
			{#if lastCompletedSet(activeSession)}
				<button onclick={onUndoLastSet} disabled={loading} title="Undo the last logged set">↶ Undo set</button>
			{:else}
				<span></span>
			{/if}
			<span class="session-name">{activeSession.planWorkoutName}</span>
			<div class="toolbar-right">
				<button onclick={openExercises} disabled={loading}>Exercises</button>
				<button onclick={() => (exitMenuOpen = true)} disabled={loading}>Exit</button>
			</div>
		</div>
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
			Rest target {formatTimer(currentExpectedRestSeconds())}
		</p>
		<p class="set-description">
			<span class="set-exercise">{currentSetExerciseName()}</span>
			{#if currentSetTargetLine()}
				<span class="set-target">{currentSetTargetLine()}</span>
				<span class="set-tools">
					<button type="button" class="link" onclick={onChangeWeight} disabled={loading}>Change weight</button>
					{#if currentIsBarbell()}
						<span class="plate-line">{formatPlates(displayWeight(current()?.weightKg ?? 0), weightUnit)}</span>
					{/if}
				</span>
			{/if}
		</p>
		{#if currentWarmups().length > 0}
			<div class="warmups">
				<span class="warmups-title">Warm-up</span>
				<ul>
					{#each currentWarmups() as warmup}
						<li>
							<strong>{warmup.weight} {unitLabel()} × {warmup.reps}</strong>
							<span class="subtle">{formatPlates(warmup.weight, weightUnit)}</span>
						</li>
					{/each}
				</ul>
			</div>
		{/if}
		{#if !current()}
			<div class="complete-actions">
				<button type="button" class="primary finish-btn" onclick={() => onFinishWorkout('Workout finished')} disabled={loading}>
					Finish workout
				</button>
				<p class="subtle">Logged a set wrong? Undo it before finishing. Need more? Use Exercises.</p>
			</div>
		{/if}
		<div class="session-actions" class:hidden={!current()}>
			<div class="action-ring success-ring">
				<button
					type="button"
					class="action-btn success-btn"
					onclick={() => submitCurrentSet('success')}
					disabled={loading || !current()}
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
					disabled={loading || !current()}
					aria-label="Mark set failed"
				>
					✕
				</button>
			</div>
		</div>

		{#if exercisesOpen}
			<div class="modal-backdrop" role="presentation">
				<div class="modal exercises-modal" role="dialog" aria-modal="true" aria-label="Exercises">
					<div class="modal-head">
						<span class="modal-title">Exercises</span>
						<button type="button" onclick={() => (exercisesOpen = false)}>Close</button>
					</div>
					<ul class="entry-list">
						{#each activeSession.entries as entry (entry.id)}
							{@const status = entryStatus(entry)}
							<li class={`entry-row ${status}`}>
								<div class="entry-info">
									<strong>{entry.exerciseName}</strong>
									<span class="subtle">
										{entry.sets.filter((s) => s.completed).length}/{entry.sets.length} sets · {statusLabel(status)}
										{#if entry.planWorkoutExerciseId === null} · added{/if}
									</span>
								</div>
								<div class="entry-actions">
									{#if status === 'skipped'}
										<button type="button" onclick={() => onUnskip(entry.id)} disabled={loading}>Unskip</button>
									{:else if status !== 'done'}
										<button type="button" onclick={() => onSkip(entry.id)} disabled={loading}>Skip</button>
									{/if}
									<button type="button" onclick={() => onSwap(entry.id, entry.exerciseName)} disabled={loading}>Swap</button>
									<button type="button" onclick={() => onAddSet(entry.id)} disabled={loading}>+ Set</button>
								</div>
							</li>
						{/each}
					</ul>
					<form class="add-exercise" onsubmit={onAddExercise}>
						<span class="modal-subtitle">Add exercise</span>
						<input placeholder="Exercise name" list="exercise-names" bind:value={addName} disabled={loading} />
						<datalist id="exercise-names">
							{#each exerciseNames as name}
								<option value={name}></option>
							{/each}
						</datalist>
						<div class="add-grid">
							<label>Sets <input type="number" min="1" step="1" bind:value={addSets} /></label>
							<label>Reps <input type="number" min="1" step="1" bind:value={addReps} /></label>
							<label>Weight ({unitLabel()}) <input type="number" min="0" step="any" bind:value={addWeight} /></label>
						</div>
						<button type="submit" class="primary" disabled={loading}>Add</button>
					</form>
				</div>
			</div>
		{/if}

		{#if exitMenuOpen}
			<div class="modal-backdrop" role="presentation">
				<div class="modal" role="dialog" aria-modal="true" aria-label="Exit workout">
					<span class="modal-title">Exit workout</span>
					<button type="button" class="primary" onclick={() => onFinishWorkout('Workout ended early')} disabled={loading}>
						Finish now (save &amp; progress)
					</button>
					<button type="button" class="danger" onclick={onDiscardWorkout} disabled={loading}>Discard workout</button>
					<button type="button" onclick={() => (exitMenuOpen = false)} disabled={loading}>Keep going</button>
				</div>
			</div>
		{/if}

		{#if prompt}
			<div class="modal-backdrop prompt-backdrop" role="presentation">
				<div class="modal" role="dialog" aria-modal="true" aria-label={prompt.title}>
					<label>
						<span class="modal-title">{prompt.title}</span>
						{#if prompt.hint}<span class="subtle">{prompt.hint}</span>{/if}
						<!-- svelte-ignore a11y_autofocus -->
						<input
							type={prompt.inputType}
							min={prompt.inputType === 'number' ? 0 : undefined}
							step={prompt.inputType === 'number' ? 'any' : undefined}
							list={prompt.inputType === 'text' ? 'exercise-names-prompt' : undefined}
							autofocus
							bind:value={promptValue}
							disabled={loading}
							onkeydown={(e) => {
								if (e.key === 'Enter') submitPrompt();
								if (e.key === 'Escape') closePrompt(null);
							}}
						/>
						<datalist id="exercise-names-prompt">
							{#each exerciseNames as name}
								<option value={name}></option>
							{/each}
						</datalist>
					</label>
					{#if promptError}
						<p class="banner error modal-error">{promptError}</p>
					{/if}
					<div class="modal-actions">
						<button type="button" onclick={() => closePrompt(null)} disabled={loading}>Cancel</button>
						<button type="button" class="primary" onclick={submitPrompt} disabled={loading}>Save</button>
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
										{unitLabel()}
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
		<button type="button" class="empty-workout-btn" onclick={onStartEmptyWorkout} disabled={loading}>
			Start empty workout
		</button>
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

	{#if prompt}
		<div class="modal-backdrop fixed" role="presentation">
			<div class="modal" role="dialog" aria-modal="true" aria-label={prompt.title}>
				<label>
					<span class="modal-title">{prompt.title}</span>
					{#if prompt.hint}<span class="subtle">{prompt.hint}</span>{/if}
					<!-- svelte-ignore a11y_autofocus -->
					<input
						type={prompt.inputType}
						autofocus
						bind:value={promptValue}
						onkeydown={(e) => {
							if (e.key === 'Enter') submitPrompt();
							if (e.key === 'Escape') closePrompt(null);
						}}
					/>
				</label>
				{#if promptError}
					<p class="banner error modal-error">{promptError}</p>
				{/if}
				<div class="modal-actions">
					<button type="button" onclick={() => closePrompt(null)}>Cancel</button>
					<button type="button" class="primary" onclick={submitPrompt}>Start</button>
				</div>
			</div>
		</div>
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

	.session-overlay {
		padding-top: 3.4rem;
		box-sizing: border-box;
		overflow-x: hidden;
		overflow-y: auto;
	}

	.session-toolbar {
		position: absolute;
		top: 0.75rem;
		left: 0.75rem;
		right: 0.75rem;
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 0.5rem;
	}

	.session-toolbar button {
		padding: 0.35rem 0.6rem;
		font-size: 0.85rem;
	}

	.toolbar-right {
		display: flex;
		gap: 0.4rem;
	}

	.session-name {
		font-size: 0.85rem;
		color: #94a3b8;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.set-tools {
		display: flex;
		justify-content: center;
		align-items: center;
		gap: 0.8rem;
		flex-wrap: wrap;
	}

	button.link {
		background: none;
		border: none;
		padding: 0;
		color: #60a5fa;
		text-decoration: underline;
		font-size: 0.95rem;
	}

	.modal-backdrop.fixed {
		position: fixed;
	}

	.prompt-backdrop {
		z-index: 30;
	}

	.modal label {
		display: grid;
		gap: 0.4rem;
	}

	.modal-head {
		display: flex;
		justify-content: space-between;
		align-items: center;
	}

	.exercises-modal {
		width: min(100%, 520px);
		max-height: 90%;
		overflow-y: auto;
	}

	.modal-subtitle {
		font-weight: 700;
	}

	.entry-list {
		list-style: none;
		margin: 0;
		padding: 0;
		display: grid;
		gap: 0.5rem;
	}

	.entry-row {
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 0.6rem;
		flex-wrap: wrap;
		border: 1px solid #1f2937;
		border-radius: 10px;
		padding: 0.5rem 0.6rem;
	}

	.entry-row.done {
		border-color: #166534;
	}

	.entry-row.skipped {
		opacity: 0.6;
	}

	.entry-info {
		display: grid;
		gap: 0.1rem;
	}

	.entry-actions {
		display: flex;
		gap: 0.35rem;
	}

	.entry-actions button {
		padding: 0.3rem 0.55rem;
		font-size: 0.85rem;
	}

	.add-exercise {
		display: grid;
		gap: 0.5rem;
		border-top: 1px solid #1f2937;
		padding-top: 0.7rem;
	}

	.add-grid {
		display: grid;
		grid-template-columns: repeat(3, 1fr);
		gap: 0.5rem;
	}

	.empty-workout-btn {
		justify-self: start;
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

	.modal-backdrop {
		position: absolute;
		inset: 0;
		background: rgba(2, 6, 23, 0.72);
		display: grid;
		place-items: center;
		padding: 1rem;
		z-index: 20;
	}

	.modal {
		width: min(100%, 320px);
		background: #111827;
		border: 1px solid #334155;
		border-radius: 12px;
		padding: 0.85rem;
		display: grid;
		gap: 0.7rem;
		text-align: left;
	}

	.modal label {
		display: grid;
		gap: 0.55rem;
	}

	.modal-title {
		font-size: 1.2rem;
		font-weight: 700;
	}

	.modal-actions {
		display: flex;
		justify-content: flex-end;
		gap: 0.55rem;
	}

	.modal-error {
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
		.session-toolbar {
			top: calc(env(safe-area-inset-top, 0px) + 0.5rem);
		}

		/* Let the clock shrink so the set details and buttons stay on screen. */
		.timer-panel {
			min-height: 0;
			padding: 0.4rem 0;
		}

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
				calc(env(safe-area-inset-top, 0px) + 3.2rem)
				0.85rem
				calc(env(safe-area-inset-bottom, 0px) + 1rem);
			border-radius: 0;
			border: none;
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
