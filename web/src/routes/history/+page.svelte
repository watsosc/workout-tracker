<script lang="ts">
	import { onMount } from 'svelte';
	import {
		deleteWorkout,
		fetchSessionHeartRateSamples,
		fetchStravaConnection,
		fetchWorkoutHistory,
		fetchWorkoutSession,
		sendWorkoutToStrava,
		updateWorkout
	} from '$lib/workout-api';
	import { pushToast } from '$lib/toast';
	import HeartRateChart from '$lib/components/heart-rate-chart.svelte';
	import type { HeartRateSample, StravaConnection, WorkoutHistoryItem } from '$lib/types';
	import {
		convertUnitToKg,
		displayWeightFromKg,
		formatDate,
		getPreferredWeightUnit,
		onWeightUnitChange,
		type WeightUnit,
		weightUnitLabel
	} from '$lib/ui';

	let loading = $state(false);
	let errorMessage = $state('');
	let infoMessage = $state('');
	let history = $state<WorkoutHistoryItem[]>([]);
	let weightUnit = $state<WeightUnit>('lb');
	let stravaConnection = $state<StravaConnection | null>(null);
	let heartRateBySession = $state<Record<number, HeartRateSample[]>>({});
	let heartRateLoadingBySession = $state<Record<number, boolean>>({});

	function prLabel(item: WorkoutHistoryItem, exerciseName: string): string | null {
		const records = item.personalRecords.filter((pr) => pr.exerciseName === exerciseName);
		if (records.length === 0) return null;
		return records
			.map((pr) => (pr.kind === 'WEIGHT' ? 'Heaviest' : 'Est. 1RM ' + loadLabel(pr.valueKg)))
			.join(' · ');
	}

	function volumeLabel(valueKg: number): string {
		return `${displayWeightFromKg(valueKg, weightUnit)} ${weightUnitLabel(weightUnit)}`;
	}

	function loadLabel(valueKg: number): string {
		return `${displayWeightFromKg(valueKg, weightUnit)} ${weightUnitLabel(weightUnit)}`;
	}

	function formatDuration(seconds: number | null): string {
		if (seconds === null || seconds < 0) return '—';
		const mins = Math.floor(seconds / 60);
		const secs = seconds % 60;
		return `${mins}:${String(secs).padStart(2, '0')}`;
	}

	function setHeartRateLoading(sessionId: number, isLoading: boolean) {
		const next = { ...heartRateLoadingBySession };
		if (isLoading) next[sessionId] = true;
		else delete next[sessionId];
		heartRateLoadingBySession = next;
	}


	async function loadHistory() {
		const [items, strava] = await Promise.all([fetchWorkoutHistory(120), fetchStravaConnection()]);
		history = items;
		stravaConnection = strava;
		heartRateBySession = {};
		heartRateLoadingBySession = {};

		const sessionsWithHr = items.filter((item) => item.heartRateSampleCount > 0).map((item) => item.sessionId);
		await Promise.all(
			sessionsWithHr.map(async (sessionId) => {
				setHeartRateLoading(sessionId, true);
				try {
					const samples = await fetchSessionHeartRateSamples(sessionId, 360);
					heartRateBySession = { ...heartRateBySession, [sessionId]: samples };
				} catch {
					heartRateBySession = { ...heartRateBySession, [sessionId]: [] };
				} finally {
					setHeartRateLoading(sessionId, false);
				}
			})
		);
	}

	type EditRow = {
		id: number;
		exerciseName: string;
		setIndex: number;
		// number inputs bind numbers (or null when empty)
		reps: number | string | null;
		weight: number | string | null;
		completed: boolean;
		originalWeightKg: number | null;
	};
	let editingSessionId = $state<number | null>(null);
	let editRows = $state<EditRow[]>([]);

	async function onEdit(item: WorkoutHistoryItem) {
		loading = true;
		try {
			const session = await fetchWorkoutSession(item.sessionId);
			if (!session) throw new Error('Workout not found');
			editRows = session.entries.flatMap((entry) =>
				entry.sets.map((setItem) => ({
					id: setItem.id,
					exerciseName: entry.exerciseName,
					setIndex: setItem.setIndex,
					reps: setItem.repsCompleted,
					weight: Number(displayWeightFromKg(setItem.weightKg ?? entry.plannedWeightKg, weightUnit)),
					completed: setItem.completed,
					originalWeightKg: setItem.weightKg
				}))
			);
			editingSessionId = item.sessionId;
		} catch (error) {
			pushToast(error instanceof Error ? error.message : String(error), 'error');
		} finally {
			loading = false;
		}
	}

	async function onSaveEdit() {
		const sessionId = editingSessionId;
		if (sessionId === null) return;
		const sets = [];
		for (const row of editRows) {
			const reps = row.reps === null || String(row.reps).trim() === '' ? null : Number(row.reps);
			const weight = row.weight === null || String(row.weight).trim() === '' ? NaN : Number(row.weight);
			if (row.completed && (reps === null || !Number.isInteger(reps) || reps < 0)) {
				pushToast(`${row.exerciseName} set ${row.setIndex}: enter reps or untick it`, 'error');
				return;
			}
			if (!Number.isFinite(weight) || weight < 0) {
				pushToast(`${row.exerciseName} set ${row.setIndex}: weight must be 0 or more`, 'error');
				return;
			}
			// Keep the exact stored kg value unless the displayed weight was changed.
			const unchanged =
				row.originalWeightKg !== null && Number(displayWeightFromKg(row.originalWeightKg, weightUnit)) === weight;
			sets.push({
				sessionSetId: row.id,
				repsCompleted: row.completed ? reps : null,
				weightKg: unchanged ? row.originalWeightKg : convertUnitToKg(weight, weightUnit),
				completed: row.completed
			});
		}
		loading = true;
		try {
			const result = await updateWorkout(sessionId, sets);
			pushToast(result.message, 'success');
			editingSessionId = null;
			await loadHistory();
		} catch (error) {
			pushToast(error instanceof Error ? error.message : String(error), 'error');
		} finally {
			loading = false;
		}
	}

	async function onDelete(item: WorkoutHistoryItem) {
		if (!window.confirm(`Delete "${item.planWorkoutName}" from ${formatDate(item.finishedAt)}? This can't be undone.`)) {
			return;
		}
		loading = true;
		try {
			const result = await deleteWorkout(item.sessionId);
			pushToast(result.message, 'success');
			await loadHistory();
		} catch (error) {
			pushToast(error instanceof Error ? error.message : String(error), 'error');
		} finally {
			loading = false;
		}
	}

	async function onSendToStrava(item: WorkoutHistoryItem) {
		loading = true;
		errorMessage = '';
		infoMessage = '';
		try {
			const result = await sendWorkoutToStrava(item.sessionId);
			if (!result.ok) throw new Error(result.message);
			infoMessage = result.activityUrl
				? `Sent to Strava: ${result.activityUrl}`
				: result.message;
			pushToast(infoMessage, 'success');
			await loadHistory();
		} catch (error) {
			errorMessage = error instanceof Error ? error.message : String(error);
			pushToast(errorMessage, 'error');
		} finally {
			loading = false;
		}
	}

	onMount(() => {
		weightUnit = getPreferredWeightUnit();
		const offWeightUnit = onWeightUnitChange((unit) => {
			weightUnit = unit;
		});

		(async () => {
			loading = true;
			try {
				await loadHistory();
			} catch (error) {
				errorMessage = error instanceof Error ? error.message : String(error);
				pushToast(errorMessage, 'error');
			} finally {
				loading = false;
			}
		})();

		return () => offWeightUnit();
	});
