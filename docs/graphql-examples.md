# GraphQL examples

Endpoint: `POST /graphql`

You can run these from GraphiQL at `http://127.0.0.1:8000/graphql`.

> Notes
> - Backend stores canonical weights in **kg**.
> - GraphQL field names are camelCase.
> - For `addExerciseToActivePlan`, `baseline1rmKg` is required for `GZCLP_T1/GZCLP_T2`, optional for `GZCLP_T3/BASIC`.

---

## 1) Dashboard

```graphql
query Dashboard {
  dashboard {
    status {
      planRunId
      planName
      week
      workoutIndex
      lastWorkoutAt
      daysSinceLastWorkout
      needsNew1rmExercises
    }
    baselines {
      exerciseId
      exerciseName
      baseline1rmKg
    }
    resetBaselines {
      exerciseId
      exerciseName
      baseline1rmKg
    }
  }
}
```

---

## 2) Active plan

```graphql
query ActivePlan {
  activePlan {
    id
    name
    totalWeeks
    daysPerWeek
    currentWeek
    currentWorkoutIndex
    workouts {
      id
      name
      sequenceIndex
      exercises {
        id
        exerciseId
        exerciseName
        sets
        reps
        targetWeightKg
        progressionType
        progressionProtocol
        tier
        progressionValue
        trainingMaxRatio
        amrapLastSet
      }
    }
  }
}
```

---

## 3) Seed a plan (example: 2-day GZCLP)

```graphql
mutation SeedPlan($inputPlanName: String!, $exercises: [SeedExerciseInput!]!, $workouts: [SeedPlanWorkoutInput!]!, $daysPerWeek: Int) {
  seedPlan(
    planName: $inputPlanName
    totalWeeks: null
    exercises: $exercises
    workouts: $workouts
    daysPerWeek: $daysPerWeek
  ) {
    ok
    planId
    planRunId
  }
}
```

Variables:

```json
{
  "inputPlanName": "GZCLP",
  "daysPerWeek": 2,
  "exercises": [
    { "name": "Squat", "baseline1rmKg": 120 },
    { "name": "Bench Press", "baseline1rmKg": 90 },
    { "name": "Lat Pulldown", "baseline1rmKg": 70 }
  ],
  "workouts": [
    {
      "name": "Day 1",
      "sequenceIndex": 0,
      "exercises": [
        {
          "exerciseName": "Squat",
          "sets": 5,
          "reps": 3,
          "targetWeightKg": 0,
          "progressionType": "LINEAR_KG",
          "progressionProtocol": "GZCLP_T1",
          "tier": "T1",
          "progressionValue": 2.5,
          "weightIncrementKg": 2.5
        },
        {
          "exerciseName": "Bench Press",
          "sets": 3,
          "reps": 10,
          "targetWeightKg": 0,
          "progressionType": "LINEAR_KG",
          "progressionProtocol": "GZCLP_T2",
          "tier": "T2",
          "progressionValue": 2.5,
          "weightIncrementKg": 2.5
        },
        {
          "exerciseName": "Lat Pulldown",
          "sets": 3,
          "reps": 15,
          "targetWeightKg": 35,
          "progressionType": "LINEAR_KG",
          "progressionProtocol": "GZCLP_T3",
          "tier": "T3",
          "progressionValue": 2.5,
          "weightIncrementKg": 2.5
        }
      ]
    },
    {
      "name": "Day 2",
      "sequenceIndex": 1,
      "exercises": [
        {
          "exerciseName": "Bench Press",
          "sets": 5,
          "reps": 3,
          "targetWeightKg": 0,
          "progressionType": "LINEAR_KG",
          "progressionProtocol": "GZCLP_T1",
          "tier": "T1",
          "progressionValue": 2.5,
          "weightIncrementKg": 2.5
        }
      ]
    }
  ]
}
```

---

## 4) Start workout

