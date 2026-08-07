from __future__ import annotations

from dataclasses import dataclass

from .models import PlanWorkoutExercise, ProgressionProtocol, ProgressionType, RunExerciseState

DEFAULT_WEIGHT_INCREMENT_KG = 2.5


@dataclass
class SetPrescription:
    target_reps: int
    is_amrap: bool


@dataclass
class ExercisePrescription:
    sets: int
    reps: int
    set_prescriptions: list[SetPrescription]


@dataclass
class ProgressionInput:
    progression_type: ProgressionType
    progression_value: float
    current_weight_kg: float
    baseline_1rm_kg: float | None
    weight_increment_kg: float = DEFAULT_WEIGHT_INCREMENT_KG


@dataclass
class ProgressionResult:
    next_weight_kg: float
    failure_count: int
    needs_new_1rm: bool


def _round_to_valid_weight(weight_kg: float, increment_kg: float) -> float:
    inc = increment_kg if increment_kg > 0 else DEFAULT_WEIGHT_INCREMENT_KG
    steps = int((max(0.0, weight_kg) / inc) + 0.5)
    return round(steps * inc, 3)


def weight_increment_for_template(template: PlanWorkoutExercise) -> float:
    meta = template.progression_meta or {}
    raw = meta.get("weight_increment_kg")
    if isinstance(raw, (int, float)) and raw > 0:
        return float(raw)
    return DEFAULT_WEIGHT_INCREMENT_KG


def next_weight_kg(inp: ProgressionInput) -> float:
    if inp.progression_type == ProgressionType.NONE:
        return inp.current_weight_kg

    if inp.progression_type == ProgressionType.LINEAR_KG:
        return _round_to_valid_weight(
            max(0.0, inp.current_weight_kg + inp.progression_value),
            inp.weight_increment_kg,
        )

    if inp.progression_type == ProgressionType.PERCENT_1RM:
        if inp.baseline_1rm_kg is None:
            return inp.current_weight_kg
        # progression_value interpreted as percentage, e.g. 0.75 = 75% 1RM
        return _round_to_valid_weight(
            max(0.0, inp.baseline_1rm_kg * inp.progression_value),
            inp.weight_increment_kg,
        )

    return inp.current_weight_kg


def initial_weight_for_template(
    template: PlanWorkoutExercise,
    baseline_1rm_kg: float | None,
) -> float:
    increment_kg = weight_increment_for_template(template)

    if baseline_1rm_kg is None:
        return _round_to_valid_weight(template.target_weight_kg, increment_kg)

    if template.progression_protocol == ProgressionProtocol.GZCLP_T1:
        ratio = template.training_max_ratio if template.training_max_ratio > 0 else 0.85
        if ratio == 1.0:
            ratio = 0.85
        return _round_to_valid_weight(max(0.0, baseline_1rm_kg * ratio), increment_kg)

    if template.progression_protocol == ProgressionProtocol.GZCLP_T2:
        ratio = template.training_max_ratio if template.training_max_ratio > 0 else 0.65
        if ratio == 1.0:
            ratio = 0.65
        return _round_to_valid_weight(max(0.0, baseline_1rm_kg * ratio), increment_kg)

    return _round_to_valid_weight(template.target_weight_kg, increment_kg)


def exercise_prescription(template: PlanWorkoutExercise, state: RunExerciseState) -> ExercisePrescription:
    protocol = template.progression_protocol

    if protocol == ProgressionProtocol.GZCLP_T1:
        # Failure ladder: 5x3 -> 6x2 -> 10x1 -> require new 1RM
        if state.failure_count <= 0:
            sets, reps = 5, 3
        elif state.failure_count == 1:
            sets, reps = 6, 2
        else:
            sets, reps = 10, 1
        amrap_last = True

    elif protocol == ProgressionProtocol.GZCLP_T2:
        # Failure ladder: 3x10 -> 3x8 -> 3x6 -> require new 1RM
        if state.failure_count <= 0:
            sets, reps = 3, 10
        elif state.failure_count == 1:
            sets, reps = 3, 8
        else:
            sets, reps = 3, 6
        amrap_last = False

    elif protocol == ProgressionProtocol.GZCLP_T3:
        sets, reps = 3, 15
        amrap_last = True

    else:
        sets, reps = template.sets, template.reps
        amrap_last = template.amrap_last_set

    out_sets = [SetPrescription(target_reps=reps, is_amrap=False) for _ in range(sets)]
    if out_sets and amrap_last:
        out_sets[-1].is_amrap = True

    return ExercisePrescription(sets=sets, reps=reps, set_prescriptions=out_sets)


def _set_success(set_row) -> bool:
    if not set_row.completed:
        return False
    if set_row.reps_completed is None:
        return False
    target = set_row.target_reps or 0
    return set_row.reps_completed >= target


def evaluate_progression(
    template: PlanWorkoutExercise,
    state: RunExerciseState,
    baseline_1rm_kg: float | None,
    session_sets: list,
) -> ProgressionResult:
    all_success = bool(session_sets) and all(_set_success(s) for s in session_sets)
    protocol = template.progression_protocol

    if protocol == ProgressionProtocol.GZCLP_T3:
        # No failure ladder for T3. Increase only if AMRAP set reaches >= 25.
        last_set = session_sets[-1] if session_sets else None
        hit_amrap_gate = (
            last_set is not None
            and last_set.completed
            and last_set.reps_completed is not None
            and last_set.reps_completed >= 25
        )
        if all_success and hit_amrap_gate:
            next_weight = next_weight_kg(
                ProgressionInput(
                    progression_type=template.progression_type,
                    progression_value=template.progression_value,
                    current_weight_kg=state.current_weight_kg,
                    baseline_1rm_kg=baseline_1rm_kg,
                    weight_increment_kg=weight_increment_for_template(template),
                )
            )
            return ProgressionResult(next_weight_kg=next_weight, failure_count=0, needs_new_1rm=False)

        return ProgressionResult(
            next_weight_kg=state.current_weight_kg,
            failure_count=0,
            needs_new_1rm=False,
        )

    if all_success:
        next_weight = next_weight_kg(
            ProgressionInput(
                progression_type=template.progression_type,
                progression_value=template.progression_value,
                current_weight_kg=state.current_weight_kg,
                baseline_1rm_kg=baseline_1rm_kg,
                weight_increment_kg=weight_increment_for_template(template),
            )
        )
        return ProgressionResult(next_weight_kg=next_weight, failure_count=0, needs_new_1rm=False)

    if protocol in (ProgressionProtocol.GZCLP_T1, ProgressionProtocol.GZCLP_T2):
        next_failures = state.failure_count + 1
        if next_failures >= 3:
            return ProgressionResult(
                next_weight_kg=state.current_weight_kg,
                failure_count=0,
                needs_new_1rm=True,
            )
        return ProgressionResult(
            next_weight_kg=state.current_weight_kg,
            failure_count=next_failures,
            needs_new_1rm=False,
        )

    # BASIC progression failed -> keep weight.
    return ProgressionResult(
        next_weight_kg=state.current_weight_kg,
        failure_count=0,
        needs_new_1rm=False,
    )
