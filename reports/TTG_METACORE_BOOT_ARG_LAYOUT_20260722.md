# TTG MetaCore Boot Argument Layout - 2026-07-22

## Scope

This is a static ABI map from MetaCore's exported wrappers, disassembly, and
`DumpBootArg` format strings. It contains no packet payloads, keys, callback
results, identifiers, or proprietary binaries.

## Export boundary

```text
SP_Preloader_BootMode(BOOT_ARG *boot_arg)
  -> direct jump to _Preloader_BootMode@4

SP_Preloader_BootMode_r(runtime_context, BOOT_ARG *boot_arg)
  -> select runtime context
  -> call _Preloader_BootMode@4(boot_arg)
```

`_Preloader_BootMode@4` rejects a null `boot_arg` with status `0x3EA`. The
non-null path dumps the structure, starts the boot-mode entry procedure, and
passes it into the internal Preloader state machine.

`_Boot_META@16` is not that path. In this build it is a compatibility stub that
returns `0x410` immediately.

## Recovered 32-bit layout

| Offset | Width | MetaCore diagnostic field |
|---:|---:|---|
| `0x000` | 4 | BBChip type |
| `0x004` | 4 | External clock |
| `0x008` | 4 | BROM timeout |
| `0x00C` | 4 | BROM retry count |
| `0x010` | 4 | Preloader timeout |
| `0x014` | 4 | Preloader retry time |
| `0x018` | 4 | Preloader retry interval |
| `0x01C` | 4 | UART baud rate |
| `0x020` | 4 | Stop-flag address |
| `0x024` | 1 | USB enable |
| `0x025` | 1 | Symbolic-name enable |
| `0x026` | 1 | Composite-device enable |
| `0x027` | 1 | Mobile-log-service disable |
| `0x028` | 1 | Modem-logging-device enable |
| `0x02C` | 4 | Boot mode type |
| `0x030` | 2 | MD mode |
| `0x034` | 4 | COM port number |
| `0x038` | 256 | Symbolic name |
| `0x138` | 4 | AUTH file handle |
| `0x13C` | 4 | SCERT file handle |
| `0x140` | 4 | SLA challenge callback |
| `0x144` | 4 | SLA challenge callback argument |
| `0x148` | 4 | SLA challenge-end callback |
| `0x14C` | 4 | SLA challenge-end callback argument |

The internal state machine also reads a byte at `0x150`; its meaning is not
proven by `DumpBootArg`, so it remains unnamed and must not be guessed.

## Callback ABI evidence

Separate local reference modules expose the following callback shapes:

```text
SLA_Challenge(arg1, arg2, arg3, arg4, arg5)       -> stdcall, ret 0x14
SLA_Challenge_END(arg1, arg2)                     -> stdcall, ret 0x08
MD_SLA_Challenge(arg1, arg2, arg3, arg4, arg5)    -> stdcall, ret 0x14
MD_SLA_Challenge_END(arg1, arg2)                  -> stdcall, ret 0x08
```

The five-argument shape is consistent with context, challenge input, input
length, response address, and response-length address, but that semantic
mapping is not yet proven and must not be treated as a callable contract.

A separate authentication module exposes `SLASetKey`, `SLAToolAuth`, and
`SLAToolAuthEx`. Its authentication functions appear to use a four-argument
cdecl shape. They are not interchangeable with the callbacks stored in
`BOOT_ARG`.

Neither reference module is present in the installed observed-product runtime
or its exact MetaCore backend directory. They therefore establish useful ABI
shapes only; they are not evidence that the observed product loads either
module. No callback is invoked, copied, or packaged by this handoff.

## Engineering conclusion

The working entry point requires a fully initialized boot structure and, for
this target's `METASLA` path, valid callback wiring. A COM number or mode value
cannot substitute for this structure. The safe next research gate is to recover
the callback semantics and initialization ownership from exported metadata,
official SDK material, or open source. It is not safe to invoke the function
with guessed callback pointers or to replay opaque authentication frames.