```graphql
mutation StartWorkout {
  startWorkout {
    id
    status
    startedAt
    entries {
      id
      exerciseId
      exerciseName
      plannedSets
      plannedReps
      plannedWeightKg
      sets {
        id
        setIndex
        targetReps
        isAmrap
        repsCompleted
        weightKg
        completed
      }
    }
  }
}
```

Optional: start a specific day by `planWorkoutId`:

```graphql
mutation StartWorkoutForDay($planWorkoutId: Int!) {
  startWorkout(planWorkoutId: $planWorkoutId) {
    id
    status
  }
}
```

---

## 5) Active workout session

```graphql
query ActiveWorkoutSession {
  activeWorkoutSession {
    id
    status
    startedAt
    finishedAt
    entries {
      id
      exerciseName
      plannedSets
      plannedReps
      plannedWeightKg
      sets {
        id
        setIndex
        targetReps
        isAmrap
        repsCompleted
        weightKg
        completed
        completedAt
      }
    }
  }
}
```

---

## 6) Complete one set (saved immediately)

```graphql
mutation CompleteSet(
  $sessionSetId: Int!
  $repsCompleted: Int!
  $weightKg: Float
  $durationSeconds: Int
) {
  completeSet(
    sessionSetId: $sessionSetId
    repsCompleted: $repsCompleted
    weightKg: $weightKg
    durationSeconds: $durationSeconds
  ) {
    id
    setIndex
    targetReps
    isAmrap
    repsCompleted
    weightKg
    durationSeconds
    completed
    completedAt
  }
}
```

---

## 7) Finish workout

```graphql
mutation FinishWorkout($sessionId: Int!) {
  finishWorkout(sessionId: $sessionId) {
    id
    status
    startedAt
    finishedAt
  }
}
```

---

## 8) Workout history (now includes exercise breakdown + volume)

```graphql
query WorkoutHistory($limit: Int!) {
  workoutHistory(limit: $limit) {
    sessionId
    planRunId
    finishedAt
    planWorkoutName
    workoutSequenceIndex
    totalSets
    completedSets
    totalVolumeKg
    exercises {
      exerciseId
      exerciseName
      completedSets
      totalReps
      topWeightKg
    }
  }
}
```

---

## 9) Exercise progress points (for charts)

```graphql
query ExerciseProgress($exerciseId: Int!, $limit: Int!) {
  exerciseProgress(exerciseId: $exerciseId, limit: $limit) {
    date
    topWeightKg
    estimated1rmKg
  }
}
```

---

## 10) Add day / remove day

```graphql
mutation AddDay($dayName: String) {
  addDayToActivePlan(dayName: $dayName) {
    ok
    message
  }
}
```

```graphql
mutation RemoveDay($sequenceIndex: Int!) {
  removeDayFromActivePlan(sequenceIndex: $sequenceIndex) {
    ok
    message
  }
}
```

---

## 11) Add exercise to active plan

### 11a) GZCLP T1/T2 (baseline required)

```graphql
mutation AddExercise($input: AddExerciseToActivePlanInput!) {
  addExerciseToActivePlan(input: $input) {
    ok
    message
  }
}
```

Variables:

```json
{
  "input": {
    "workoutSequenceIndex": 0,
    "exerciseName": "Overhead Press",
    "baseline1rmKg": 70,
    "sets": 5,
    "reps": 3,
    "targetWeightKg": 0,
    "progressionType": "LINEAR_KG",
    "progressionProtocol": "GZCLP_T1",
    "progressionValue": 2.5,
    "weightIncrementKg": 2.5
  }
}
```

### 11b) GZCLP T3/BASIC (start weight required, baseline optional)

```json
{
  "input": {
    "workoutSequenceIndex": 0,
    "exerciseName": "Tricep Pressdowns",
    "baseline1rmKg": null,
    "sets": 3,
    "reps": 15,
    "targetWeightKg": 25,
    "progressionType": "LINEAR_KG",
    "progressionProtocol": "GZCLP_T3",
    "progressionValue": 2.5,
    "weightIncrementKg": 2.5
  }
}
```

