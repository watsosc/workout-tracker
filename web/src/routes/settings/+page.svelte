<script lang="ts">
	import { onMount } from 'svelte';
	import {
		connectStrava,
		deleteActivePlan,
		disconnectStrava,
		fetchActivePlan,
		fetchDashboard,
		fetchStravaConnection,
		resetToBaseline,
		setExerciseOneRepMax,
		startStravaAuth
	} from '$lib/workout-api';
	import type {
		ActivePlan,
		Baseline,
		BaselineOverrideInput,
		DashboardStatus,
		StravaConnection
	} from '$lib/types';
	import {
		convertKgToUnit,
		convertUnitToKg,
		displayWeightFromKg,
		formatDate,
		getPreferredWeightUnit,
		onWeightUnitChange,
		parsePositiveFloat,
		setPreferredWeightUnit,
		type WeightUnit,
		weightUnitLabel
	} from '$lib/ui';

	let loading = $state(false);
	let errorMessage = $state('');
	let infoMessage = $state('');
	let activePlan = $state<ActivePlan | null>(null);
	let baselines = $state<Baseline[]>([]);
	let resetBaselines = $state<Baseline[]>([]);
	let resetBaselineInputs = $state<Record<number, string>>({});
	let oneRepMaxInputs = $state<Record<number, string>>({});
	let weightUnit = $state<WeightUnit>('lb');
	let status = $state<DashboardStatus | null>(null);
	let stravaConnection = $state<StravaConnection | null>(null);

	function initializeResetBaselineInputs(rows: Baseline[]) {
		const next: Record<number, string> = {};
		for (const row of rows) next[row.exerciseId] = displayWeightFromKg(row.baseline1rmKg, weightUnit);
		resetBaselineInputs = next;
	}

	function initializeOneRepMaxInputs(rows: Baseline[]) {
		const next: Record<number, string> = {};
		for (const row of rows) next[row.exerciseId] = displayWeightFromKg(row.baseline1rmKg, weightUnit);
		oneRepMaxInputs = next;
	}

	function setWeightUnit(unit: WeightUnit) {
		weightUnit = unit;
		setPreferredWeightUnit(unit);
		initializeResetBaselineInputs(resetBaselines);
		initializeOneRepMaxInputs(baselines);
	}

	function toggleWeightUnit() {
		setWeightUnit(weightUnit === 'lb' ? 'kg' : 'lb');
	}

	async function loadSettings() {
		const [plan, dashboard, strava] = await Promise.all([
			fetchActivePlan(),
			fetchDashboard(),
			fetchStravaConnection()
		]);
		activePlan = plan;
		baselines = dashboard.baselines;
		resetBaselines = dashboard.resetBaselines.length ? dashboard.resetBaselines : dashboard.baselines;
		initializeResetBaselineInputs(resetBaselines);
		initializeOneRepMaxInputs(dashboard.baselines);
		status = dashboard.status;
		stravaConnection = strava;
	}

	async function runAction(action: () => Promise<void>, msg?: string) {
		loading = true;
		errorMessage = '';
		try {
			await action();
			await loadSettings();
			if (msg) infoMessage = msg;
		} catch (error) {
			errorMessage = error instanceof Error ? error.message : String(error);
		} finally {
			loading = false;
		}
	}

	async function saveOneRepMax(row: Baseline) {
		const raw = oneRepMaxInputs[row.exerciseId] ?? displayWeightFromKg(row.baseline1rmKg, weightUnit);
		const displayValue = parsePositiveFloat(raw, '1RM');
		const baselineKg = convertUnitToKg(displayValue, weightUnit);
		await runAction(
			() => setExerciseOneRepMax(row.exerciseId, baselineKg),
			`Updated 1RM for ${row.exerciseName}`
		);
	}

	async function onResetProgress() {
		if (!activePlan) return;
		const overrides: BaselineOverrideInput[] = [];
		for (const row of resetBaselines) {
			const raw = resetBaselineInputs[row.exerciseId] ?? displayWeightFromKg(row.baseline1rmKg, weightUnit);
			const parsedDisplay = parsePositiveFloat(raw, `${row.exerciseName} reset 1RM`);
			const parsedKg = convertUnitToKg(parsedDisplay, weightUnit);
			if (Math.abs(parsedKg - row.baseline1rmKg) > 1e-6) {
				overrides.push({ exerciseId: row.exerciseId, baseline1rmKg: parsedKg });
			}
		}

		await runAction(
			() => resetToBaseline(overrides),
			'Reset progression to saved plan-start 1RM values'
		);
	}

	async function onDeletePlan() {
		if (!activePlan) return;
		if (!window.confirm(`Delete plan "${activePlan.name}" and all associated history?`)) return;
		await runAction(() => deleteActivePlan(), 'Deleted active plan');
	}

	function clearOAuthQueryParams() {
		if (typeof window === 'undefined') return;
		const url = new URL(window.location.href);
		url.searchParams.delete('code');
		url.searchParams.delete('scope');
		url.searchParams.delete('state');
		url.searchParams.delete('error');
		window.history.replaceState({}, '', url.toString());
	}

	async function maybeHandleStravaCallback(): Promise<boolean> {
		if (typeof window === 'undefined') return false;
		const params = new URLSearchParams(window.location.search);
		const oauthError = params.get('error');
		const code = params.get('code');
		const state = params.get('state');

		if (!oauthError && !code && !state) return false;

		if (oauthError) {
			errorMessage = `Strava OAuth error: ${oauthError}`;
			clearOAuthQueryParams();
			return true;
		}

		if (!code || !state) {
			errorMessage = 'Strava OAuth callback is missing code/state';
			clearOAuthQueryParams();
			return true;
		}

		await runAction(() => connectStrava(code, state), 'Connected Strava');
		clearOAuthQueryParams();
		return true;
	}

	async function onConnectStrava() {
		loading = true;
		errorMessage = '';
		infoMessage = '';
		try {
			const init = await startStravaAuth();
			if (!init.ok || !init.authUrl) throw new Error(init.message || 'Unable to start Strava OAuth');
			window.location.assign(init.authUrl);
		} catch (error) {
			errorMessage = error instanceof Error ? error.message : String(error);
		} finally {
			loading = false;
		}
	}

	async function onDisconnectStrava() {
		await runAction(() => disconnectStrava(), 'Disconnected Strava');
	}

	onMount(() => {
		weightUnit = getPreferredWeightUnit();
		const offWeightUnit = onWeightUnitChange((unit) => {
			weightUnit = unit;
			initializeResetBaselineInputs(resetBaselines);
			initializeOneRepMaxInputs(baselines);
		});

		(async () => {
			loading = true;
			try {
				const handledCallback = await maybeHandleStravaCallback();
				if (!handledCallback) await loadSettings();
			} catch (error) {
				errorMessage = error instanceof Error ? error.message : String(error);
			} finally {
				loading = false;
			}
		})();

		return () => offWeightUnit();
	});
