"""Inspect all seven OULAD CSVs without loading them into memory at once."""

from __future__ import annotations

import argparse
import csv
from collections import Counter
from itertools import islice
from pathlib import Path


DEFAULT_RAW_DIR = Path(__file__).resolve().parents[1] / "data" / "raw" / "archive"
KEYS = {
    "courses.csv": ("code_module", "code_presentation"),
    "assessments.csv": ("id_assessment",),
    "vle.csv": ("id_site",),
    "studentInfo.csv": ("code_module", "code_presentation", "id_student"),
    "studentRegistration.csv": ("code_module", "code_presentation", "id_student"),
    "studentAssessment.csv": ("id_assessment", "id_student"),
    "studentVle.csv": None,
}


def profile(path: Path, full: bool) -> None:
    print(f"\n{path.name} ({path.stat().st_size:,} bytes)")
    with path.open(newline="", encoding="utf-8-sig") as source:
        reader = csv.DictReader(source)
        header = reader.fieldnames
        if not header:
            raise ValueError(f"CSV has no header: {path}")
        print(f"columns ({len(header)}): {', '.join(header)}")
        sample = list(islice(reader, 2))
        for number, row in enumerate(sample, start=1):
            print(f"sample {number}: {row}")
        if not full:
            return

        blanks = Counter()
        seen = set()
        duplicate_keys = 0
        key_columns = KEYS[path.name]
        count = 0
        from itertools import chain

        for row in chain(sample, reader):
            count += 1
            for column in header:
                if row[column] == "":
                    blanks[column] += 1
            if key_columns is not None:
                key = tuple(row[column] for column in key_columns)
                if key in seen:
                    duplicate_keys += 1
                else:
                    seen.add(key)

        print(f"data rows: {count:,}")
        if key_columns is not None:
            print(f"candidate key: {', '.join(key_columns)}; duplicate rows: {duplicate_keys:,}")
        else:
            print("candidate key: none assumed; repeated daily interaction records are allowed")
        print("blank fields: " + (", ".join(f"{key}={value:,}" for key, value in blanks.items()) or "none"))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--full", action="store_true", help="scan every row for counts, blanks, and small-table key duplicates")
    parser.add_argument("--raw-dir", type=Path, default=DEFAULT_RAW_DIR, help="directory containing the seven CSVs")
    args = parser.parse_args()
    for name in KEYS:
        path = args.raw_dir / name
        if not path.is_file():
            raise SystemExit(f"Missing source file: {path}")
        profile(path, args.full)


if __name__ == "__main__":
    main()

