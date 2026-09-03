#!/usr/bin/env python3
"""chainctl -- governor-only reader/writer/validator for two_jup/chain.json.

The hard gate: a block may not be published MEASURED-CLEAN unless its witness
was demonstrated capable of a non-null (positive_control true). A witness never
seen to move renders WITNESS-DEAD, not clean. This is the section 0 rule made
structural rather than remembered -- it is the check that would have prevented
the withdrawn section 20 result.
"""
import json
import os

STATUSES = {"UNTESTED", "INSTRUMENTED", "WITNESS-DEAD",
            "MEASURED-CLEAN", "MEASURED-DEVIATES", "WITHDRAWN"}
NEEDS_PC = {"MEASURED-CLEAN", "MEASURED-DEVIATES"}


def load(path):
    with open(path) as f:
        return json.load(f)


def save(chain, path):
    errs = validate(chain)
    if errs:
        raise ValueError("refusing to save an invalid chain: " + "; ".join(errs))
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(chain, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def validate(chain):
    errs = []
    for name, b in chain.get("blocks", {}).items():
        st = b.get("status")
        if st not in STATUSES:
            errs.append(f"{name}: unknown status {st!r}")
            continue
        if st in NEEDS_PC and b.get("positive_control") is not True:
            errs.append(f"{name}: status {st} requires positive_control true "
                        f"(section 0) -- publish WITNESS-DEAD instead")
        if st.startswith("MEASURED") and not b.get("run"):
            errs.append(f"{name}: status {st} requires a run directory")
        if st.startswith("MEASURED") and not b.get("provenance"):
            errs.append(f"{name}: status {st} requires a provenance label")
    return errs


def set_block(chain, name, status, provenance, run, positive_control, note):
    if not isinstance(positive_control, bool):
        raise TypeError(
            f"set_block({name!r}): positive_control must be a bool, "
            f"got {type(positive_control).__name__} {positive_control!r} -- "
            f"a coerced value could silently launder a dead witness into a clean status"
        )
    chain.setdefault("blocks", {})[name] = {
        "status": status, "provenance": provenance, "run": run,
        "positive_control": positive_control, "note": note,
    }