</script>

<section class="card">
	<h1>Settings</h1>
	{#if activePlan}
		<p class="subtle">
			Plan: <strong>{activePlan.name}</strong> · last workout: {formatDate(status?.lastWorkoutAt ?? null)}
		</p>
	{:else}
		<p class="subtle">No active plan loaded.</p>
	{/if}
</section>

{#if infoMessage}
	<p class="banner success">{infoMessage}</p>
{/if}
{#if errorMessage}
	<p class="banner error">{errorMessage}</p>
{/if}

<section class="card">
	<h2>Units</h2>
	<div class="unit-toggle-row">
		<div class="unit-toggle-label">Weight unit</div>
		<button
			type="button"
			class="unit-toggle"
			onclick={toggleWeightUnit}
			aria-label={`Switch weight unit (currently ${weightUnit})`}
		>
			<span class="unit-option" class:active={weightUnit === 'lb'}>lb</span>
			<span class="unit-option" class:active={weightUnit === 'kg'}>kg</span>
			<span class="unit-knob" class:kg={weightUnit === 'kg'}></span>
		</button>
	</div>
	<p class="subtle">This preference affects all displayed/input weights. Backend values are stored in kg.</p>
</section>

<section class="card">
	<h2>Strava</h2>
	{#if !stravaConnection}
		<p class="subtle">Loading Strava status…</p>
	{:else if !stravaConnection.configured}
		<p class="subtle">
			Strava is not configured on the server yet. Add STRAVA_CLIENT_ID, STRAVA_CLIENT_SECRET, and
			STRAVA_REDIRECT_URI to the API service environment.
		</p>
	{:else if stravaConnection.connected}
		<p class="subtle">
			Connected{stravaConnection.athleteId ? ` (athlete ${stravaConnection.athleteId})` : ''} · token
			expires: {formatDate(stravaConnection.expiresAt)}
		</p>
		<div class="actions">
			<button type="button" onclick={onDisconnectStrava} disabled={loading}>Disconnect Strava</button>
		</div>
	{:else}
		<p class="subtle">Connect Strava to post completed workouts.</p>
		<div class="actions">
			<button type="button" onclick={onConnectStrava} disabled={loading}>Connect Strava</button>
		</div>
	{/if}
</section>

<section class="card">
	<h2>Training actions</h2>
	<p class="subtle">
		Update current 1RM values and adjust saved reset values below before running a reset.
	</p>
	{#if resetBaselines.length === 0}
		<p class="subtle">No saved reset 1RM values available yet.</p>
	{:else}
		<div class="baseline-grid">
			{#each resetBaselines as row}
				<div class="baseline-item">
					<div class="baseline-name">{row.exerciseName}</div>
					<div class="baseline-controls">
						<label class="compact-field">
							Current 1RM ({weightUnitLabel(weightUnit)})
							<div class="baseline-inline">
								<input
									type="number"
									min="0"
									step="0.1"
									bind:value={oneRepMaxInputs[row.exerciseId]}
									disabled={loading}
								/>
								<button type="button" onclick={() => saveOneRepMax(row)} disabled={loading}>Save</button>
							</div>
						</label>
						<label class="compact-field">
							Reset value ({weightUnitLabel(weightUnit)})
							<div class="baseline-inline">
								<input
									type="number"
									min="0"
									step="0.1"
									bind:value={resetBaselineInputs[row.exerciseId]}
									disabled={loading || !activePlan}
								/>
							</div>
						</label>
					</div>
				</div>
			{/each}
		</div>
	{/if}
	<div class="actions">
		<button onclick={onResetProgress} disabled={loading || !activePlan || resetBaselines.length === 0}>
			Reset progression to saved 1RM values
		</button>
		<button class="danger" onclick={onDeletePlan} disabled={loading || !activePlan}>Delete active plan</button>
	</div>
</section>

<style>
	.unit-toggle-row {
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 0.8rem;
		flex-wrap: wrap;
		padding: 0.35rem 0;
		margin-bottom: 0.35rem;
	}

	.unit-toggle-label {
		font-size: 0.92rem;
	}

	.unit-toggle {
		position: relative;
		display: grid;
		grid-template-columns: 1fr 1fr;
		align-items: center;
		width: 6.5rem;
		padding: 0.28rem;
		border-radius: 999px;
		background: #0b1220;
		border: 1px solid #334155;
		overflow: hidden;
	}

	.unit-option {
		z-index: 1;
		text-align: center;
		font-size: 0.82rem;
		line-height: 1.35;
		color: #94a3b8;
		user-select: none;
	}

	.unit-option.active {
		color: #fff;
		font-weight: 600;
	}

	.unit-knob {
		position: absolute;
		top: 0.28rem;
		left: 0.28rem;
		width: calc(50% - 0.28rem);
		height: calc(100% - 0.56rem);
		background: #2563eb;
		border-radius: 999px;
		transition: transform 140ms ease;
	}

	.unit-knob.kg {
		transform: translateX(100%);
	}

	.actions {
		display: flex;
		gap: 0.6rem;
		flex-wrap: wrap;
	}

	.baseline-grid {
		display: grid;
		grid-template-columns: 1fr;
		gap: 0.6rem;
		max-width: 760px;
	}

	.baseline-item {
		display: grid;
		gap: 0.7rem;
		border: 1px solid #1f2937;
		border-radius: 10px;
		padding: 0.7rem;
	}

	.baseline-name {
		font-weight: 600;
	}

	.baseline-controls {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
		gap: 0.65rem;
	}

	.compact-field {
		display: grid;
		gap: 0.35rem;
		font-size: 0.88rem;
	}

	.baseline-inline {
		display: inline-flex;
		align-items: center;
		gap: 0.45rem;
		flex-wrap: nowrap;
	}

	.baseline-inline input {
		width: 8rem;
	}

	@media (max-width: 640px) {
		.baseline-controls {
			grid-template-columns: 1fr;
		}
	}
</style>
