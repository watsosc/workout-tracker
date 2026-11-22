import { expect, test, type Page } from '@playwright/test';

// Runs against a fresh backend seeded by e2e/start-backend.sh:
//   login e2e / e2e-password, plan "E2E Plan" with Day A (Squat T1 5x3, Lat Pulldown 2x10) and Day B.

async function signIn(page: Page) {
	await page.goto('/workout');
	await expect(page).toHaveURL(/\/login/);
	await page.getByLabel('Username').fill('e2e');
	await page.getByLabel('Password').fill('e2e-password');
	await page.getByRole('button', { name: 'Sign in' }).click();
	await expect(page).toHaveURL(/\/workout/);
}

const toast = (page: Page, text: string | RegExp) => page.getByRole('status').filter({ hasText: text }).first();
const setLine = (page: Page) => page.locator('.set-target');

async function answerPrompt(page: Page, value: string) {
	const dialog = page.locator('.modal').last();
	await dialog.locator('input').fill(value);
	await dialog.getByRole('button', { name: /Save|Start/ }).click();
}

test('sign-in rejects a wrong password', async ({ page }) => {
	await page.goto('/workout');
	await expect(page).toHaveURL(/\/login\?next=%2Fworkout/);
	await page.getByLabel('Username').fill('e2e');
	await page.getByLabel('Password').fill('nope');
	await page.getByRole('button', { name: 'Sign in' }).click();
	await expect(page.getByText('Incorrect username or password')).toBeVisible();
});

test('full workout: log, adjust, undo, skip, add, finish, then edit and delete from history', async ({ page }) => {
	page.on('dialog', (dialog) => dialog.accept());
	await signIn(page);

	await test.step('start the planned workout', async () => {
		await expect(page.getByText('Day A')).toBeVisible();
		await page.getByRole('button', { name: 'Start workout' }).click();
		await expect(page.locator('.set-exercise')).toHaveText('Squat');
		await expect(setLine(page)).toContainText('Set 1/5');
		await expect(page.getByText('Warm-up')).toBeVisible();
		await expect(page.locator('.plate-line')).toContainText('/side');
	});

	await test.step('log a set, undo it, log it again', async () => {
		await page.getByRole('button', { name: 'Mark set successful' }).click();
		await expect(setLine(page)).toContainText('Set 2/5');
		await expect(page.getByText('Warm-up')).toBeHidden();
		await page.getByRole('button', { name: /Undo set/ }).click();
		await expect(setLine(page)).toContainText('Set 1/5');
		await page.getByRole('button', { name: 'Mark set successful' }).click();
		await expect(setLine(page)).toContainText('Set 2/5');
	});

	await test.step('change the weight for the remaining sets', async () => {
		await page.getByRole('button', { name: 'Change weight' }).click();
		await answerPrompt(page, '150');
		await expect(setLine(page)).toContainText('@ 150 lb');
	});

	await test.step('a failed set asks for the reps actually done', async () => {
		await page.getByRole('button', { name: 'Mark set failed' }).click();
		await answerPrompt(page, '3');
		await expect(page.getByText('A failed set is fewer than 3 reps')).toBeVisible();
		await answerPrompt(page, '1');
		await expect(setLine(page)).toContainText('Set 3/5');
		await expect(setLine(page)).toContainText('@ 150 lb'); // weight change carried forward
	});

	await test.step('skip the rest of squat, add a set and an exercise', async () => {
		await page.getByRole('button', { name: 'Exercises' }).click();
		const squat = page.locator('.entry-row').filter({ hasText: 'Squat' });
		await expect(squat).toContainText('2/5 sets · In progress');
		await squat.getByRole('button', { name: 'Skip' }).click();
		await expect(squat).toContainText('Skipped');

		const pulldown = page.locator('.entry-row').filter({ hasText: 'Lat Pulldown' });
		await pulldown.getByRole('button', { name: '+ Set' }).click();
		await expect(pulldown).toContainText('0/3 sets');

		await page.getByPlaceholder('Exercise name').fill('Plank');
		await page.getByLabel('Sets').fill('1');
		await page.getByLabel('Reps').fill('1');
		await page.getByRole('button', { name: 'Add', exact: true }).click();
		await expect(page.locator('.entry-row').filter({ hasText: 'Plank' })).toContainText('added');
		await page.getByRole('button', { name: 'Close' }).click();
	});

	await test.step('finish the remaining sets', async () => {
		await expect(page.locator('.set-exercise')).toHaveText('Lat Pulldown');
		for (let i = 0; i < 4; i++) {
			await page.getByRole('button', { name: 'Mark set successful' }).click();
		}
		await expect(page.getByText('All sets complete')).toBeVisible();
		await page.getByRole('button', { name: 'Finish workout' }).click();
		await expect(toast(page, 'Workout finished')).toBeVisible();
		await expect(page.getByText('Day B')).toBeVisible(); // plan advanced
	});

	await test.step('edit the workout in history (latest, so progression is recalculated)', async () => {
		await page.goto('/history');
		const item = page.locator('.history-item').filter({ hasText: 'Day A' });
		await expect(item).toBeVisible();
		await item.getByRole('button', { name: 'Edit' }).click();
		const plankReps = item.locator('tr').filter({ hasText: 'Plank' }).getByLabel('Reps');
		await plankReps.fill('2');
		await item.getByRole('button', { name: 'Save changes' }).click();
		await expect(toast(page, 'progression recalculated')).toBeVisible();
	});

	await test.step('delete it, which undoes its progression', async () => {
		await page.locator('.history-item').filter({ hasText: 'Day A' }).getByRole('button', { name: 'Delete' }).click();
		await expect(toast(page, 'progression undone')).toBeVisible();
		await expect(page.getByText('No completed workouts yet.')).toBeVisible();
		await page.goto('/workout');
		await expect(page.getByText('Day A')).toBeVisible();
	});
});

test('empty workout outside the plan', async ({ page }) => {
	page.on('dialog', (dialog) => dialog.accept());
	await signIn(page);
	// Don't depend on earlier tests having finished cleanly.
	const exit = page.getByRole('button', { name: 'Exit' });
	if (await exit.isVisible()) {
		await exit.click();
		await page.getByRole('button', { name: 'Discard workout' }).click();
	}
	await page.getByRole('button', { name: 'Start empty workout' }).click();
	await answerPrompt(page, 'Hotel gym');

	// The exercises panel opens so you can add the first exercise.
	await page.getByPlaceholder('Exercise name').fill('Push-up');
	await page.getByLabel('Sets').fill('2');
	await page.getByRole('button', { name: 'Add', exact: true }).click();
	await page.getByRole('button', { name: 'Close' }).click();

	await expect(page.locator('.set-exercise')).toHaveText('Push-up');
	await page.getByRole('button', { name: 'Mark set successful' }).click();
	await page.getByRole('button', { name: 'Mark set successful' }).click();
	await page.getByRole('button', { name: 'Finish workout' }).click();
	await expect(toast(page, 'Workout finished')).toBeVisible();
	await expect(page.getByText('Day A')).toBeVisible(); // plan untouched

	await page.goto('/history');
	await expect(page.locator('.history-item').filter({ hasText: 'Hotel gym' })).toBeVisible();
});