---

## 12) Move / remove exercise in active plan

```graphql
mutation MoveExercise($planExerciseId: Int!, $targetWorkoutSequenceIndex: Int!) {
  moveExerciseToDay(
    planExerciseId: $planExerciseId
    targetWorkoutSequenceIndex: $targetWorkoutSequenceIndex
  ) {
    ok
    message
  }
}
```

```graphql
mutation RemoveExercise($planExerciseId: Int!) {
  removeExerciseFromActivePlan(planExerciseId: $planExerciseId) {
    ok
    message
  }
}
```

---

## 13) Set explicit 1RM

```graphql
mutation SetOneRepMax($exerciseId: Int!, $oneRepMaxKg: Float!) {
  setExerciseOneRepMax(exerciseId: $exerciseId, oneRepMaxKg: $oneRepMaxKg) {
    ok
    message
  }
}
```

---

## 14) Reset progression to saved plan-start baselines

```graphql
mutation Reset($baselineOverrides: [BaselineInput!]) {
  resetToBaseline(baselineOverrides: $baselineOverrides) {
    ok
    message
    updatedExerciseCount
  }
}
```

Example override payload:

```json
{
  "baselineOverrides": [
    { "exerciseId": 1, "baseline1rmKg": 95 }
  ]
}
```

`trainingMaxRatio` is still accepted by the API for compatibility, but normal app usage uses saved plan-start baselines + optional overrides.

---

## 15) Delete active plan

```graphql
mutation DeletePlan {
  deleteActivePlan {
    ok
    message
  }
}
```

---

## 16) Exercise catalog autocomplete search

```graphql
query ExerciseCatalogSearch($query: String!, $limit: Int!) {
  exerciseCatalogSearch(query: $query, limit: $limit) {
    catalogItemId
    canonicalName
    equipmentType
    matchedAlias
    source
  }
}
```

Variables:

```json
{
  "query": "press",
  "limit": 12
}
```

---

## 17) Exercise catalog item + linking existing exercise

```graphql
query ExerciseCatalogItem($catalogItemId: Int!) {
  exerciseCatalogItem(catalogItemId: $catalogItemId) {
    id
    source
    sourceExerciseId
    canonicalName
    equipmentType
    movementCategory
    primaryMuscle
  }
}
```

```graphql
mutation LinkExerciseToCatalog($exerciseId: Int!, $catalogItemId: Int) {
  linkExerciseToCatalog(exerciseId: $exerciseId, catalogItemId: $catalogItemId) {
    ok
    message
  }
}
```

Set `catalogItemId` to `null` to unlink.

---

## 18) Strava connection status

```graphql
query StravaConnection {
  stravaConnection {
    configured
    connected
    athleteId
    athleteUsername
    scope
    expiresAt
    autoSendOnFinish
  }
}
```

---

## 19) Start Strava OAuth + connect callback

```graphql
mutation StartStravaAuth {
  startStravaAuth {
    ok
    authUrl
    message
  }
}
```

Open `authUrl` in the browser. After Strava redirects back to your app (with `code` + `state` query params), exchange via:

```graphql
mutation ConnectStrava($code: String!, $state: String!) {
  connectStrava(code: $code, state: $state) {
    ok
    message
  }
}
```

---

## 20) Toggle auto-send on workout finish (default: off)

```graphql
mutation SetStravaAutoSendOnFinish($enabled: Boolean!) {
  setStravaAutoSendOnFinish(enabled: $enabled) {
    ok
    message
  }
}
```

---

## 21) Send completed workout to Strava

```graphql
mutation SendWorkoutToStrava($sessionId: Int!) {
  sendWorkoutToStrava(sessionId: $sessionId) {
    ok
    message
    activityId
    activityUrl
  }
}
```

---

## 22) Disconnect Strava

```graphql
mutation DisconnectStrava {
  disconnectStrava {
    ok
    message
  }
}
```
