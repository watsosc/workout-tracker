from __future__ import annotations

import argparse
from datetime import datetime
import json
import re
from typing import Any
from urllib.parse import urlencode
from urllib.request import urlopen

from sqlalchemy import and_, select

from .db import db_session
from .models import (
    Exercise,
    ExerciseAliasKind,
    ExerciseCatalogAlias,
    ExerciseCatalogItem,
    ExerciseCatalogSource,
    EquipmentType,
)


def _now_utc() -> datetime:
    return datetime.utcnow()


def _normalize_text(value: str) -> str:
    value = value.strip().lower()
    value = re.sub(r"[\-_/,]+", " ", value)
    value = re.sub(r"\s+", " ", value)
    return value


def _fetch_json(url: str) -> dict[str, Any]:
    with urlopen(url, timeout=45) as response:
        return json.loads(response.read().decode("utf-8"))


def _fetch_wger_exerciseinfo(base_url: str, page_limit: int) -> list[dict[str, Any]]:
    params = urlencode({"limit": page_limit})
    next_url = f"{base_url.rstrip('/')}/exerciseinfo/?{params}"
    results: list[dict[str, Any]] = []

    while next_url:
        payload = _fetch_json(next_url)
        results.extend(payload.get("results", []))
        next_url = payload.get("next")

    return results


def _equipment_from_wger(equipment_rows: list[dict[str, Any]]) -> EquipmentType:
    names = [str((row or {}).get("name", "")).lower() for row in equipment_rows]
    text = " ".join(names)

    if "barbell" in text:
        return EquipmentType.BARBELL
    if "dumbbell" in text:
        return EquipmentType.DUMBBELL
    if "machine" in text:
        return EquipmentType.MACHINE
    if "cable" in text or "pulley" in text:
        return EquipmentType.CABLE
    if "bodyweight" in text or "body weight" in text or "none (bodyweight" in text:
        return EquipmentType.BODYWEIGHT
    if "kettlebell" in text:
        return EquipmentType.KETTLEBELL
    if "band" in text:
        return EquipmentType.BAND
    return EquipmentType.OTHER


def _extract_names(row: dict[str, Any]) -> list[str]:
    names: list[str] = []

    for tr in row.get("translations", []) or []:
        name = str((tr or {}).get("name", "")).strip()
        if name:
            names.append(name)

        aliases = (tr or {}).get("aliases", [])
        if isinstance(aliases, str):
            alias_text = aliases.strip()
            if alias_text:
                names.append(alias_text)
        elif isinstance(aliases, list):
            for alias in aliases:
                alias_text = str(alias).strip()
                if alias_text:
                    names.append(alias_text)

    deduped: list[str] = []
    seen: set[str] = set()
    for name in names:
        key = _normalize_text(name)
        if not key or key in seen:
            continue
        seen.add(key)
        deduped.append(name)
    return deduped


def _pick_canonical_name(row: dict[str, Any], names: list[str]) -> str:
    for tr in row.get("translations", []) or []:
        if (tr or {}).get("language") == 2:
            name = str((tr or {}).get("name", "")).strip()
            if name:
                return name
    if names:
        return names[0]
    return f"Exercise {row.get('id')}"


def _upsert_alias(
    session,
    catalog_item_id: int,
    alias_value: str,
    alias_kind: ExerciseAliasKind = ExerciseAliasKind.SOURCE_NAME,
) -> bool:
    normalized = _normalize_text(alias_value)
    if not normalized:
        return False

    alias = session.scalar(
        select(ExerciseCatalogAlias).where(
            and_(
                ExerciseCatalogAlias.catalog_item_id == catalog_item_id,
                ExerciseCatalogAlias.alias_normalized == normalized,
            )
        )
    )
    if alias:
        alias.alias = alias_value
        alias.alias_kind = alias_kind
        alias.is_active = True
        return False

    session.add(
        ExerciseCatalogAlias(
            catalog_item_id=catalog_item_id,
            alias=alias_value,
            alias_normalized=normalized,
            alias_kind=alias_kind,
            is_active=True,
        )
    )
    return True


