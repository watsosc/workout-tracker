<script lang="ts">
	import { onDestroy, onMount } from 'svelte';
	import Chart from 'chart.js/auto';
	import type { HeartRateSample } from '$lib/types';

	type Props = {
		samples: HeartRateSample[];
	};

	let { samples }: Props = $props();

	let canvasEl: HTMLCanvasElement | null = null;
	let chart: Chart<'line', { x: number; y: number }[]> | null = null;

	function formatSeconds(totalSeconds: number): string {
		const mins = Math.floor(totalSeconds / 60);
		const secs = totalSeconds % 60;
		return `${mins}:${String(secs).padStart(2, '0')}`;
	}

	function toPoints(items: HeartRateSample[]): { x: number; y: number }[] {
		const rows = items
			.map((sample) => ({ time: Date.parse(sample.recordedAt), bpm: sample.bpm }))
			.filter((row) => Number.isFinite(row.time) && Number.isFinite(row.bpm))
			.sort((a, b) => a.time - b.time);
		if (rows.length < 2) return [];

		const firstTime = rows[0].time;
		return rows.map((row) => ({
			x: Math.max(0, Math.round((row.time - firstTime) / 1000)),
			y: row.bpm
		}));
	}

	function xTickLimit(totalSeconds: number): number {
		if (totalSeconds < 120) return 4;
		if (totalSeconds < 480) return 5;
		return 6;
	}

	function averageBpm(points: { x: number; y: number }[]): number {
		if (points.length === 0) return 100;
		const total = points.reduce((sum, row) => sum + row.y, 0);
		return Math.round(total / points.length);
	}

	function buildYTickValues(yMin: number, yMax: number, avgY: number): number[] {
		const clampedAvg = Math.min(yMax, Math.max(yMin, avgY));
		const values = [Math.round(yMin), Math.round(clampedAvg), Math.round(yMax)].sort((a, b) => a - b);
		return values.filter((value, index) => index === 0 || value !== values[index - 1]);
	}

	function buildChart() {
		if (!canvasEl) return;

		const points = toPoints(samples);
		const lastX = points.length > 0 ? points[points.length - 1].x : 0;
		const minY = points.length > 0 ? Math.min(...points.map((p) => p.y)) : 60;
		const maxY = points.length > 0 ? Math.max(...points.map((p) => p.y)) : 160;
		const padY = Math.max(4, Math.round((maxY - minY) * 0.08));
		const yMin = Math.max(20, minY - padY);
		const yMax = maxY + padY;
		const avgY = averageBpm(points);
		const yTickValues = buildYTickValues(yMin, yMax, avgY);

		chart = new Chart(canvasEl, {
			type: 'line',
			data: {
				datasets: [
					{
						data: [
							{ x: 0, y: avgY },
							{ x: Math.max(1, lastX), y: avgY }
						],
						borderColor: 'rgba(241, 245, 249, 0.92)',
						borderWidth: 1.35,
						pointRadius: 0,
						pointHoverRadius: 0,
						pointHitRadius: 0,
						borderDash: [6, 6],
						tension: 0,
						fill: false
					},
					{
						data: points,
						borderColor: '#22c55e',
						borderWidth: 2,
						pointRadius: 0,
						pointHitRadius: 6,
						tension: 0,
						fill: false
					}
				]
			},
			options: {
				responsive: true,
				maintainAspectRatio: false,
				animation: false,
				normalized: true,
				plugins: {
					legend: { display: false },
					tooltip: {
						filter(item) {
							return item.datasetIndex === 1;
						},
						callbacks: {
							title(items) {
								const x = Number(items[0]?.parsed?.x ?? 0);
								return formatSeconds(Math.max(0, Math.round(x)));
							},
							label(item) {
								const y = Number(item.parsed.y ?? 0);
								return `${Math.round(y)} bpm`;
							}
						}
					}
				},
				scales: {
					x: {
						type: 'linear',
						min: 0,
						max: Math.max(1, lastX),
						grid: {
							color: 'rgba(71, 85, 105, 0.25)'
						},
						border: {
							color: 'rgba(148, 163, 184, 0.75)'
						},
						ticks: {
							color: '#cbd5e1',
							maxTicksLimit: xTickLimit(lastX),
							callback(value) {
								return formatSeconds(Math.max(0, Math.round(Number(value))));
							}
						}
					},
					y: {
						min: yMin,
						max: yMax,
						afterBuildTicks(axis) {
							axis.ticks = yTickValues.map((value) => ({ value }));
						},
						grid: {
							color: 'rgba(71, 85, 105, 0.45)'
						},
						border: {
							color: 'rgba(148, 163, 184, 0.75)'
						},
						ticks: {
							color: '#cbd5e1',
							callback(value) {
								return `${Math.round(Number(value))} bpm`;
							}
						}
					}
				}
			}
		});
	}

	function refreshChart() {
		if (!chart) return;
		const points = toPoints(samples);
		const lastX = points.length > 0 ? points[points.length - 1].x : 0;
		const minY = points.length > 0 ? Math.min(...points.map((p) => p.y)) : 60;
		const maxY = points.length > 0 ? Math.max(...points.map((p) => p.y)) : 160;
		const padY = Math.max(4, Math.round((maxY - minY) * 0.08));
		const yMin = Math.max(20, minY - padY);
		const yMax = maxY + padY;
		const avgY = averageBpm(points);
		const yTickValues = buildYTickValues(yMin, yMax, avgY);

		chart.data.datasets[0].data = [
			{ x: 0, y: avgY },
			{ x: Math.max(1, lastX), y: avgY }
		];
		chart.data.datasets[1].data = points;

		if (chart.options.scales?.x && chart.options.scales.x.type === 'linear') {
			chart.options.scales.x.max = Math.max(1, lastX);
			if (chart.options.scales.x.ticks) chart.options.scales.x.ticks.maxTicksLimit = xTickLimit(lastX);
		}
		if (chart.options.scales?.y) {
			chart.options.scales.y.min = yMin;
			chart.options.scales.y.max = yMax;
			chart.options.scales.y.afterBuildTicks = (axis) => {
				axis.ticks = yTickValues.map((value) => ({ value }));
			};
		}
		chart.update('none');
	}

	onMount(() => {
		buildChart();
	});

	$effect(() => {
		samples;
		refreshChart();
	});

	onDestroy(() => {
		if (chart) {
			chart.destroy();
			chart = null;
		}
	});
</script>

<div class="hr-canvas-wrap">
	<canvas bind:this={canvasEl} aria-label="Heart rate line chart"></canvas>
</div>

<style>
	.hr-canvas-wrap {
		position: relative;
		height: 11rem;
		width: 100%;
	}

	canvas {
		display: block;
		width: 100%;
		height: 100%;
	}
</style>
