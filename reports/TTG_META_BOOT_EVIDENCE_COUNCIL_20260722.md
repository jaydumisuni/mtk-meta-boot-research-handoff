# TTG META Boot Evidence Council

Verdict: `BLOCKED_CALLBACK_AUTH_REQUIRED`

## Counts

- `campaigns_with_evidence`: 19
- `preloader_windows`: 22
- `ready_misses`: 0
- `metasla_responses`: 11
- `zero_length_sla_reads`: 1
- `metaforb_reads`: 5
- `static_256_attempts`: 5
- `advemeta_accepts`: 10
- `certified_raw_pid2007_transitions`: 0
- `existing_meta_d4_passes`: 1
- `legacy_false_passes`: 1

## Ranked hypotheses

- **H1 REFUTED (0.99)**: TTG misses the short Preloader or READY window. 22 Preloader windows; 0 READY misses.
- **H2 REFUTED (0.99)**: ADVEMETA acceptance is sufficient to enumerate Kernel META. 10 ATEMEVDX accepts; 0 certified raw PID_2007 transitions.
- **H3 REFUTED (0.99)**: The historical static 256-byte response completes this target's SLA stage. 5 historical attempts; 0 certified raw PID_2007 transitions.
- **H4 SUPPORTED (0.99)**: A callback-driven SLA boot context is required after METASLA. 11 METASLA responses; 1 zero-length post-SLASTART reads; 4/4 MetaCore context markers.
- **H5 REFUTED (0.99)**: The existing-META D4 read-only attach layer is the boot blocker. 1 read-only D4 attach passes after PID_2007 already existed.

## Boundary

This report contains counts and classifications only. It excludes raw serial frames, authentication material, device identifiers, local paths, and proprietary binaries.