def sync_wger_catalog(
    *,
    base_url: str,
    page_limit: int,
    max_items: int | None,
    deactivate_missing: bool,
) -> dict[str, int]:
    rows = _fetch_wger_exerciseinfo(base_url=base_url, page_limit=page_limit)
    if max_items is not None:
        rows = rows[:max_items]

    now = _now_utc()
    seen_source_ids: set[str] = set()

    created_items = 0
    updated_items = 0
    created_aliases = 0
    linked_existing_exercises = 0
    deactivated_items = 0

    with db_session() as session:
        for row in rows:
            source_exercise_id = str(row.get("id"))
            seen_source_ids.add(source_exercise_id)

            names = _extract_names(row)
            canonical_name = _pick_canonical_name(row, names)

            category = row.get("category") or {}
            muscles = row.get("muscles") or []

            primary_muscle = None
            if muscles:
                first_muscle = muscles[0] or {}
                primary_muscle = first_muscle.get("name_en") or first_muscle.get("name")

            item = session.scalar(
                select(ExerciseCatalogItem).where(
                    and_(
                        ExerciseCatalogItem.source == ExerciseCatalogSource.WGER,
                        ExerciseCatalogItem.source_exercise_id == source_exercise_id,
                    )
                )
            )

            if item is None:
                item = ExerciseCatalogItem(
                    source=ExerciseCatalogSource.WGER,
                    source_exercise_id=source_exercise_id,
                    canonical_name=canonical_name,
                    name_normalized=_normalize_text(canonical_name),
                    equipment_type=_equipment_from_wger(row.get("equipment") or []),
                    movement_category=(category or {}).get("name"),
                    primary_muscle=primary_muscle,
                    is_active=True,
                    raw_payload_json=row,
                    last_synced_at=now,
                )
                session.add(item)
                session.flush()
                created_items += 1
            else:
                item.canonical_name = canonical_name
                item.name_normalized = _normalize_text(canonical_name)
                item.equipment_type = _equipment_from_wger(row.get("equipment") or [])
                item.movement_category = (category or {}).get("name")
                item.primary_muscle = primary_muscle
                item.is_active = True
                item.raw_payload_json = row
                item.last_synced_at = now
                updated_items += 1

            all_names = [canonical_name, *names]
            for name in all_names:
                if _upsert_alias(session, item.id, name):
                    created_aliases += 1

        if deactivate_missing:
            existing = session.scalars(
                select(ExerciseCatalogItem).where(ExerciseCatalogItem.source == ExerciseCatalogSource.WGER)
            ).all()
            for item in existing:
                if item.source_exercise_id in seen_source_ids:
                    continue
                if item.is_active:
                    item.is_active = False
                    deactivated_items += 1

        # opportunistic linking for existing exercises by exact normalized name match
        unlinked = session.scalars(
            select(Exercise).where(Exercise.catalog_item_id.is_(None))
        ).all()
        for ex in unlinked:
            key = _normalize_text(ex.name)
            if not key:
                continue

            alias = session.scalar(
                select(ExerciseCatalogAlias)
                .where(
                    and_(
                        ExerciseCatalogAlias.alias_normalized == key,
                        ExerciseCatalogAlias.is_active.is_(True),
                    )
                )
                .order_by(ExerciseCatalogAlias.id.asc())
            )
            if alias:
                ex.catalog_item_id = alias.catalog_item_id
                linked_existing_exercises += 1

        session.commit()

    return {
        "fetched": len(rows),
        "created_items": created_items,
        "updated_items": updated_items,
        "created_aliases": created_aliases,
        "linked_existing_exercises": linked_existing_exercises,
        "deactivated_items": deactivated_items,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Sync canonical exercise catalog from wger")
    parser.add_argument("--base-url", default="https://wger.de/api/v2")
    parser.add_argument("--page-limit", type=int, default=100)
    parser.add_argument("--max-items", type=int, default=None)
    parser.add_argument("--no-deactivate-missing", action="store_true")

    args = parser.parse_args()

    summary = sync_wger_catalog(
        base_url=args.base_url,
        page_limit=max(1, min(args.page_limit, 200)),
        max_items=args.max_items,
        deactivate_missing=not args.no_deactivate_missing,
    )

    print("WGER sync complete")
    for key, value in summary.items():
        print(f"- {key}: {value}")


if __name__ == "__main__":
    main()
