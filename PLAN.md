# Plan: make reduce's input-drop optimization conditional and exact

## Problem

`gen_reduce()` currently starts each reduce loop with `DUPN`:

```c
block loop = BLOCK(gen_op_simple(DUPN),
                   source,
                   ...,
                   gen_op_simple(BACKTRACK));
```

`DUPN` is intentionally stronger than `DUP`: when the value being popped is
kept alive by a fork point, `stack_popn()` replaces that saved stack cell with
`null` instead of leaving the original value there. That was added for the old
"reduce/foreach no longer leak a reference to `.`" performance problem.

That optimization is not semantically neutral. In:

```jq
[1] | reduce .[] as $x (., .; .)
```

the reduce loop is entered while there is still an older continuation from the
multi-result init expression. That continuation can later resume and needs the
original reduce input. `DUPN` overwrites the shared saved stack cell anyway, so
the resumed continuation sees `null`, and the next `.[]` fails with "Cannot
iterate over null".

The important constraint is that the old performance fix is still valid in the
common case: once there are no older continuations that can observe the reduce
input, reduce should not keep the whole input alive for the duration of the
loop just because its finalizer fork point has a dormant stack reference to it.

## Proposed fix

Add a new VM opcode for "duplicate, and null the old stack cell only if that is
provably unobservable". For discussion, call it `DUPN_IF_UNSHARED`.

At reduce loop entry, the current stack top is the original reduce input, and
the newest fork point is the reduce finalizer fork point created by
`gen_op_target(FORK, loop)`. That newest fork point does not semantically expose
the input; on backtrack it jumps past the loop and `LOADVN res_var` discards the
top stack value before returning the final accumulator. Therefore it is safe to
ignore that one fork point when deciding whether the old stack cell can be
cleared.

The new opcode should behave as follows:

1. Let `p = jq->stk_top`, the stack cell about to be popped/duplicated.
2. Check whether `p` is reachable from any pending fork point older than the
   newest fork point.
3. If no older fork point can restore a stack containing `p`, perform the
   current `DUPN` behavior: take the value, replace the old saved cell with
   `null` when the cell cannot physically be freed yet, then push the two
   duplicates for the active path.
4. If any older fork point can restore a stack containing `p`, perform ordinary
   `DUP` behavior instead. This preserves correctness for init backtracking,
   alternation backtracking, `try`, labels, and any other construct whose saved
   continuation may still observe `.`.

This is not a heuristic: the decision is based on the VM's actual continuation
graph. If a saved continuation can reach the stack cell, keep it. If none can,
the value is dead except for the active reduce iteration and may be cleared from
the dormant stack slot.

## Implementation outline

1. Add an opcode in `src/opcode_list.h`, probably near `DUPN`:

   ```c
   OP(DUPN_IF_UNSHARED, NONE, 1, 2)
   ```

2. Add VM helpers in `src/execute.c`:

   - A helper that walks a data-stack linked list and answers whether a given
     `stack_ptr` is reachable.
   - A helper that walks the fork-point stack, skipping the newest fork point,
     and checks whether any older `fork->saved_data_stack` reaches the current
     data stack cell.

   The reachability walk should follow `stack_block_next(&jq->stk, ptr)` until
   zero. This keeps the test exact even when the target cell is not the saved
   stack top but is underneath values saved by an older continuation.

3. Implement `DUPN_IF_UNSHARED` in the execute switch:

   ```c
   case DUPN_IF_UNSHARED: {
     int shared = stack_cell_reachable_from_older_forkpoints(jq, jq->stk_top);
     jv v = shared ? stack_pop(jq) : stack_popn(jq);
     stack_push(jq, jv_copy(v));
     stack_push(jq, v);
     break;
   }
   ```

   The existing `DUP` and `DUPN` opcodes remain unchanged, which keeps the
   change scoped to reduce.

4. Change `gen_reduce()` in `src/compile.c` to use the new opcode instead of
   raw `DUPN`:

   ```c
   block loop = BLOCK(gen_op_simple(DUPN_IF_UNSHARED),
                      source,
                      ...);
   ```

   Leave `gen_foreach()` alone; its previous fix removed the unnecessary
   fork/backtrack loop entirely.

5. Add regression tests in `tests/jq.test`:

   - The reported case:

     ```jq
     [1] | reduce .[] as $x (., .; .)
     null
     [1]
     [1]
     ```

   - A source/body backtracking case to ensure reduce still keeps accumulator
     semantics:

     ```jq
     reduce range(5) as $x (0; . + $x | select($x != 2))
     null
     8
     ```

     This existing test should continue to pass.

   - A case with an older continuation outside reduce, to exercise the "fall
     back to `DUP`" branch:

     ```jq
     [1] | (., .) | reduce .[] as $x (0; . + $x)
     null
     1
     1
     ```

6. Run the jq test target locally. If the build system is available in the
   checkout, run the normal `make check` path; otherwise at least run the built
   `jq` against the new filters with `-n`.

## Why this preserves the performance property

For the common deterministic-init case, the only pending continuation at reduce
loop entry is the reduce finalizer fork point. `DUPN_IF_UNSHARED` skips that
specific fork point, sees no older continuation that can observe the input, and
uses the old `DUPN` behavior. The dormant saved stack cell is nulled immediately,
so a large reduce input is not retained solely by the finalizer.

For the uncommon but valid multi-continuation case, the VM can see that an older
fork point still reaches the same stack cell. It uses normal `DUP` behavior, so
the older continuation resumes with the correct value of `.`. This may retain
the input for that continuation, but that retention is required for correctness;
there is no sound way to discard an object while a live continuation can still
observe it.