</script>

<section class="card history-card">
	<h1>Workout History</h1>
	{#if loading}
		<p class="subtle">Loading…</p>
	{/if}

	{#if !loading && history.length === 0}
		<p class="subtle">No completed workouts yet.</p>
	{:else if history.length > 0}
		<div class="history-list">
			{#each history as item}
				<article class="history-item">
					<header class="history-head">
						<div>
							<h2>#{item.sessionId} · {item.planWorkoutName}</h2>
							<p class="subtle">Finished: {formatDate(item.finishedAt)}</p>
						</div>
						<div class="history-summary">
							<div>
								<span class="subtle">Completed sets</span>
								<strong>{item.completedSets}/{item.totalSets}</strong>
							</div>
							<div>
								<span class="subtle">Total volume</span>
								<strong>{volumeLabel(item.totalVolumeKg)}</strong>
							</div>
							<div>
								<span class="subtle">Workout time</span>
								<strong>{formatDuration(item.totalDurationSeconds)}</strong>
							</div>
							{#if item.heartRateSampleCount > 0}
								<div>
									<span class="subtle">Heart rate</span>
									<strong>{item.avgHeartRateBpm ?? '—'} avg · {item.maxHeartRateBpm ?? '—'} max</strong>
								</div>
							{/if}
							<div class="strava-row">
								{#if item.stravaExportStatus === 'SENT' && item.stravaActivityUrl}
									<a href={item.stravaActivityUrl} target="_blank" rel="noreferrer">View on Strava</a>
								{:else if stravaConnection?.connected}
									<button
										type="button"
										onclick={() => onSendToStrava(item)}
										disabled={loading || item.stravaExportStatus === 'PENDING'}
									>
										{item.stravaExportStatus === 'FAILED' ? 'Retry Strava' : 'Send to Strava'}
									</button>
								{:else}
									<span class="subtle">Connect Strava in Settings</span>
								{/if}
							</div>
							<div class="edit-row">
								<button type="button" onclick={() => onEdit(item)} disabled={loading}>Edit</button>
								<button type="button" class="danger" onclick={() => onDelete(item)} disabled={loading}>Delete</button>
							</div>
						</div>
					</header>

					{#if editingSessionId === item.sessionId}
						<section class="edit-panel">
							<p class="subtle">
								Fix reps or weights. If this is your most recent workout, progression is recalculated;
								otherwise only history, PRs and charts change.
							</p>
							<table>
								<thead>
									<tr>
										<th>Exercise</th>
										<th>Set</th>
										<th>Done</th>
										<th>Reps</th>
										<th>Weight ({weightUnitLabel(weightUnit)})</th>
									</tr>
								</thead>
								<tbody>
									{#each editRows as row (row.id)}
										<tr>
											<td>{row.exerciseName}</td>
											<td>{row.setIndex}</td>
											<td><input type="checkbox" bind:checked={row.completed} aria-label="Set completed" /></td>
											<td><input type="number" min="0" step="1" bind:value={row.reps} disabled={!row.completed} aria-label="Reps" /></td>
											<td><input type="number" min="0" step="any" bind:value={row.weight} aria-label="Weight" /></td>
										</tr>
									{/each}
								</tbody>
							</table>
							<div class="edit-row">
								<button type="button" class="primary" onclick={onSaveEdit} disabled={loading}>Save changes</button>
								<button type="button" onclick={() => (editingSessionId = null)} disabled={loading}>Cancel</button>
							</div>
						</section>
					{/if}

					{#if item.heartRateSampleCount > 0}
						<section class="hr-section">
							{#if heartRateLoadingBySession[item.sessionId]}
								<p class="subtle">Loading heart-rate chart…</p>
							{:else if (heartRateBySession[item.sessionId] ?? []).length >= 2}
								<div class="hr-chart-wrap" aria-label="Heart rate chart">
									<HeartRateChart samples={heartRateBySession[item.sessionId] ?? []} />
								</div>
							{:else}
								<p class="subtle">Heart-rate data captured ({item.heartRateSampleCount} sample(s)).</p>
							{/if}
						</section>
					{/if}

					{#if item.exercises.length === 0}
						<p class="subtle">No completed exercises recorded.</p>
					{:else}
						<table>
							<thead>
								<tr>
									<th>Exercise</th>
									<th>Sets</th>
									<th>Total reps</th>
									<th>Top weight</th>
								</tr>
							</thead>
							<tbody>
								{#each item.exercises as exercise}
									<tr>
										<td>
											{exercise.exerciseName}
											{#if prLabel(item, exercise.exerciseName)}
												<span class="pr-badge" title={prLabel(item, exercise.exerciseName)}>🏆 PR</span>
											{/if}
										</td>
										<td>{exercise.completedSets}</td>
										<td>{exercise.totalReps}</td>
										<td>{loadLabel(exercise.topWeightKg)}</td>
									</tr>
								{/each}
							</tbody>
						</table>
					{/if}
				</article>
			{/each}
		</div>
	{/if}
</section>

<style>
	.edit-row {
		display: flex;
		gap: 0.5rem;
		justify-content: flex-end;
	}

	.edit-panel {
		display: grid;
		gap: 0.6rem;
		border: 1px solid #334155;
		border-radius: 10px;
		padding: 0.7rem;
	}

	.edit-panel input[type='number'] {
		width: 6rem;
	}

	.edit-panel input[type='checkbox'] {
		width: auto;
	}

	.pr-badge {
		margin-left: 0.35rem;
		font-size: 0.72rem;
		padding: 0.05rem 0.4rem;
		border-radius: 999px;
		border: 1px solid #f59e0b;
		color: #f59e0b;
		white-space: nowrap;
	}

	.history-card {
		display: grid;
		gap: 0.75rem;
	}

	.history-list {
		display: grid;
		gap: 0.85rem;
	}

	.history-item {
		border: 1px solid #1f2937;
		border-radius: 10px;
		padding: 0.7rem;
		display: grid;
		gap: 0.65rem;
		background: #0b1220;
	}

	.history-head {
		display: flex;
		justify-content: space-between;
		align-items: flex-start;
		gap: 0.85rem;
		flex-wrap: wrap;
	}

	.history-head h2 {
		margin: 0;
		font-size: 1rem;
	}

	.history-head p {
		margin: 0.2rem 0 0;
	}

	.history-summary {
		display: grid;
		gap: 0.35rem;
		font-size: 0.9rem;
		text-align: right;
	}

	.history-summary div {
		display: grid;
		gap: 0.1rem;
	}

	.strava-row {
		justify-items: end;
	}

	.strava-row button,
	.strava-row a {
		justify-self: end;
	}

	.hr-section {
		display: grid;
		gap: 0.45rem;
	}

	.hr-chart-wrap {
		display: grid;
		padding: 0.4rem;
		border-radius: 8px;
		border: 1px solid #1e293b;
		background: #050b16;
	}

	table {
		width: 100%;
		border-collapse: collapse;
		font-size: 0.92rem;
	}

	th,
	td {
		padding: 0.45rem;
		border-bottom: 1px solid #1f2937;
		text-align: left;
	}

	tbody tr:last-child td {
		border-bottom: none;
	}

	@media (max-width: 740px) {
		.history-summary {
			text-align: left;
		}

		.strava-row {
			justify-items: start;
		}

		.strava-row button,
		.strava-row a {
			justify-self: start;
		}
	}
</style>
