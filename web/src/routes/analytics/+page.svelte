<script lang="ts">
	import { onMount } from 'svelte';
	import { pushToast } from '$lib/toast';
	import {
		fetchActivePlan,
		fetchDashboard,
		fetchExerciseProgress,
		fetchWorkoutHistory
	} from '$lib/workout-api';
	import type {
		ActivePlan,
		Baseline,
		ExerciseProgressPoint,
		WorkoutHistoryItem
	} from '$lib/types';
	import {
		convertKgToUnit,
		getPreferredWeightUnit,
		onWeightUnitChange,
		snapWeightToHalfStep,
		type WeightUnit,
		weightUnitLabel
	} from '$lib/ui';

	type ChartDot = {
		x: number;
		y: number;
	};

	type ChartTick = {
		value: number;
		y: number;
	};

	type ChartXTick = {
		label: string;
		x: number;
	};

	type ChartSeriesModel = {
		label: string;
		color: string;
		path: string;
		dots: ChartDot[];
	};

	type ChartModel = {
		hasData: boolean;
		pointCount: number;
		xAxisY: number;
		yAxisX: number;
		yTicks: ChartTick[];
		xTicks: ChartXTick[];
		series: ChartSeriesModel[];
	};

	type ChartSeriesInput = {
		label: string;
		color: string;
		values: number[];
	};

	type VolumeView = 'overall' | `day:${number}`;

	const CHART_WIDTH = 720;
	const CHART_HEIGHT = 300;
	const CHART_PADDING = {
		top: 16,
		right: 16,
		bottom: 40,
		left: 56
	};

	let loading = $state(false);
	let errorMessage = $state('');
	let baselines = $state<Baseline[]>([]);
	let selectedExerciseId = $state<number | null>(null);
	let progress = $state<ExerciseProgressPoint[]>([]);
	let history = $state<WorkoutHistoryItem[]>([]);
	let activePlan = $state<ActivePlan | null>(null);
	let activePlanRunId = $state<number | null>(null);
	let selectedVolumeView = $state<VolumeView>('overall');
	let weightUnit = $state<WeightUnit>('lb');

	async function loadProgress() {
		if (selectedExerciseId === null) {
			progress = [];
			return;
		}
		progress = await fetchExerciseProgress(selectedExerciseId, 120);
	}

	function shortDate(value: string | null): string {
		if (!value) return '—';
		return new Date(value).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
	}

	function volumeUnitLabel(unit: WeightUnit): string {
		return `${unit}-reps`;
	}

	function tickIndices(total: number, maxTicks = 6): number[] {
		if (total <= 0) return [];
		if (total <= maxTicks) return Array.from({ length: total }, (_, i) => i);
		const idx = new Set<number>();
		for (let i = 0; i < maxTicks; i += 1) {
			idx.add(Math.round((i * (total - 1)) / (maxTicks - 1)));
		}
		return Array.from(idx).sort((a, b) => a - b);
	}

	function formatAxisValue(value: number): string {
		if (Math.abs(value) >= 1000) return Math.round(value).toLocaleString();
		if (Math.abs(value) >= 100) return value.toFixed(0);
		return value.toFixed(1);
	}

	function formatWeightAxisValue(value: number): string {
		const snapped = snapWeightToHalfStep(value);
		return String(Number(snapped.toFixed(1)));
	}

	function buildLineChart(labels: string[], seriesInput: ChartSeriesInput[]): ChartModel {
		const pointCount = labels.length;
		const chartWidth = CHART_WIDTH - CHART_PADDING.left - CHART_PADDING.right;
		const chartHeight = CHART_HEIGHT - CHART_PADDING.top - CHART_PADDING.bottom;
		const xAxisY = CHART_HEIGHT - CHART_PADDING.bottom;
		const yAxisX = CHART_PADDING.left;

		if (pointCount === 0 || seriesInput.length === 0) {
			return {
				hasData: false,
				pointCount: 0,
				xAxisY,
				yAxisX,
				yTicks: [],
				xTicks: [],
				series: []
			};
		}

		const allValues = seriesInput.flatMap((s) => s.values).filter((v) => Number.isFinite(v));
		if (allValues.length === 0) {
			return {
				hasData: false,
				pointCount,
				xAxisY,
				yAxisX,
				yTicks: [],
				xTicks: [],
				series: []
			};
		}

		let minValue = Math.min(...allValues);
		let maxValue = Math.max(...allValues);
		if (minValue >= 0) minValue = 0;
		if (maxValue === minValue) {
			maxValue = minValue + 1;
		} else {
			const rangePad = (maxValue - minValue) * 0.08;
			maxValue += rangePad;
			if (minValue > 0) minValue = Math.max(0, minValue - rangePad);
		}
		const span = maxValue - minValue;

		const xFor = (index: number): number =>
			pointCount === 1
				? CHART_PADDING.left + chartWidth / 2
				: CHART_PADDING.left + (index * chartWidth) / (pointCount - 1);
		const yFor = (value: number): number =>
			CHART_PADDING.top + ((maxValue - value) / span) * chartHeight;

		const yTicks: ChartTick[] = Array.from({ length: 5 }, (_, i) => {
			const ratio = i / 4;
			const value = maxValue - span * ratio;
			return { value, y: yFor(value) };
		});

		const xTicks: ChartXTick[] = tickIndices(pointCount).map((i) => ({ label: labels[i], x: xFor(i) }));

		const series: ChartSeriesModel[] = seriesInput.map((s) => {
			const dots = labels.map((_, index) => {
				const value = s.values[index] ?? 0;
				return { x: xFor(index), y: yFor(value) };
			});
			return {
				label: s.label,
				color: s.color,
				path: dots.map((d) => `${d.x},${d.y}`).join(' '),
				dots
			};
		});

		return {
			hasData: true,
			pointCount,
			xAxisY,
			yAxisX,
			yTicks,
			xTicks,
			series
		};
	}

	function volumeViewOptions(): Array<{ value: VolumeView; label: string }> {
		const options: Array<{ value: VolumeView; label: string }> = [{ value: 'overall', label: 'Overall' }];
		if (!activePlan) return options;
		const days = [...activePlan.workouts].sort((a, b) => a.sequenceIndex - b.sequenceIndex);
		for (const day of days) {
			options.push({
				value: `day:${day.sequenceIndex}`,
				label: `Day ${day.sequenceIndex + 1} · ${day.name}`
			});
		}
		return options;
	}

	function filteredVolumeRows(): WorkoutHistoryItem[] {
		const scoped =
			activePlanRunId === null
				? history
				: history.filter((item) => item.planRunId === activePlanRunId);
		const chronological = [...scoped].sort((a, b) => {
			const aTime = a.finishedAt ? new Date(a.finishedAt).getTime() : 0;
			const bTime = b.finishedAt ? new Date(b.finishedAt).getTime() : 0;
			return aTime - bTime;
		});

		if (selectedVolumeView === 'overall') return chronological;
		const daySequence = Number(selectedVolumeView.replace('day:', ''));
		return chronological.filter((item) => item.workoutSequenceIndex === daySequence);
	}

	function volumeChartModel(): ChartModel {
		const rows = filteredVolumeRows();
		const labels = rows.map((r) => shortDate(r.finishedAt));
		const values = rows.map((r) => convertKgToUnit(r.totalVolumeKg, weightUnit));
		return buildLineChart(labels, [
			{
				label: `Total volume (${volumeUnitLabel(weightUnit)})`,
				color: '#38bdf8',
				values
			}
		]);
	}

	function exerciseChartModel(): ChartModel {
		const labels = progress.map((p) => shortDate(p.date));
		const topSet = progress.map((p) => snapWeightToHalfStep(convertKgToUnit(p.topWeightKg, weightUnit)));
		const est1rm = progress.map((p) =>
			snapWeightToHalfStep(convertKgToUnit(p.estimated1rmKg, weightUnit))
		);
		return buildLineChart(labels, [
			{ label: `Top set weight (${weightUnitLabel(weightUnit)})`, color: '#22c55e', values: topSet },
			{ label: `Estimated 1RM (${weightUnitLabel(weightUnit)})`, color: '#f59e0b', values: est1rm }
		]);
	}

	onMount(() => {
		weightUnit = getPreferredWeightUnit();
		const offWeightUnit = onWeightUnitChange((unit) => {
			weightUnit = unit;
		});

		(async () => {
			loading = true;
			try {
				const [dashboard, plan, workoutHistory] = await Promise.all([
					fetchDashboard(),
					fetchActivePlan(),
					fetchWorkoutHistory(300)
				]);
				baselines = dashboard.baselines;
				activePlanRunId = dashboard.status?.planRunId ?? null;
				activePlan = plan;
				history = workoutHistory;
				selectedExerciseId = baselines.length ? baselines[0].exerciseId : null;
				await loadProgress();
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

<section class="card analytics-card">
	<h1>Analytics</h1>
	{#if loading}
		<p class="subtle">Loading…</p>
	{/if}

	<section class="panel">
		<h2>Total weight volume</h2>
		<p class="subtle">Completed set weight × reps per workout ({volumeUnitLabel(weightUnit)}).</p>
		{#if history.length === 0}
			<p class="subtle">No completed workouts yet.</p>
		{:else}
			<label>
				View
				<select bind:value={selectedVolumeView}>
					{#each volumeViewOptions() as option}
						<option value={option.value}>{option.label}</option>
					{/each}
				</select>
			</label>

			{@const volumeModel = volumeChartModel()}
			{#if !volumeModel.hasData}
				<p class="subtle">No workouts yet for that day.</p>
			{:else}
				<svg viewBox={`0 0 ${CHART_WIDTH} ${CHART_HEIGHT}`} class="chart" aria-label="Total volume chart">
					{#each volumeModel.yTicks as tick}
						<line x1={volumeModel.yAxisX} y1={tick.y} x2={CHART_WIDTH - CHART_PADDING.right} y2={tick.y} class="grid" />
						<text x={volumeModel.yAxisX - 8} y={tick.y + 4} class="axis-label right">{formatAxisValue(tick.value)}</text>
					{/each}
					<line x1={volumeModel.yAxisX} y1={CHART_PADDING.top} x2={volumeModel.yAxisX} y2={volumeModel.xAxisY} class="axis" />
					<line x1={volumeModel.yAxisX} y1={volumeModel.xAxisY} x2={CHART_WIDTH - CHART_PADDING.right} y2={volumeModel.xAxisY} class="axis" />
					{#each volumeModel.xTicks as tick}
						<line x1={tick.x} y1={volumeModel.xAxisY} x2={tick.x} y2={volumeModel.xAxisY + 5} class="axis" />
						<text x={tick.x} y={volumeModel.xAxisY + 20} class="axis-label center">{tick.label}</text>
					{/each}
					{#each volumeModel.series as series}
						{#if volumeModel.pointCount > 1}
							<polyline points={series.path} fill="none" stroke={series.color} stroke-width="3" />
						{/if}
						{#each series.dots as dot}
							<circle cx={dot.x} cy={dot.y} r="4" fill={series.color} />
						{/each}
					{/each}
				</svg>
				<p class="legend">
					{#each volumeModel.series as series}
						<span><i class="dot" style={`background:${series.color}`}></i>{series.label}</span>
					{/each}
				</p>
			{/if}
		{/if}
	</section>

	<section class="panel">
		<h2>Exercise trends</h2>
		{#if baselines.length === 0}
			<p class="subtle">No exercises available yet.</p>
		{:else}
			<label>
				Exercise
				<select bind:value={selectedExerciseId} onchange={loadProgress}>
					{#each baselines as baseline}
						<option value={baseline.exerciseId}>{baseline.exerciseName}</option>
					{/each}
				</select>
			</label>

			{#if progress.length === 0}
				<p class="subtle">No completed sets for this exercise yet.</p>
			{:else}
				{@const exerciseModel = exerciseChartModel()}
				<svg viewBox={`0 0 ${CHART_WIDTH} ${CHART_HEIGHT}`} class="chart" aria-label="Exercise progress chart">
					{#each exerciseModel.yTicks as tick}
						<line x1={exerciseModel.yAxisX} y1={tick.y} x2={CHART_WIDTH - CHART_PADDING.right} y2={tick.y} class="grid" />
						<text x={exerciseModel.yAxisX - 8} y={tick.y + 4} class="axis-label right">{formatWeightAxisValue(tick.value)}</text>
					{/each}
					<line x1={exerciseModel.yAxisX} y1={CHART_PADDING.top} x2={exerciseModel.yAxisX} y2={exerciseModel.xAxisY} class="axis" />
					<line x1={exerciseModel.yAxisX} y1={exerciseModel.xAxisY} x2={CHART_WIDTH - CHART_PADDING.right} y2={exerciseModel.xAxisY} class="axis" />
					{#each exerciseModel.xTicks as tick}
						<line x1={tick.x} y1={exerciseModel.xAxisY} x2={tick.x} y2={exerciseModel.xAxisY + 5} class="axis" />
						<text x={tick.x} y={exerciseModel.xAxisY + 20} class="axis-label center">{tick.label}</text>
					{/each}
					{#each exerciseModel.series as series}
						{#if exerciseModel.pointCount > 1}
							<polyline points={series.path} fill="none" stroke={series.color} stroke-width="3" />
						{/if}
						{#each series.dots as dot}
							<circle cx={dot.x} cy={dot.y} r="4" fill={series.color} />
						{/each}
					{/each}
				</svg>
				<p class="legend">
					{#each exerciseModel.series as series}
						<span><i class="dot" style={`background:${series.color}`}></i>{series.label}</span>
					{/each}
				</p>
			{/if}
		{/if}
	</section>
</section>

<style>
	.analytics-card {
		display: grid;
		gap: 1rem;
	}

	.panel {
		display: grid;
		gap: 0.55rem;
	}

	h2 {
		margin: 0;
		font-size: 1.05rem;
	}

	.chart {
		width: 100%;
		height: auto;
		background: #0b1220;
		border: 1px solid #1f2937;
		border-radius: 10px;
		margin-top: 0.35rem;
	}

	.grid {
		stroke: #1f2937;
		stroke-width: 1;
	}

	.axis {
		stroke: #64748b;
		stroke-width: 1.2;
	}

	.axis-label {
		font-size: 0.72rem;
		fill: #94a3b8;
	}

	.axis-label.right {
		text-anchor: end;
	}

	.axis-label.center {
		text-anchor: middle;
	}

	.legend {
		display: flex;
		flex-wrap: wrap;
		gap: 0.85rem;
		font-size: 0.9rem;
		color: #cbd5e1;
	}

	.dot {
		display: inline-block;
		width: 0.7rem;
		height: 0.7rem;
		border-radius: 50%;
		margin-right: 0.4rem;
	}
</style>
