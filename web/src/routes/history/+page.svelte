<script lang="ts">
	import { onMount } from 'svelte';
	import { fetchStravaConnection, fetchWorkoutHistory, sendWorkoutToStrava } from '$lib/workout-api';
	import { pushToast } from '$lib/toast';
	import type { StravaConnection, WorkoutHistoryItem } from '$lib/types';
	import {
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

	async function loadHistory() {
		const [items, strava] = await Promise.all([fetchWorkoutHistory(120), fetchStravaConnection()]);
		history = items;
		stravaConnection = strava;
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
	{#if errorMessage}
		<p class="banner error">{errorMessage}</p>
	{/if}
	{#if infoMessage}
		<p class="banner success">{infoMessage}</p>
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
						</div>
					</header>

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
										<td>{exercise.exerciseName}</td>
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
